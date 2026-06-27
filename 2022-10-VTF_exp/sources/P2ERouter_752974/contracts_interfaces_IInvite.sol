// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

interface IInvite {

    function inviterTree(address _user, uint _height) external view returns (address[] memory);

    function sendReward(address _user, IERC20 _token, uint[] memory amounts) external returns (uint);

}

