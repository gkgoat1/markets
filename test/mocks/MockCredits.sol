// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/// Stand-in credits registry for M-2 tests (the real one lands in M-4).
contract MockCredits {
    mapping(address => uint256) public credits;
    uint256 public granted;

    function grantFor(address user, uint256 amount) external {
        credits[user] += amount;
        granted += amount;
    }
}
