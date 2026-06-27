// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ITokenInterface {
    function getFather(address user) external view returns (address);

    function burn(uint256 amount) external;
}


interface IKBKGovIDO {
    function releasePriSale(address user) external;
    function isPriSaler(address user) external view returns (bool);
}
