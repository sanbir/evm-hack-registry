// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;
// 定义接收通知的接口（接收合约需实现此接口）

interface ITokenReceiver {
    /**
     * @dev 代币接收通知方法
     * @param sender 转账发送者
     * @param amount 转账金额
     * @return 固定返回值，用于验证接口实现
     */
    function onTokenReceived(address sender,address to, uint256 amount) external returns (bytes4);
}