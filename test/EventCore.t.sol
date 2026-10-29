// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {EventFactory} from "../src/EventFactory.sol";
import {Event} from "../src/Event.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockCredits} from "./mocks/MockCredits.sol";

/// M-2 (+ M-5 redemption math, resolver faked by prank): events, outcome tokens,
/// deposits with cutoff, proportional redemption, loser no-op, zero-winner unwind.
contract EventCoreTest is Test {
    EventFactory factory;
    MockERC20 underlying;
    MockCredits credits;
    address resolver = makeAddr("resolver");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint256 constant RB = 1000; // resolution block

    Event evt;
    OutcomeToken t0;
    OutcomeToken t1;

    function setUp() public {
        underlying = new MockERC20();
        credits = new MockCredits();
        UpgradeableBeacon eventBeacon = new UpgradeableBeacon(address(new Event()), address(this));
        UpgradeableBeacon outcomeBeacon = new UpgradeableBeacon(address(new OutcomeToken()), address(this));
        factory = new EventFactory();
        factory.initialize(address(this), eventBeacon, outcomeBeacon);
        factory.setResolverFor(address(underlying), resolver);
        factory.setCreditsFor(address(underlying), address(credits));

        (address e, address[] memory tokens) =
            factory.createEvent(IERC20(address(underlying)), 2, RB, "ipfs://match-7");
        evt = Event(e);
        t0 = OutcomeToken(tokens[0]);
        t1 = OutcomeToken(tokens[1]);

        underlying.mint(alice, 10_000);
        underlying.mint(bob, 10_000);
        vm.prank(alice);
        underlying.approve(address(evt), type(uint256).max);
        vm.prank(bob);
        underlying.approve(address(evt), type(uint256).max);
    }

    function test_create_wires_event_and_tokens() public view {
        assertEq(factory.eventCount(), 1);
        assertTrue(factory.isEvent(address(evt)));
        assertEq(evt.outcomeCount(), 2);
        assertEq(address(t0.marketEvent()), address(evt));
        assertEq(address(t0.underlying()), address(underlying));
        assertEq(evt.metadataURI(), "ipfs://match-7");
    }

    function test_deposit_mints_real_and_closes_at_resolution_block() public {
        vm.prank(alice);
        evt.deposit(0, 1000);
        assertEq(t0.realOf(alice), 1000);
        assertEq(underlying.balanceOf(address(evt)), 1000);
        vm.roll(RB);
        vm.prank(alice);
        vm.expectRevert(Event.DepositsClosed.selector);
        evt.deposit(0, 1);
    }

    function test_direct_wrap_is_disabled() public {
        vm.prank(alice);
        underlying.approve(address(t0), 100);
        vm.prank(alice);
        vm.expectRevert("use Event.deposit");
        t0.wrap(100);
    }

    function test_resolve_only_resolver_and_once() public {
        vm.roll(RB);
        vm.expectRevert(Event.NotResolver.selector);
        evt.resolve(0);
        vm.prank(resolver);
        evt.resolve(0);
        vm.prank(resolver);
        vm.expectRevert("already resolved");
        evt.resolve(1);
    }

    function test_winner_redeems_proportionally_from_whole_pool() public {
        // alice backs outcome 0 with 1000, bob backs outcome 1 with 3000.
        vm.prank(alice);
        evt.deposit(0, 1000);
        vm.prank(bob);
        evt.deposit(1, 3000);
        // fake: bob gets 1000 fake of outcome 0 via the registry (the only minter)
        vm.prank(address(credits));
        t0.mintFake(bob, 1000);

        vm.roll(RB);
        vm.prank(resolver);
        evt.resolve(0); // winner = 0; pool 4000, S_w = 2000 (1000 real + 1000 fake)

        // alice: 1000 real * 4000/2000 = 2000 underlying
        uint256 balBefore = underlying.balanceOf(alice);
        vm.prank(alice);
        evt.redeem(0);
        assertEq(underlying.balanceOf(alice) - balBefore, 2000, "real pays 2x rate");
        // bob's 1000 fake * 4000/2000 = 2000 credits
        vm.prank(bob);
        evt.redeem(0);
        assertEq(credits.credits(bob), 2000, "fake settles in credits");
        assertEq(t0.totalSupply(), 0);
        // loser no-op: nothing changes
        vm.prank(bob);
        evt.redeem(1);
        assertEq(t1.realOf(bob), 3000, "losing tokens untouched (no-op)");
    }

    function test_zero_winner_unwinds_at_par() public {
        vm.prank(alice);
        evt.deposit(1, 1000); // only outcome 1 backed
        vm.roll(RB);
        vm.prank(resolver);
        evt.resolve(0); // winner 0 has zero supply -> unwind
        (Event.Status st,,) = evt.state();
        assertEq(uint8(st), uint8(Event.Status.Unwound));
        uint256 balBefore = underlying.balanceOf(alice);
        vm.prank(alice);
        evt.redeem(1);
        assertEq(underlying.balanceOf(alice) - balBefore, 1000, "1:1 refund");
    }

    function test_deposit_delta_measured_on_fee_token() public {
        underlying.setFeeBps(1000);
        vm.prank(alice);
        evt.deposit(0, 1000);
        assertEq(t0.realOf(alice), 900, "credited the received delta");
    }

    function test_event_beacon_upgrade_preserves_state() public {
        vm.prank(alice);
        evt.deposit(0, 500);
        UpgradeableBeacon eb = factory.eventBeacon();
        address v2 = address(new Event());
        eb.upgradeTo(v2);
        assertEq(t0.realOf(alice), 500);
        (Event.Status st,, uint256 rb) = evt.state();
        assertEq(uint8(st), uint8(Event.Status.Open));
        assertEq(rb, RB);
    }
}
