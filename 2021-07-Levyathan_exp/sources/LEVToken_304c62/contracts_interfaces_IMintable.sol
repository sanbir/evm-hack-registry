//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

interface IMintable {
    function mint(address receiver, uint256 amount) external;
}
