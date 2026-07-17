// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

// RECONSTRUCTED (not verified on Etherscan) from runtime bytecode at
// 0x143A737bfFC6414b61134F513CEED1a64390181A for write-up purposes.
// Owner is immutable-bound to the victim EOA; rescue* are gated, execute is not.

/// @notice Personal automation the victim used to convert yvWETH (approval-based).
/// @dev Root cause: execute() has no owner / msg.sender check.
contract VictimAutomation {
    struct Call {
        uint8 kind; // 2 = call(target, data); 3 = ERC20 transfer full/balance path
        bytes data;
    }

    // Hardcoded in bytecode as comparison target for rescue*
    address public constant OWNER = 0x98289E90d6fC92a8769bC892D006A2Baa7705aFE;

    error NotOwner();
    error CallFailed(bytes reason);

    function owner() external pure returns (address) {
        return OWNER;
    }

    /// @notice Intended private multicall helper — MISSING access control.
    /// Anyone can drive arbitrary calls as this contract (and thus spend its
    /// allowances / token balances, including the victim's infinite yvWETH approve).
    function execute(Call[] calldata calls) external {
        // BUG: no require(msg.sender == OWNER)
        for (uint256 i = 0; i < calls.length; i++) {
            _run(calls[i]);
        }
    }

    function rescueERC20(address token, address to, uint256 amount) external {
        if (msg.sender != OWNER) revert NotOwner();
        // ... transfer token to `to`
        token; to; amount;
    }

    function rescueETH(address to, uint256 amount) external {
        if (msg.sender != OWNER) revert NotOwner();
        to; amount;
    }

    function _run(Call calldata c) internal {
        // kind-decoded call / transfer path (simplified)
        c;
    }
}
