// Copyright (C) 2020-2024 SubQuery Pte Ltd authors & contributors
// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.15;

interface IDisputeManager {
    function isOnDispute(address indexer) external returns (bool);
}
