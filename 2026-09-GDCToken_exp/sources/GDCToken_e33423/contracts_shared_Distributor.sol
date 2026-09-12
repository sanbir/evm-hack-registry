// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Distributor
 * @dev Auxiliary contract for token swaps
 * Approves the caller to transfer unlimited tokens in the constructor, used for swap operations
 */
contract Distributor {
    constructor(address token) {
        IERC20(token).approve(msg.sender, uint256(~uint256(0)));
    }
}
