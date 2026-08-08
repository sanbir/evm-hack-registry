// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2021-25 Panther Protocol Foundation
pragma solidity ^0.8.19;

/**
 * @title IPrpVoucherController
 * @notice Interface for the `PrpVoucherController` contract
 */
interface IPrpVoucherController {
    function generateRewards(
        bytes32 _secretHash,
        uint64 _amount,
        bytes4 _voucherType
    ) external returns (uint256);
}
