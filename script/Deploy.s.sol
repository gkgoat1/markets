// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {EventFactory} from "../src/EventFactory.sol";
import {Event} from "../src/Event.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {Resolver, ResolverStake} from "../src/Resolver.sol";
import {CreditsRegistry, IFactory} from "../src/CreditsRegistry.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// Deploys the whole markets stack for one underlying and writes the dApp config.
/// The owner (deployer) holds all beacons/proxies — hand off to a multisig at launch.
contract Deploy is Script {
    function run() external {
        address underlying = vm.envAddress("UNDERLYING");
        uint256 welcomeGrant = vm.envOr("WELCOME_GRANT", uint256(500));
        vm.startBroadcast();
        address owner = msg.sender;

        Event eventImpl = new Event();
        OutcomeToken outcomeImpl = new OutcomeToken();
        UpgradeableBeacon eventBeacon = new UpgradeableBeacon(address(eventImpl), owner);
        UpgradeableBeacon outcomeBeacon = new UpgradeableBeacon(address(outcomeImpl), owner);

        EventFactory factoryImpl = new EventFactory();
        EventFactory factory = EventFactory(
            address(new ERC1967Proxy(address(factoryImpl), abi.encodeCall(EventFactory.initialize, (owner, eventBeacon, outcomeBeacon))))
        );

        Resolver.Params memory p = Resolver.Params({
            slashBps: 1000, quorumBps: 500, window: 7200, deferPeriod: 7200, windowMax: 50400,
            challengeWindow: 3600, levelMax: 3, appellantShareBps: 1000, appealBond: 0 // set per-deployment
        });
        ResolverStake stakeImpl = new ResolverStake();
        ResolverStake stakeToken = ResolverStake(
            address(new ERC1967Proxy(address(stakeImpl), abi.encodeCall(ResolverStake.initialize, (IERC20(underlying), "Stake", "STK"))))
        );
        Resolver resolverImpl = new Resolver();
        Resolver resolver = Resolver(
            address(new ERC1967Proxy(address(resolverImpl), abi.encodeCall(Resolver.initialize, (stakeToken, owner, p))))
        );

        CreditsRegistry creditsImpl = new CreditsRegistry();
        CreditsRegistry credits = CreditsRegistry(
            address(
                new ERC1967Proxy(
                    address(creditsImpl),
                    abi.encodeCall(CreditsRegistry.initialize, (owner, IERC20(underlying), IFactory(address(factory)), welcomeGrant))
                )
            )
        );

        factory.setResolverFor(underlying, address(resolver));
        factory.setCreditsFor(underlying, address(credits));
        vm.stopBroadcast();

        string memory json = string.concat(
            '{\n  "factory": "', vm.toString(address(factory)),
            '",\n  "eventBeacon": "', vm.toString(address(eventBeacon)),
            '",\n  "outcomeBeacon": "', vm.toString(address(outcomeBeacon)),
            '",\n  "trustedEventImpl": "', vm.toString(address(eventImpl)),
            '",\n  "trustedOutcomeImpl": "', vm.toString(address(outcomeImpl)),
            '",\n  "underlying": "', vm.toString(underlying),
            '",\n  "stakeToken": "', vm.toString(address(stakeToken)),
            '",\n  "resolver": "', vm.toString(address(resolver)),
            '",\n  "credits": "', vm.toString(address(credits)),
            '"\n}'
        );
        vm.writeFile("site/public/config.deployed.json", json);
    }
}
