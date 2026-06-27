// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../interfaces/IERC677.sol";

interface ITransferReceiver {
    function onTokenTransfer(address, uint256, bytes calldata) external returns (bool);
}

interface IApprovalReceiver {
    function onTokenApproval(address, uint256, bytes calldata) external returns (bool);
}

abstract contract ERC677 is ERC20, IERC677 {
    function approveAndCall(address spender, uint256 value, bytes calldata data) external override returns (bool) {
        _approve(msg.sender, spender, value);
        return IApprovalReceiver(spender).onTokenApproval(msg.sender, value, data);
    }

    function transferAndCall(address to, uint256 value, bytes calldata data) external override returns (bool) {
        require(to != address(0) || to != address(this));
        _transfer(msg.sender, to, value);
        return ITransferReceiver(to).onTokenTransfer(msg.sender, value, data);
    }
}