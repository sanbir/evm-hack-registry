// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

contract EtherPaymentFallback {
    event NativeTokenReceived(address indexed sender, uint256 value);

    /// @dev Fallback function accepts Ether transactions.
    receive() external payable {
        emit NativeTokenReceived(msg.sender, msg.value);
    }
}