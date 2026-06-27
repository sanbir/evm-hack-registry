// Copyright (C) 2020-2024 SubQuery Pte Ltd authors & contributors
// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.15;

import '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';

import './interfaces/ISettings.sol';

contract Settings is ISettings, Initializable, OwnableUpgradeable {
    mapping(SQContracts => address) public contractAddresses;
    mapping(address => bool) private walletBlacklist;

    function initialize() external initializer {
        __Ownable_init();
    }

    function setContractAddress(SQContracts sq, address _address) public onlyOwner {
        contractAddresses[sq] = _address;
    }

    function getContractAddress(SQContracts sq) public view returns (address) {
        return contractAddresses[sq];
    }

    function setBatchAddress(
        SQContracts[] calldata _sq,
        address[] calldata _address
    ) external onlyOwner {
        require(_sq.length == _address.length, 'ST001');
        for (uint256 i = 0; i < _sq.length; i++) {
            contractAddresses[_sq[i]] = _address[i];
        }
    }

    function setWalletBlacklisted(address wallet, bool blacklisted) external onlyOwner {
        walletBlacklist[wallet] = blacklisted;
        emit WalletBlacklistUpdated(wallet, blacklisted);
    }

    function setWalletBlacklistedBatch(
        address[] calldata wallets,
        bool blacklisted
    ) external onlyOwner {
        for (uint256 i = 0; i < wallets.length; i++) {
            walletBlacklist[wallets[i]] = blacklisted;
            emit WalletBlacklistUpdated(wallets[i], blacklisted);
        }
    }

    function isWalletBlacklisted(address wallet) external view returns (bool) {
        return walletBlacklist[wallet];
    }
}
