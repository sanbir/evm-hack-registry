// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

library StructData {
    // struct to store staked NFT information
    struct StakedNFT {
        address stakerAddress;
        uint256 lastClaimedTime;
        uint256 unlockTime;
        uint256 totalValueStakeUsdWithDecimal;
        uint256 totalClaimedAmountTokenWithDecimal;
        bool isUnstaked;
    }

    struct ChildListData {
        address[] childList;
        uint256 memberCounter;
    }

    struct ListBuyData {
        StructData.InfoBuyData[] childList;
    }

    struct InfoBuyData {
        uint256 timeBuy;
        uint256 valueUsd;
    }

    struct ListSwapData {
        StructData.InfoSwapData[] childList;
    }

    struct InfoSwapData {
        uint256 timeSwap;
        uint256 valueSwap;
    }

    struct ListMaintenance {
        StructData.InfoMaintenanceNft[] childList;
    }

    struct InfoMaintenanceNft {
        uint256 startTimeRepair;
        uint256 endTimeRepair;
    }
}
