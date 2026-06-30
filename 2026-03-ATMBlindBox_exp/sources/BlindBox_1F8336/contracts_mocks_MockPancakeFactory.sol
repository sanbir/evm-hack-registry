// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./MockPancakePair.sol";

contract MockPancakeFactory {
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;
    address public feeTo;
    
    function setFeeTo(address _feeTo) external {
        feeTo = _feeTo;
    }
    
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "IDENTICAL");
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(getPair[t0][t1] == address(0), "EXISTS");
        
        MockPancakePair p = new MockPancakePair();
        p.initialize(t0, t1);
        pair = address(p);
        getPair[t0][t1] = pair;
        getPair[t1][t0] = pair;
        allPairs.push(pair);
    }
    
    function allPairsLength() external view returns (uint) { return allPairs.length; }
}
