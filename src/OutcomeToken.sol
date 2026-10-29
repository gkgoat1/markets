// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {FakeableERC20} from "fakeable/FakeableERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MarketsSlots} from "./MarketsSlots.sol";

/// OutcomeToken — the markets-system FakeableERC20 derivative: one per
/// {event, outcome, underlying}. The event is the vault and the only real
/// mint/burn path (wrap/unwrap are disabled — all flows route through the event,
/// which enforces the resolution-block deposit cutoff and redemption accounting).
/// The underlying's credits registry is the only authorized fake minter.
contract OutcomeToken is FakeableERC20 {
    struct OutcomeStorage {
        address event_;
        address credits;
    }

    error OnlyEvent();

    function _outcome() internal pure returns (OutcomeStorage storage s) {
        bytes32 slot = MarketsSlots.OUTCOME_SLOT;
        assembly {
            s.slot := slot
        }
    }

    function initialize(IERC20 underlying_, address event_, address credits_, string memory name_, string memory symbol_)
        external
        initializer
    {
        __FakeableERC20_init(name_, symbol_, underlying_);
        OutcomeStorage storage s = _outcome();
        s.event_ = event_;
        s.credits = credits_;
        _setVault(event_); // the event holds the pooled underlying
    }

    function marketEvent() external view returns (address) {
        return _outcome().event_;
    }

    function creditsRegistry() external view returns (address) {
        return _outcome().credits;
    }

    function _authorizeFakeMint(address caller) internal view override returns (bool) {
        return caller == _outcome().credits;
    }

    modifier onlyEvent() {
        if (msg.sender != _outcome().event_) revert OnlyEvent();
        _;
    }

    /// Event-only real mint (the event pulled the underlying first — backing is
    /// 1:1 at the event's pooled level, asserted by the invariant suite).
    function eventMintReal(address to, uint256 amount) external onlyEvent {
        _mint(to, amount);
    }

    function eventBurnRealFrom(address from, uint256 amount) external onlyEvent {
        if (realOf(from) < amount) revert InsufficientReal();
        _burn(from, amount);
    }

    function eventBurnFakeFrom(address from, uint256 amount) external onlyEvent {
        _burnFake(from, amount);
    }

    /// All user flows route through the event (deposit cutoff + redemption math).
    function wrap(uint256) external pure override {
        revert("use Event.deposit");
    }

    function unwrap(uint256) external pure override {
        revert("use Event.redeem");
    }

    uint256[50] private __outcomeGap;
}
