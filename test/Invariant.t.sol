// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Resolver} from "../src/Resolver.sol";
import {Event} from "../src/Event.sol";
import {EventFactory} from "../src/EventFactory.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {CreditsRegistry, IFactory} from "../src/CreditsRegistry.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// M-6: system-wide invariant fuzzing over random operation sequences.
///   stake backing:    underlying(resolver) == Σ real stake supply
///   event accounting: underlying(event) == poolIn − paidOut;  Σ real supplies == poolIn − burnedReal
///   credits:          totalCredits == Σ user credits;  Σ fake supplies == fakeMinted − fakeBurned
contract MarketsInvariantTest is Test {
    Handler h;

    function setUp() public {
        h = new Handler();
        targetContract(address(h));
    }

    function invariant_stake_backing() public view {
        assertEq(h.underlying().balanceOf(address(h.resolver())), h.resolver().realSupply());
    }

    function invariant_event_accounting() public view {
        assertEq(h.underlying().balanceOf(address(h.evt())), h.poolIn() - h.paidOut());
        uint256 realSum = h.t0().realSupply() + h.t1().realSupply();
        assertEq(realSum, h.poolIn() - h.burnedReal());
    }

    function invariant_credits_conservation() public view {
        uint256 sum;
        for (uint256 i; i < 4; i++) {
            sum += h.credits().creditsOf(h.actors(i));
        }
        assertEq(h.credits().totalCredits(), sum);
        uint256 fakeSum = h.t0().fakeSupply() + h.t1().fakeSupply();
        assertEq(fakeSum, h.fakeMinted() - h.fakeBurned());
    }
}

