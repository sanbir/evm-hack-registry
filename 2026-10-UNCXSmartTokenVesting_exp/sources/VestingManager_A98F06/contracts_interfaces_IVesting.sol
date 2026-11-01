// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IVesting {
    enum VestingType {
        NORMAL
        // Removed DAILY_SOFT, WEEKLY_SOFT, MONTHLY_SOFT since they're just NORMAL with specific tranches
    }
    
    error NoTokensToRelease();
}
