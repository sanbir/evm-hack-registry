// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

/**
 * @title Zap errors
 * @author kexley, Beefy
 * @notice Custom errors for the zap router
 */
contract ZapErrors {
    error InvalidCaller(address owner, address caller);
    error TargetingInvalidContract(address target);
    error CallFailed(address target, uint256 value, bytes callData);
    error Slippage(address token, uint256 minAmountOut, uint256 balance);
    error EtherTransferFailed(address recipient);
    error CallerNotZap(address caller);
    error InsufficientRelayValue(uint256 balance, uint256 relayValue);
}
