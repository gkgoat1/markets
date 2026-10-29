// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/// ERC-7201 storage slots for the markets system (each =
/// keccak256(abi.encode(uint256(keccak256(ns)) - 1)) & ~0xff, pinned by tests).
library MarketsSlots {
    bytes32 constant OUTCOME_SLOT = 0xd339ad56fe1e6f6cad3d16756699fa1f4689d7410441970e9cdfc7114c980000;
    bytes32 constant EVENT_SLOT = 0x32dd7237d62dc17f0f0a325b3fe5d26b4f6c71b53339445deebdb0aa7868e300;
    bytes32 constant FACTORY_SLOT = 0x83a6b4f08608ba7d4bb5c090e20596846db398a65c7a09addcb0b65b473c4e00;
    bytes32 constant RESOLVER_SLOT = 0x1d3f7637b0efb88777ffad206f1361954c49abe311aac79dce0b0728cecb3300;
    bytes32 constant CREDITS_SLOT = 0x5c936df2a1aac5190cc0a57e106c7b6ea473ff05321b914676ab765760da4600;
}
