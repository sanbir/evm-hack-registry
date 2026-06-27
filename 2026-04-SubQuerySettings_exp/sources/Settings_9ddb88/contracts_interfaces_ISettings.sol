// Copyright (C) 2020-2024 SubQuery Pte Ltd authors & contributors
// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.15;

enum SQContracts {
    SQToken,
    Staking,
    StakingManager,
    IndexerRegistry,
    ProjectRegistry,
    EraManager,
    PlanManager,
    ServiceAgreementRegistry,
    RewardsDistributor,
    RewardsPool,
    RewardsStaking,
    RewardsHelper,
    InflationController,
    Vesting,
    DisputeManager,
    StateChannel,
    ConsumerRegistry,
    PriceOracle,
    Treasury,
    RewardsBooster,
    StakingAllocation
}

interface ISettings {
    event WalletBlacklistUpdated(address indexed wallet, bool blacklisted);

    function setBatchAddress(SQContracts[] calldata sq, address[] calldata _address) external;

    function setContractAddress(SQContracts sq, address _address) external;

    function getContractAddress(SQContracts sq) external view returns (address);

    function setWalletBlacklisted(address wallet, bool blacklisted) external;

    function setWalletBlacklistedBatch(address[] calldata wallets, bool blacklisted) external;

    function isWalletBlacklisted(address wallet) external view returns (bool);
}
