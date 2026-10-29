// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Resolver, ResolverStake} from "../src/Resolver.sol";
import {Event} from "../src/Event.sol";
import {EventFactory} from "../src/EventFactory.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockCredits} from "./mocks/MockCredits.sol";

/// M-3: the Resolver — rounds, escrow, plurality, quorum, slash/reward, defer,
/// and the appeal layer (overturn / uphold / defer / Lmax finality bound).
contract ResolverTest is Test {
    uint8 internal constant DEFER = type(uint8).max;

    MockERC20 underlying;
    MockCredits credits;
    Resolver resolver;
    ResolverStake stake;
    EventFactory factory;
    Event evt;
    OutcomeToken t0;
    OutcomeToken t1;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    uint256 constant RB = 100;

    Resolver.Params P = Resolver.Params({
        slashBps: 1000, // 10%
        quorumBps: 500, // 5%
        window: 10,
        deferPeriod: 20,
        windowMax: 80,
        challengeWindow: 5,
        levelMax: 2,
        appellantShareBps: 1000, // 10%
        appealBond: 100
    });

    function setUp() public {
        underlying = new MockERC20();
        credits = new MockCredits();
        UpgradeableBeacon eventBeacon = new UpgradeableBeacon(address(new Event()), address(this));
        UpgradeableBeacon outcomeBeacon = new UpgradeableBeacon(address(new OutcomeToken()), address(this));
        factory = new EventFactory();
        factory.initialize(address(this), eventBeacon, outcomeBeacon);

        stake = ResolverStake(
            address(
                new ERC1967Proxy(
                    address(new ResolverStake()),
                    abi.encodeCall(ResolverStake.initialize, (IERC20(address(underlying)), "Stake", "STK"))
                )
            )
        );
        resolver = Resolver(
            address(
                new ERC1967Proxy(
                    address(new Resolver()),
                    abi.encodeCall(Resolver.initialize, (stake, address(this), P))
                )
            )
        );
        factory.setResolverFor(address(underlying), address(resolver));
        factory.setCreditsFor(address(underlying), address(credits));

        (address e, address[] memory tokens) = factory.createEvent(IERC20(address(underlying)), 2, RB, "m");
        evt = Event(e);
        t0 = OutcomeToken(tokens[0]);
        t1 = OutcomeToken(tokens[1]);

        // stake holders: wrap underlying into stake tokens
        for (uint256 i; i < 3; i++) {
            address u = [alice, bob, carol][i];
            underlying.mint(u, 10_000);
            vm.prank(u);
            underlying.approve(address(resolver), type(uint256).max);
            vm.prank(u);
            underlying.approve(address(stake), type(uint256).max);
            vm.prank(u);
            stake.wrap(10_000);
            vm.prank(u);
            stake.approve(address(resolver), type(uint256).max); // for vote escrow
        }
    }

    uint256 internal constant SKIP = 999;

    function _openVoteConclude(uint256 aVote, uint256 bVote) internal returns (bytes32 rid) {
        vm.roll(RB);
        rid = resolver.openRound(address(evt));
        if (aVote != SKIP) {
            vm.prank(alice);
            resolver.vote(rid, uint8(aVote), 5000);
        }
        if (bVote != SKIP) {
            vm.prank(bob);
            resolver.vote(rid, uint8(bVote), 3000);
        }
        vm.roll(RB + 11);
        resolver.concludeRound(rid);
    }

    function test_fake_minting_disabled() public {
        vm.expectRevert();
        stake.mintFake(alice, 1);
    }

    function test_open_requires_maturity() public {
        vm.expectRevert("not mature");
        resolver.openRound(address(evt));
        vm.roll(RB);
        resolver.openRound(address(evt));
    }

    function test_plurality_slash_and_reward() public {
        // alice 5000 on outcome 0, bob 3000 on outcome 1, carol 2000 on DEFER.
        vm.roll(RB);
        bytes32 rid = resolver.openRound(address(evt));
        vm.prank(alice);
        resolver.vote(rid, 0, 5000);
        vm.prank(bob);
        resolver.vote(rid, 1, 3000);
        vm.prank(carol);
        resolver.vote(rid, DEFER, 2000);
        vm.roll(RB + 11);
        resolver.concludeRound(rid);
        Resolver.Round memory r = resolver.getRound(rid);
        assertEq(r.winner, 0);
        assertEq(r.slashedPool, 300, "10% of losing 3000");
        assertEq(r.winningStake, 5000);

        // bob: 3000 - 300 = 2700 back
        vm.prank(bob);
        resolver.claim(rid);
        assertEq(stake.balanceOf(bob), 7000 + 2700);
        // carol (defer): whole 2000 back
        vm.prank(carol);
        resolver.claim(rid);
        assertEq(stake.balanceOf(carol), 10_000);
        // alice: 5000 + share 300 = 5300
        vm.prank(alice);
        resolver.claim(rid);
        assertEq(stake.balanceOf(alice), 5000 + 5300);
    }

    function test_finalize_pushes_resolve_to_event() public {
        _aliceDeposits();
        bytes32 rid = _openVoteConclude(0, 1);
        vm.roll(RB + 11 + 6); // past challenge window
        resolver.finalizeRound(rid);
        (Event.Status st, uint8 w,) = evt.state();
        assertEq(uint8(st), uint8(Event.Status.Resolved));
        assertEq(w, 0);
    }

    function test_finalize_blocked_during_challenge_window() public {
        bytes32 rid = _openVoteConclude(0, 1);
        vm.expectRevert(Resolver.ChallengeActive.selector);
        resolver.finalizeRound(rid);
    }

    function test_defer_win_advances_resolution_block() public {
        bytes32 rid = _openVoteConclude(DEFER, DEFER); // both defer
        Resolver.Round memory r = resolver.getRound(rid);
        assertEq(r.winner, DEFER);
        (,, uint256 rb) = evt.state();
        assertEq(rb, RB + 11 + 20, "resolution block advanced by deferPeriod");
        // escrow returns whole
        vm.prank(alice);
        resolver.claim(rid);
        assertEq(stake.balanceOf(alice), 10_000);
    }

    function test_quorum_failure_auto_defers() public {
        vm.roll(RB);
        bytes32 rid = resolver.openRound(address(evt));
        // supply 30000; quorum 5% = 1500; vote only 1000
        vm.prank(alice);
        resolver.vote(rid, 0, 1000);
        vm.roll(RB + 11);
        resolver.concludeRound(rid);
        assertEq(resolver.getRound(rid).winner, DEFER);
    }

    function test_revote_moves_whole_stake() public {
        vm.roll(RB);
        bytes32 rid = resolver.openRound(address(evt));
        vm.prank(alice);
        resolver.vote(rid, 0, 5000);
        vm.prank(alice);
        resolver.vote(rid, 1, 5000); // re-vote
        assertEq(resolver.tallyOf(rid, 0), 0);
        assertEq(resolver.tallyOf(rid, 1), 5000);
    }

    // ── appeals ─────────────────────────────────────────────────────────────

    function _aliceDeposits() internal {
        underlying.mint(alice, 1000); // her 10k is wrapped as stake
        underlying.mint(bob, 1000);
        vm.prank(alice);
        underlying.approve(address(evt), type(uint256).max);
        vm.prank(alice);
        evt.deposit(0, 1000);
        vm.prank(bob);
        underlying.approve(address(evt), type(uint256).max);
        vm.prank(bob);
        evt.deposit(1, 1000); // both outcomes backed (zero-winner would unwind)
    }

    function test_appeal_overturn_rewards_appellant_and_new_winners() public {
        _aliceDeposits();
        // round 0: alice wins with outcome 0 (5000 vs bob 3000).
        bytes32 rid = _openVoteConclude(0, 1);
        // carol appeals for outcome 1 (bond 100).
        vm.prank(carol);
        bytes32 rid2 = resolver.appeal(rid, 1);
        Resolver.Round memory r2 = resolver.getRound(rid2);
        assertEq(r2.level, 1);
        assertEq(r2.window, 20, "window escalated 2x");
        // appeal round: bob 3000 + carol 4000 on 1 vs alice 5000 on 0 -> 7000 wins.
        vm.prank(bob);
        resolver.vote(rid2, 1, 3000);
        vm.prank(carol);
        resolver.vote(rid2, 1, 4000);
        vm.prank(alice);
        resolver.vote(rid2, 0, 5000);
        vm.roll(RB + 11 + 21);
        resolver.concludeRound(rid2);
        r2 = resolver.getRound(rid2);
        assertEq(r2.winner, 1, "overturned");
        // slashed pool = 10% of 5000 = 500; appellant reserve 10% = 50.
        assertEq(r2.slashedPool, 500);
        assertEq(r2.slashReserved, 50);
        // carol claims bond + reserve + escrow + winner share:
        // share = 4000 * (500-50)/7000 = 257 (floor)
        uint256 before = stake.balanceOf(carol);
        vm.prank(carol);
        resolver.claim(rid2);
        assertEq(stake.balanceOf(carol) - before, 4000 + 100 + 50 + 257);
        // alice (loser of the appeal round) claims 5000-500 = 4500; she also still
        // has her round-0 winnings to claim (5000 + 300 reward).
        vm.prank(alice);
        resolver.claim(rid);
        vm.prank(alice);
        resolver.claim(rid2);
        assertEq(stake.balanceOf(alice), 5300 + 4500);
        // finality: level 1 < Lmax 2, needs challenge window
        vm.roll(RB + 11 + 21 + 6);
        resolver.finalizeRound(rid2);
        (, uint8 w,) = evt.state();
        assertEq(w, 1, "event resolved to the appeal outcome");
    }

    function test_appeal_upheld_burns_bond() public {
        bytes32 rid = _openVoteConclude(0, 1);
        vm.prank(carol);
        bytes32 rid2 = resolver.appeal(rid, 1);
        // appeal round upholds 0: alice 5000 on 0 vs bob 3000 on 1
        vm.prank(alice);
        resolver.vote(rid2, 0, 5000);
        vm.prank(bob);
        resolver.vote(rid2, 1, 3000);
        vm.roll(RB + 11 + 21);
        resolver.concludeRound(rid2);
        assertEq(resolver.getRound(rid2).winner, 0, "upheld");
        // carol's bond burned: nothing claimable
        vm.prank(carol);
        vm.expectRevert("nothing to claim");
        resolver.claim(rid2);
        // settle round0 claims, then the appeal round claims
        vm.prank(alice);
        resolver.claim(rid);
        vm.prank(bob);
        resolver.claim(rid);
        vm.prank(alice);
        resolver.claim(rid2);
        vm.prank(bob);
        resolver.claim(rid2);
        // float = round0 slash 300 (alice's reward 300 leaves it 0) + round1 slash
        // 300 paid to alice as reward + bond 100 burned = 400
        assertEq(stake.balanceOf(address(resolver)), 100, "slashes paid out as rewards; bond floats");
    }

    function test_lmax_bounds_finality() public {
        // L0 -> appeal -> L1 -> appeal -> L2; L2 needs no challenge window.
        _aliceDeposits();
        bytes32 rid = _openVoteConclude(0, 1);
        vm.prank(carol);
        bytes32 rid1 = resolver.appeal(rid, 1);
        vm.prank(alice);
        resolver.claim(rid); // reclaim L0 escrow before re-staking
        vm.prank(alice);
        resolver.vote(rid1, 0, 5000);
        vm.prank(bob);
        resolver.vote(rid1, 1, 3000);
        vm.roll(block.number + 21);
        resolver.concludeRound(rid1);
        vm.prank(carol);
        bytes32 rid2 = resolver.appeal(rid1, 1); // level 2 == Lmax
        vm.prank(alice);
        resolver.claim(rid1);
        vm.prank(alice);
        resolver.vote(rid2, 0, 5000);
        vm.prank(bob);
        resolver.vote(rid2, 1, 3000);
        vm.roll(block.number + 41);
        resolver.concludeRound(rid2);
        // at Lmax: finalizable immediately (no window)
        resolver.finalizeRound(rid2);
        (, uint8 w,) = evt.state();
        assertEq(w, 0);
        // and no further appeals
        vm.expectRevert();
        resolver.appeal(rid2, 1);
    }

    function test_revote_after_window_reverts() public {
        vm.roll(RB);
        bytes32 rid = resolver.openRound(address(evt));
        vm.roll(RB + 11);
        vm.prank(alice);
        vm.expectRevert(Resolver.RoundNotOpen.selector);
        resolver.vote(rid, 0, 100);
    }
}