contract Handler is Test {
    uint8 internal constant DEFER = type(uint8).max;

    MockERC20 public underlying;
    Resolver public resolver;
    CreditsRegistry public credits;
    Event public evt;
    OutcomeToken public t0;
    OutcomeToken public t1;
    address[] public actorList;

    // ghosts
    uint256 public poolIn;
    uint256 public paidOut;
    uint256 public burnedReal;
    uint256 public fakeMinted;
    uint256 public fakeBurned;

    uint256 constant RB = 50;

    constructor() {
        underlying = new MockERC20();
        UpgradeableBeacon eventBeacon = new UpgradeableBeacon(address(new Event()), address(this));
        UpgradeableBeacon outcomeBeacon = new UpgradeableBeacon(address(new OutcomeToken()), address(this));
        EventFactory factory = new EventFactory();
        factory.initialize(address(this), eventBeacon, outcomeBeacon);
        Resolver.Params memory p = Resolver.Params({
            slashBps: 1000, quorumBps: 100, window: 5, deferPeriod: 10, windowMax: 40,
            challengeWindow: 3, levelMax: 2, appellantShareBps: 1000, appealBond: 50
        });
        resolver = Resolver(
            address(
                new ERC1967Proxy(
                    address(new Resolver()),
                    abi.encodeCall(Resolver.initialize, (IERC20(address(underlying)), address(this), "S", "S", p))
                )
            )
        );
        credits = CreditsRegistry(
            address(
                new ERC1967Proxy(
                    address(new CreditsRegistry()),
                    abi.encodeCall(CreditsRegistry.initialize, (address(this), IERC20(address(underlying)), IFactory(address(factory)), 500))
                )
            )
        );
        factory.setResolverFor(address(underlying), address(resolver));
        factory.setCreditsFor(address(underlying), address(credits));
        (address e, address[] memory tokens) = factory.createEvent(IERC20(address(underlying)), 2, RB, "m");
        evt = Event(e);
        t0 = OutcomeToken(tokens[0]);
        t1 = OutcomeToken(tokens[1]);

        for (uint256 i; i < 4; i++) {
            address a = address(uint160(0xA000 + i));
            actorList.push(a);
            underlying.mint(a, 100_000);
            vm.startPrank(a);
            underlying.approve(address(evt), type(uint256).max);
            underlying.approve(address(resolver), type(uint256).max);
            t0.approve(address(credits), type(uint256).max);
            t1.approve(address(credits), type(uint256).max);
            vm.stopPrank();
        }
    }

    function actors(uint256 i) external view returns (address) {
        return actorList[i % 4];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actorList[seed % 4];
    }

    // ── actions ─────────────────────────────────────────────────────────────

    function rollForward(uint256 n) external {
        vm.roll(block.number + bound(n, 1, 30));
    }

    function deposit(uint256 seed, uint8 k, uint256 amount) external {
        if (block.number >= RB) return;
        address a = _actor(seed);
        amount = bound(amount, 0, underlying.balanceOf(a));
        if (amount == 0) return;
        uint256 before = underlying.balanceOf(address(evt));
        vm.prank(a);
        evt.deposit(k % 2, amount);
        poolIn += underlying.balanceOf(address(evt)) - before;
    }

    function grantCredits(uint256 seed, uint256 amount) external {
        amount = bound(amount, 1, 2000);
        credits.grant(_actor(seed), amount);
    }

    function convertFake(uint256 seed, uint8 k, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 0, credits.creditsOf(a));
        if (amount == 0) return;
        vm.prank(a);
        credits.convertToFake(address(evt), k % 2, amount);
        fakeMinted += amount;
    }

    function convertBack(uint256 seed, uint8 k, uint256 amount) external {
        address a = _actor(seed);
        OutcomeToken t = k % 2 == 0 ? t0 : t1;
        amount = bound(amount, 0, t.fakeOf(a));
        if (amount == 0) return;
        vm.prank(a);
        credits.convertToCredits(address(evt), k % 2, amount);
        fakeBurned += amount;
    }

    function wrapStake(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 0, underlying.balanceOf(a));
        if (amount == 0) return;
        vm.prank(a);
        resolver.wrap(amount);
    }

    function vote(uint256 seed, uint8 choice, uint256 amount) external {
        bytes32 rid = _latestRid();
        try resolver.getRound(rid) returns (Resolver.Round memory r) {
            if (r.status != Resolver.RoundStatus.Voting) return;
            if (block.number >= r.startBlock + r.window) return;
            address a = _actor(seed);
            // existing escrow stays; vote only extra stake the actor holds
            amount = bound(amount, 0, resolver.realOf(a));
            if (amount == 0) return;
            uint8 c = choice % 3 == 2 ? DEFER : choice % 2;
            vm.prank(a);
            resolver.vote(rid, c, amount);
        } catch {}
    }

    function _latestRid() internal view returns (bytes32) {
        // level 0 round id is the only one openable via openRound; appeal rounds
        // are opened via appeal() with explicit ids — tracked by scanning levels.
        for (uint8 l = 3; l > 0; l--) {
            bytes32 rid = resolver.roundIdOf(address(evt), l - 1);
            if (resolver.getRound(rid).event_ != address(0)) return rid;
        }
        return resolver.roundIdOf(address(evt), 0);
    }

    function openRound() external {
        (Event.Status st0,,) = evt.state(); uint8 status = uint8(st0);
        if (status != 0) return;
        if (block.number < evt.resolutionBlock()) return;
        bytes32 latest = _latestRid();
        if (resolver.getRound(latest).status == Resolver.RoundStatus.Voting) return;
        try resolver.openRound(address(evt)) {} catch {}
    }

    function conclude() external {
        bytes32 rid = _latestRid();
        Resolver.Round memory r = resolver.getRound(rid);
        if (r.event_ == address(0) || r.status != Resolver.RoundStatus.Voting) return;
        if (block.number < r.startBlock + r.window) return;
        try resolver.concludeRound(rid) {} catch {}
    }

    function appeal(uint256 seed, uint8 choice) external {
        bytes32 rid = _latestRid();
        Resolver.Round memory r = resolver.getRound(rid);
        if (r.status != Resolver.RoundStatus.Concluded) return;
        if (block.number >= r.challengeEnd || r.level >= 2) return;
        address a = _actor(seed);
        if (resolver.realOf(a) < 50) return;
        uint8 c = choice % 3 == 2 ? DEFER : choice % 2;
        if (c == r.winner) c = c == 0 ? 1 : 0;
        vm.prank(a);
        try resolver.appeal(rid, c) {} catch {}
    }

    function finalize() external {
        bytes32 rid = _latestRid();
        Resolver.Round memory r = resolver.getRound(rid);
        if (r.status != Resolver.RoundStatus.Concluded) return;
        if (r.level < 2 && block.number < r.challengeEnd) return;
        try resolver.finalizeRound(rid) {} catch {}
    }

    function redeem(uint256 seed, uint8 k) external {
        (Event.Status st1, uint8 winner,) = evt.state(); uint8 status = uint8(st1);
        if (status == 0) return;
        address a = _actor(seed);
        OutcomeToken t = k % 2 == 0 ? t0 : t1;
        uint256 r = t.realOf(a);
        uint256 f = t.fakeOf(a);
        if (r == 0 && f == 0) return;
        if (status == 1 && (k % 2) != winner) return; // no-op path
        uint256 paid;
        if (status == 1) {
            (uint256 num, uint256 den) = evt.rates();
            paid = (r * num) / den;
        } else {
            paid = r;
        }
        fakeBurned += f; // redeem burns fake (supply leaves; value recredits as credits)
        vm.prank(a);
        evt.redeem(k % 2);
        paidOut += paid;
        burnedReal += r;
    }

    function claimRound(uint256 seed) external {
        bytes32 rid = _latestRid();
        vm.prank(_actor(seed));
        try resolver.claim(rid) {} catch {}
    }
}
