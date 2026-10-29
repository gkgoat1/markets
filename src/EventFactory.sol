// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Initializable} from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Event} from "./Event.sol";
import {OutcomeToken} from "./OutcomeToken.sol";
import {MarketsSlots} from "./MarketsSlots.sol";

/// EventFactory — deploys events (beacon proxies, one per event; the address is the
/// public handle) and their outcome tokens (beacon proxies over the outcome
/// beacon). Holds the per-underlying Resolver and CreditsRegistry registry. Events
/// are verified trustlessly by their beacon + implementation (the dApp pins them).
contract EventFactory is Initializable {
    struct FactoryStorage {
        address owner;
        UpgradeableBeacon eventBeacon;
        UpgradeableBeacon outcomeBeacon;
        mapping(address => address) resolverOf; // underlying => resolver
        mapping(address => address) creditsOf; //  underlying => credits registry
        mapping(address => bool) isEvent;
        address[] events;
    }

    event EventCreated(
        address indexed event_, address indexed underlying, uint8 outcomes, uint256 resolutionBlock, string metadataURI
    );
    event ResolverSet(address indexed underlying, address resolver);
    event CreditsSet(address indexed underlying, address credits);

    error NotOwner();

    function _f() internal pure returns (FactoryStorage storage s) {
        bytes32 slot = MarketsSlots.FACTORY_SLOT;
        assembly {
            s.slot := slot
        }
    }

    function initialize(address owner_, UpgradeableBeacon eventBeacon_, UpgradeableBeacon outcomeBeacon_)
        external
        initializer
    {
        FactoryStorage storage s = _f();
        s.owner = owner_;
        s.eventBeacon = eventBeacon_;
        s.outcomeBeacon = outcomeBeacon_;
    }

    modifier onlyOwner() {
        if (msg.sender != _f().owner) revert NotOwner();
        _;
    }

    function owner() external view returns (address) {
        return _f().owner;
    }

    function eventBeacon() external view returns (UpgradeableBeacon) {
        return _f().eventBeacon;
    }

    function outcomeBeacon() external view returns (UpgradeableBeacon) {
        return _f().outcomeBeacon;
    }

    function resolverOf(address underlying) external view returns (address) {
        return _f().resolverOf[underlying];
    }

    function creditsOf(address underlying) external view returns (address) {
        return _f().creditsOf[underlying];
    }

    function isEvent(address e) external view returns (bool) {
        return _f().isEvent[e];
    }

    function eventCount() external view returns (uint256) {
        return _f().events.length;
    }

    function eventAt(uint256 i) external view returns (address) {
        return _f().events[i];
    }

    function setResolverFor(address underlying, address resolver) external onlyOwner {
        _f().resolverOf[underlying] = resolver;
        emit ResolverSet(underlying, resolver);
    }

    function setCreditsFor(address underlying, address credits) external onlyOwner {
        _f().creditsOf[underlying] = credits;
        emit CreditsSet(underlying, credits);
    }

    function createEvent(IERC20 underlying, uint8 outcomes, uint256 resolutionBlock, string memory metadataURI)
        external
        returns (address event_, address[] memory tokens)
    {
        FactoryStorage storage s = _f();
        address resolver = s.resolverOf[address(underlying)];
        address credits = s.creditsOf[address(underlying)];
        require(resolver != address(0) && credits != address(0), "underlying not registered");

        event_ = address(
            new BeaconProxy(
                address(s.eventBeacon),
                abi.encodeCall(Event.initialize, (underlying, resolver, credits, outcomes, resolutionBlock, metadataURI))
            )
        );
        tokens = new address[](outcomes);
        for (uint8 k; k < outcomes; k++) {
            string memory name = string.concat(metadataURI, " #", _u8(k));
            tokens[k] = address(
                new BeaconProxy(
                    address(s.outcomeBeacon),
                    abi.encodeCall(OutcomeToken.initialize, (underlying, event_, credits, name, name))
                )
            );
        }
        OutcomeToken[] memory ts = new OutcomeToken[](outcomes);
        for (uint8 k; k < outcomes; k++) {
            ts[k] = OutcomeToken(tokens[k]);
        }
        Event(event_).wire(ts);
        s.isEvent[event_] = true;
        s.events.push(event_);
        emit EventCreated(event_, address(underlying), outcomes, resolutionBlock, metadataURI);
    }

    function _u8(uint8 k) internal pure returns (string memory) {
        bytes memory b = new bytes(3);
        uint256 n = k;
        uint256 len;
        do {
            b[2 - len] = bytes1(uint8(48 + (n % 10)));
            n /= 10;
            len++;
        } while (n != 0 && len < 3);
        bytes memory out = new bytes(len);
        for (uint256 i; i < len; i++) {
            out[i] = b[3 - len + i];
        }
        return string(out);
    }

    uint256[50] private __factoryGap;
}
