// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Initializable} from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {OutcomeToken} from "./OutcomeToken.sol";
import {MarketsSlots} from "./MarketsSlots.sol";

interface ICreditsRegistry {
    function grantFor(address user, uint256 amount) external;
}

/// Event — one contract per event; its address is the canonical handle. Holds the
/// pooled underlying for all of its outcome tokens. Deposits close at
/// resolutionBlock; resolution comes only from the event's Resolver (§2.3 of the
/// plan); redemption follows §2.2: winner redeems proportionally against the whole
/// pool at the rate snapshotted at resolve time (real → underlying, fake →
/// credits), losing outcomes no-op, zero-winner events unwind 1:1 per outcome.
contract Event is Initializable, ReentrancyGuard {
    enum Status {
        Open,
        Resolved,
        Unwound
    }

    struct EventStorage {
        IERC20 underlying;
        address resolver;
        address credits;
        address factory;
        uint8 outcomeCount;
        uint256 resolutionBlock;
        Status status;
        uint8 winner;
        OutcomeToken[] tokens;
        string metadataURI;
        // Redemption rate snapshot (pay = amount * rateNum / rateDen), set at resolve.
        uint256 rateNum;
        uint256 rateDen;
    }

    event Deposited(address indexed user, uint8 outcome, uint256 amount);
    event Resolved(uint8 winner, uint256 rateNum, uint256 rateDen);
    event Unwound();
    event Redeemed(address indexed user, uint8 outcome, uint256 realPaid, uint256 creditsPaid);

    error NotResolver();
    error DepositsClosed();
    error BadOutcome();
    error AlreadyWired();
    error NotFactory();

    function _ev() internal pure returns (EventStorage storage s) {
        bytes32 slot = MarketsSlots.EVENT_SLOT;
        assembly {
            s.slot := slot
        }
    }

    function initialize(
        IERC20 underlying_,
        address resolver_,
        address credits_,
        uint8 outcomeCount_,
        uint256 resolutionBlock_,
        string memory metadataURI_
    ) external initializer {
        require(outcomeCount_ >= 2, "need >=2 outcomes");
        require(resolutionBlock_ > block.number, "resolution block must be future");
        EventStorage storage s = _ev();
        s.underlying = underlying_;
        s.resolver = resolver_;
        s.credits = credits_;
        s.factory = msg.sender;
        s.outcomeCount = outcomeCount_;
        s.resolutionBlock = resolutionBlock_;
        s.metadataURI = metadataURI_;
    }

    /// One-time outcome-token wiring by the factory (tokens need the event address
    /// at their own init, so they deploy after the proxy address exists).
    function wire(OutcomeToken[] calldata tokens_) external {
        EventStorage storage s = _ev();
        if (msg.sender != s.factory) revert NotFactory();
        if (s.tokens.length != 0) revert AlreadyWired();
        require(tokens_.length == s.outcomeCount, "token count");
        s.tokens = tokens_;
    }

    // ── views ────────────────────────────────────────────────────────────────

    function underlying() external view returns (IERC20) {
        return _ev().underlying;
    }

    function resolver() external view returns (address) {
        return _ev().resolver;
    }

    function creditsRegistry() external view returns (address) {
        return _ev().credits;
    }

    function resolutionBlock() external view returns (uint256) {
        return _ev().resolutionBlock;
    }

    function outcomeCount() external view returns (uint8) {
        return _ev().outcomeCount;
    }

    function outcomeToken(uint8 k) external view returns (OutcomeToken) {
        return _ev().tokens[k];
    }

    function metadataURI() external view returns (string memory) {
        return _ev().metadataURI;
    }

    function rates() external view returns (uint256 rateNum, uint256 rateDen) {
        EventStorage storage s = _ev();
        return (s.rateNum, s.rateDen);
    }

    function state() external view returns (Status, uint8 winner, uint256 resolutionBlk) {
        EventStorage storage s = _ev();
        return (s.status, s.winner, s.resolutionBlock);
    }

    // ── deposits (close at resolutionBlock) ─────────────────────────────────

    function deposit(uint8 k, uint256 amount) external nonReentrant {
        EventStorage storage s = _ev();
        if (s.status != Status.Open || block.number >= s.resolutionBlock) revert DepositsClosed();
        if (k >= s.outcomeCount) revert BadOutcome();
        uint256 before = s.underlying.balanceOf(address(this));
        require(s.underlying.transferFrom(msg.sender, address(this), amount), "transfer failed");
        uint256 received = s.underlying.balanceOf(address(this)) - before; // FoT-safe
        s.tokens[k].eventMintReal(msg.sender, received);
        emit Deposited(msg.sender, k, received);
    }

    // ── resolution (resolver-only, once) ────────────────────────────────────

    /// Called by the resolver at finality. A zero-supply winner unwinds the event.
    function resolve(uint8 winner_) external {
        EventStorage storage s = _ev();
        if (msg.sender != s.resolver) revert NotResolver();
        if (s.status != Status.Open) revert("already resolved");
        if (winner_ >= s.outcomeCount) revert BadOutcome();
        uint256 sW = s.tokens[winner_].totalSupply();
        if (sW == 0) {
            s.status = Status.Unwound;
            emit Unwound();
            return;
        }
        s.status = Status.Resolved;
        s.winner = winner_;
        s.rateNum = s.underlying.balanceOf(address(this)); // == Σ real supplies
        s.rateDen = sW;
        emit Resolved(winner_, s.rateNum, s.rateDen);
    }

    /// Advance the resolution block (resolver-only, on defer outcomes).
    function defer(uint256 newResolutionBlock) external {
        EventStorage storage s = _ev();
        if (msg.sender != s.resolver) revert NotResolver();
        require(newResolutionBlock > s.resolutionBlock, "must advance");
        s.resolutionBlock = newResolutionBlock;
    }

    // ── redemption (§2.2) ───────────────────────────────────────────────────

    /// Redeems the caller's FULL position (real + fake) of outcome k. Winning
    /// outcome after resolution: real → underlying at the snapshotted rate, fake →
    /// credits at the same rate. Losing outcome: no-op. Unwound: 1:1 refund.
    function redeem(uint8 k) external nonReentrant {
        EventStorage storage s = _ev();
        if (k >= s.outcomeCount) revert BadOutcome();
        OutcomeToken t = s.tokens[k];
        if (s.status == Status.Open) revert("not resolved");
        if (s.status == Status.Resolved && k != s.winner) return; // no-op per spec

        uint256 r = t.realOf(msg.sender);
        uint256 f = t.fakeOf(msg.sender);
        if (r == 0 && f == 0) return;

        uint256 realPaid;
        uint256 creditsPaid;
        if (s.status == Status.Resolved) {
            realPaid = (r * s.rateNum) / s.rateDen;
            creditsPaid = (f * s.rateNum) / s.rateDen;
        } else {
            // Unwound: refund at par.
            realPaid = r;
            creditsPaid = f;
        }
        if (r != 0) t.eventBurnRealFrom(msg.sender, r);
        if (f != 0) t.eventBurnFakeFrom(msg.sender, f);
        if (realPaid != 0) require(s.underlying.transfer(msg.sender, realPaid), "payout failed");
        if (creditsPaid != 0) ICreditsRegistry(s.credits).grantFor(msg.sender, creditsPaid);
        emit Redeemed(msg.sender, k, realPaid, creditsPaid);
    }

    uint256[50] private __eventGap;
}
