// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CreditsRegistry, IFactory} from "../src/CreditsRegistry.sol";
import {EventFactory} from "../src/EventFactory.sol";
import {Event} from "../src/Event.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// M-4: the CreditsRegistry — grants, conversions, recredit, registry↔factory
/// cross-check.
contract CreditsTest is Test {
    MockERC20 underlying;
    CreditsRegistry credits;
    EventFactory factory;
    Event evt;
    OutcomeToken t0;
    OutcomeToken t1;
    address resolver = makeAddr("resolver");
    address alice = makeAddr("alice");
    uint256 constant RB = 100;

    function setUp() public {
        underlying = new MockERC20();
        UpgradeableBeacon eventBeacon = new UpgradeableBeacon(address(new Event()), address(this));
        UpgradeableBeacon outcomeBeacon = new UpgradeableBeacon(address(new OutcomeToken()), address(this));
        factory = new EventFactory();
        factory.initialize(address(this), eventBeacon, outcomeBeacon);
        credits = CreditsRegistry(
            address(
                new ERC1967Proxy(
                    address(new CreditsRegistry()),
                    abi.encodeCall(CreditsRegistry.initialize, (address(this), IERC20(address(underlying)), IFactory(address(factory)), 500))
                )
            )
        );
        factory.setResolverFor(address(underlying), resolver);
        factory.setCreditsFor(address(underlying), address(credits));
        (address e, address[] memory tokens) = factory.createEvent(IERC20(address(underlying)), 2, RB, "m");
        evt = Event(e);
        t0 = OutcomeToken(tokens[0]);
        t1 = OutcomeToken(tokens[1]);
    }

    function test_welcome_grant_once() public {
        vm.prank(alice);
        credits.claimWelcome();
        assertEq(credits.creditsOf(alice), 500);
        vm.prank(alice);
        vm.expectRevert("already welcomed");
        credits.claimWelcome();
    }

    function test_owner_grant_only() public {
        credits.grant(alice, 100);
        assertEq(credits.creditsOf(alice), 100);
        vm.prank(alice);
        vm.expectRevert(CreditsRegistry.NotOwner.selector);
        credits.grant(alice, 100);
    }

    function test_convert_round_trip() public {
        credits.grant(alice, 700);
        vm.prank(alice);
        credits.convertToFake(address(evt), 0, 400);
        assertEq(credits.creditsOf(alice), 300);
        assertEq(t0.fakeOf(alice), 400);
        assertEq(t0.balanceOf(alice), 400);

        vm.prank(alice);
        t0.approve(address(credits), 150);
        vm.prank(alice);
        credits.convertToCredits(address(evt), 0, 150);
        assertEq(credits.creditsOf(alice), 450);
        assertEq(t0.fakeOf(alice), 250);
    }

    function test_convert_rejects_unregistered_event() public {
        credits.grant(alice, 100);
        vm.prank(alice);
        vm.expectRevert(CreditsRegistry.NotRegisteredEvent.selector);
        credits.convertToFake(address(0xdead), 0, 50);
    }

    function test_grantFor_only_registered_events() public {
        vm.expectRevert(CreditsRegistry.NotRegisteredEvent.selector);
        credits.grantFor(alice, 100);
    }

    function test_recredit_on_withdraw() public {
        // alice: 600 fake of outcome 0 (winner), 200 real backing from this contract.
        credits.grant(alice, 600);
        vm.prank(alice);
        credits.convertToFake(address(evt), 0, 600);
        underlying.mint(address(this), 1000);
        underlying.approve(address(evt), 1000);
        evt.deposit(0, 1000);
        vm.roll(RB);
        vm.prank(resolver);
        evt.resolve(0); // pool 1000, S_w = 1000 real + 600 fake = 1600

        // alice redeems: fake 600 * 1000/1600 = 375 credits
        vm.prank(alice);
        evt.redeem(0);
        assertEq(credits.creditsOf(alice), 375, "fake recredited at the redemption rate");
        // and the owner redeems real: 1000 * 1000/1600 = 625 underlying
        uint256 before = underlying.balanceOf(address(this));
        evt.redeem(0);
        assertEq(underlying.balanceOf(address(this)) - before, 625, "real at the same rate");
    }
}
