// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IMintableNft {
    function transfer(address to) external;

    function isTransferred() external view returns (bool);
}
