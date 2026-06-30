/// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

library Transfers {
    using SafeERC20 for IERC20;
    
    error TransferFailed();
    error NotEnoughEthValueTransferred(uint256 amountReceived, uint256 amountRequired);

    function transferEth(address from, address to, uint256 amount) internal {
        if (from == msg.sender || from == address(this)) {
            if (to.code.length == 0) {
                payable(to).transfer(amount);
            } else {
                (bool success, /* bytes memory data */) = to.call{ gas: 10000, value: amount }("");
                if (!success) revert TransferFailed();
            }
        } else if (to == msg.sender || to == address(this)) {
            if (msg.value < amount) revert NotEnoughEthValueTransferred(msg.value, amount);
        }
    }

    function transferToken(address token, address from, address to, uint256 amount) internal {
        if (token == address(0)) {
            return transferEth(from, to, amount);
        }

        if (from == address(this)) {
            IERC20(token).safeTransfer(to, amount);
        } else {
            IERC20(token).safeTransferFrom(from, to, amount);
        }
    }
}