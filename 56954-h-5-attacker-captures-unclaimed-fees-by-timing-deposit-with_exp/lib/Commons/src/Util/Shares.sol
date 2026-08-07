// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Itos Inc.
pragma solidity ^0.8.17;

import { FullMath } from "../Math/FullMath.sol";

struct Shares {
    uint256 totalShares;
    uint256 totalAmount;
}

library SharesImpl {
    function addAmount(Shares memory self, uint256 amount) internal pure returns (uint256 sharesAdded) {
        if (self.totalShares == 0) {
            sharesAdded = amount;
        } else {
            sharesAdded = FullMath.mulDiv(amount, self.totalShares, self.totalAmount);
        }

        self.totalAmount += amount;
        self.totalShares += sharesAdded;
    }

    function removeAmount(Shares memory self, uint256 amount) internal pure returns (uint256 sharesRemoved) {
        sharesRemoved = FullMath.mulDiv(amount, self.totalShares, self.totalAmount);

        self.totalAmount -= amount;
        self.totalShares -= sharesRemoved;
    }

    function removeShares(Shares memory self, uint256 shares) internal pure returns (uint256 amountRemoved) {
        amountRemoved = FullMath.mulDiv(shares, self.totalAmount, self.totalShares);

        self.totalAmount -= amountRemoved;
        self.totalShares -= shares;
    }
}
