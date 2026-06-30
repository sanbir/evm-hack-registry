// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IHenloKartV1} from './interfaces/IHenloKartV1.sol';

library HenloKartStorage {
    bytes32 internal constant STORAGE_SLOT = keccak256(abi.encode(uint256(keccak256("henlo_kart.store")) - 1)) & ~bytes32(uint256(0xff));

    /// @custom:storage-location erc7201:henlo_kart.store
    struct Store {
        mapping(address => bool) enabledHamsterAgents;
        mapping(address => bool) betTokenEnabled;
        mapping(address => mapping(uint256 size => bool)) betSizeEnabled;

        mapping(bytes32 commitmentHash => IHenloKartV1.RaceCommitment) raceCommitments;
        mapping(bytes32 commitmentHash => uint256) commitmentLockStart;
        mapping(bytes32 commitmentHash => uint256) countUsed;

        address directory;
        address jackpot;
        address feeReceiver;
        uint256 rewardFeePercent;
        uint256 feePercent;
        uint256 commitmentLockPeriod;
        uint256 raceId;
        bool isRacingEnabled;
    }

    function store() internal pure returns (Store storage $) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            $.slot := slot
        }
    }
}