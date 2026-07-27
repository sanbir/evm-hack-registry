// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @dev Protocol boundary used by the audited Syndicate implementation.  The
/// production Stakehouse API supplies these two registries; the test supplies
/// deterministic registry doubles with the same call surface.
interface IStakeHouseUniverse {
    function stakeHouseKnotInfo(bytes calldata blsPubKey)
        external
        view
        returns (address stakeHouse, uint256, uint256, uint256, uint256, bool isActive);
}

interface ISlotRegistry {
    function stakeHouseShareTokens(address stakeHouse) external view returns (address);
    function currentSlashedAmountOfSLOTForKnot(bytes calldata blsPubKey) external view returns (uint256);
    function numberOfCollateralisedSlotOwnersForKnot(bytes calldata blsPubKey) external view returns (uint256);
    function getCollateralisedOwnerAtIndex(bytes calldata blsPubKey, uint256 index) external view returns (address);
    function totalUserCollateralisedSLOTBalanceForKnot(
        address stakeHouse,
        address owner,
        bytes calldata blsPubKey
    ) external view returns (uint256);
}

contract StakehouseAPI {
    IStakeHouseUniverse private _stakeHouseUniverse;
    ISlotRegistry private _slotRegistry;

    function configureStakehouseAPI(IStakeHouseUniverse universe, ISlotRegistry registry) external {
        _stakeHouseUniverse = universe;
        _slotRegistry = registry;
    }

    function getStakeHouseUniverse() public view returns (IStakeHouseUniverse) {
        return _stakeHouseUniverse;
    }

    function getSlotRegistry() public view returns (ISlotRegistry) {
        return _slotRegistry;
    }
}
