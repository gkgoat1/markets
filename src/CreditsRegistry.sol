// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Initializable} from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {OutcomeToken} from "./OutcomeToken.sol";
import {MarketsSlots} from "./MarketsSlots.sol";

interface IFactory {
    function isEvent(address e) external view returns (bool);
}

/// CreditsRegistry — the centralized fake-token ledger for one underlying (plan
/// §2.4). Users gain credits for interacting (welcome grant + owner grants),
/// convert credits ↔ fake outcome tokens 1:1, and get recredited on withdrawal
/// (Event.redeem calls grantFor). The registry is the sole authorized fake minter
/// for outcome tokens of its underlying, and only factory-registered events can
/// move credits.
contract CreditsRegistry is Initializable, ReentrancyGuard {
    struct CreditsStorage {
        address owner;
        IERC20 underlying;
        IFactory factory;
        uint256 welcomeGrant;
        mapping(address => uint256) credits;
        mapping(address => bool) welcomed;
        uint256 totalCredits;
    }

    event Granted(address indexed user, uint256 amount, string reason);
    event ConvertedToFake(address indexed user, address indexed event_, uint8 outcome, uint256 amount);
    event ConvertedToCredits(address indexed user, address indexed event_, uint8 outcome, uint256 amount);

    error NotOwner();
    error NotRegisteredEvent();
    error InsufficientCredits();

    function _c() internal pure returns (CreditsStorage storage s) {
        bytes32 slot = MarketsSlots.CREDITS_SLOT;
        assembly {
            s.slot := slot
        }
    }

    function initialize(address owner_, IERC20 underlying_, IFactory factory_, uint256 welcomeGrant_)
        external
        initializer
    {
        CreditsStorage storage s = _c();
        s.owner = owner_;
        s.underlying = underlying_;
        s.factory = factory_;
        s.welcomeGrant = welcomeGrant_;
    }

    modifier onlyOwner() {
        if (msg.sender != _c().owner) revert NotOwner();
        _;
    }

    function creditsOf(address user) external view returns (uint256) {
        return _c().credits[user];
    }

    function totalCredits() external view returns (uint256) {
        return _c().totalCredits;
    }

    function underlying() external view returns (IERC20) {
        return _c().underlying;
    }

    // ── grants ───────────────────────────────────────────────────────────────

    /// Claim the one-time welcome grant (the "credits for interacting" faucet).
    function claimWelcome() external {
        CreditsStorage storage s = _c();
        require(!s.welcomed[msg.sender], "already welcomed");
        s.welcomed[msg.sender] = true;
        _grant(s, msg.sender, s.welcomeGrant, "welcome");
    }

    /// Owner grant (campaigns, support, …).
    function grant(address user, uint256 amount) external onlyOwner {
        _grant(_c(), user, amount, "owner");
    }

    /// Event-only recredit (withdrawal of winning fake positions). Verified by the
    /// factory's event registry.
    function grantFor(address user, uint256 amount) external {
        CreditsStorage storage s = _c();
        if (!s.factory.isEvent(msg.sender)) revert NotRegisteredEvent();
        _grant(s, user, amount, "withdraw");
    }

    function _grant(CreditsStorage storage s, address user, uint256 amount, string memory reason) internal {
        s.credits[user] += amount;
        s.totalCredits += amount;
        emit Granted(user, amount, reason);
    }

    // ── conversions (1:1 with fake token units) ──────────────────────────────

    /// credits → fake outcome tokens. Only for factory-registered events.
    function convertToFake(address event_, uint8 outcome, uint256 amount) external nonReentrant {
        CreditsStorage storage s = _c();
        if (!s.factory.isEvent(event_)) revert NotRegisteredEvent();
        if (s.credits[msg.sender] < amount) revert InsufficientCredits();
        s.credits[msg.sender] -= amount;
        s.totalCredits -= amount;
        OutcomeToken t = OutcomeToken(_tokenOf(event_, outcome));
        t.mintFake(msg.sender, amount);
        emit ConvertedToFake(msg.sender, event_, outcome, amount);
    }

    /// fake outcome tokens → credits. The registry burns via the base's
    /// allowance path — the user approves the registry on the token once.
    function convertToCredits(address event_, uint8 outcome, uint256 amount) external nonReentrant {
        CreditsStorage storage s = _c();
        if (!s.factory.isEvent(event_)) revert NotRegisteredEvent();
        OutcomeToken t = OutcomeToken(_tokenOf(event_, outcome));
        t.burnFakeFrom(msg.sender, amount);
        s.credits[msg.sender] += amount;
        s.totalCredits += amount;
        emit ConvertedToCredits(msg.sender, event_, outcome, amount);
    }

    function _tokenOf(address event_, uint8 outcome) internal view returns (address) {
        (bool ok, bytes memory data) = event_.staticcall(abi.encodeWithSignature("outcomeToken(uint8)", outcome));
        require(ok && data.length >= 32, "no such outcome");
        return address(uint160(uint256(bytes32(data))));
    }

    uint256[50] private __creditsGap;
}
