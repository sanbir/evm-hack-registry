// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "./interfaces/IWETH.sol";

contract TokenDistributor {
    mapping(address => bool) private _whiteList;

    constructor() {
        _whiteList[msg.sender] = true;
        _whiteList[tx.origin] = true;
    }

    function claimToken(address token, address to, uint256 amount) external {
        require(_whiteList[msg.sender], "not allowed");
        IERC20(token).transfer(to, amount);
    }

    function claimETH(address to, uint256 amount, address weth) external {
        require(_whiteList[msg.sender], "not allowed");
        uint256 wethBal = IERC20(weth).balanceOf(address(this));
        if (wethBal > 0) {
            IWETH(weth).withdraw(wethBal);
        }
        _safeTransferETH(to, amount);
    }

    function _safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, "ETH transfer failed");
    }

    receive() external payable {}
}
