// SPDX-License-Identifier: MIT

pragma solidity 0.8.15;

interface IFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint256) external view returns (address pair);
    function allPairsLength() external view returns (uint256);
    function setFeeTo(address) external;
    function feeTo() external view returns (address);
    function setFeeToSetter(address) external;
    function feeToSetter() external view returns (address);
}
