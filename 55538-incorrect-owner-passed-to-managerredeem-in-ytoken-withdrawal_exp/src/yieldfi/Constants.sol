// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.20;

// Real YieldFi source, byte-identical to
// github.com/YieldFiLabs/smart-contracts/contracts/libs/Constants.sol
library Constants {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN");
    bytes32 public constant MINTER_AND_REDEEMER_ROLE = keccak256("MINTER_AND_REDEEMER");
    bytes32 public constant COLLATERAL_MANAGER_ROLE = keccak256("COLLATERAL_MANAGER");
    bytes32 public constant REWARDER_ROLE = keccak256("REWARDER");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER");
    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER");
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE");

    uint256 constant PINT = 1e18;
    uint256 constant HUNDRED_PERCENT = 100e18;

    uint256 constant VESTING_PERIOD = 8 hours;
    uint256 constant MAX_COOLDOWN_PERIOD = 7 days;
    uint256 constant MIN_COOLDOWN_PERIOD = 1 days;

    bytes constant ETH_SIGNED_MESSAGE_PREFIX = "\x19Ethereum Signed Message:\n32";

    bytes32 public constant REWARD_HASH = keccak256("REWARD");
    bytes32 public constant BRIDGE_SEND_HASH = keccak256("BRIDGE_SEND");
}
