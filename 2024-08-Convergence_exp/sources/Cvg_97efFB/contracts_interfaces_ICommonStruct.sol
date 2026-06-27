// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ICommonStruct {
    struct TokenAmount {
        IERC20 token;
        uint256 amount;
    }
}
