// SPDX-License-Identifier: MIT

pragma solidity >= 0.8.0;

interface IFeeDiscount {
    function tryDiscount(address _user, uint256 _amount) external returns (uint256 remaining);
}
