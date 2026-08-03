pragma solidity 0.8.13;

// SPDX-License-Identifier: MIT

import { ISlotSettlementRegistry } from "@blockswaplab/stakehouse-contract-interfaces/contracts/interfaces/ISlotSettlementRegistry.sol";

contract MockSlotRegistry is ISlotSettlementRegistry {
    function totalUserCollateralisedSLOTBalanceInHouse(address, address) external pure returns (uint256) {
        return 0;
    }

    mapping(address => mapping(address => mapping(bytes => uint256))) userCollateralisedSLOTBalanceForKnot;
    function setUserCollateralisedSLOTBalanceForKnot(address _stakeHouse, address _user, bytes calldata _blsPublicKey, uint256 _bal) external {
        userCollateralisedSLOTBalanceForKnot[_stakeHouse][_user][_blsPublicKey] = _bal;
    }

    /// @notice Total collateralised SLOT owned by an account for a given KNOT in a Stakehouse
    function totalUserCollateralisedSLOTBalanceForKnot(address _stakeHouse, address _user, bytes calldata _blsPublicKey) external view returns (uint256) {
        return userCollateralisedSLOTBalanceForKnot[_stakeHouse][_user][_blsPublicKey];
    }

    // @notice Given a KNOT and account, a flag represents whether the account has been a collateralised SLOT owner at some point in the past
    function isCollateralisedOwner(bytes calldata, address) external pure returns (bool) {
        return false;
    }

    /// @notice If a user account has been able to rage quit a KNOT, this flag is set to true to allow beacon chain funds to be claimed
    function isUserEnabledForKnotWithdrawal(address, bytes calldata) external pure returns (bool) {
        return false;
    }

    /// @notice Once beacon chain funds have been redeemed, this flag is set to true in order to block double withdrawals
    function userWithdrawn(address, bytes calldata) external pure returns (bool) {
        return false;
    }

    mapping(bytes => uint256) _numberOfCollateralisedSlotOwnersForKnot;
    function setNumberOfCollateralisedSlotOwnersForKnot(bytes calldata _blsPublicKey, uint256 _numOfOwners) external {
        _numberOfCollateralisedSlotOwnersForKnot[_blsPublicKey] = _numOfOwners;
    }

    /// @notice Total number of collateralised SLOT owners for a given KNOT
    /// @param _blsPublicKey BLS public key of the KNOT
    function numberOfCollateralisedSlotOwnersForKnot(bytes calldata _blsPublicKey) external view returns (uint256) {
        return _numberOfCollateralisedSlotOwnersForKnot[_blsPublicKey] == 0 ? 1 : _numberOfCollateralisedSlotOwnersForKnot[_blsPublicKey];
    }

    mapping(bytes => mapping(uint256 => address)) collateralisedOwnerAtIndex;
    function setCollateralisedOwnerAtIndex(bytes calldata _blsPublicKey, uint256 _index, address _owner) external {
        collateralisedOwnerAtIndex[_blsPublicKey][_index] = _owner;
    }

    /// @notice Fetch a collateralised SLOT owner address for a specific KNOT at a specific index
    function getCollateralisedOwnerAtIndex(bytes calldata _blsPublicKey, uint256 _index) external view returns (address) {
        return collateralisedOwnerAtIndex[_blsPublicKey][_index];
    }

    /// @dev Get the sum of total collateralized SLOT balances for multiple sETH tokens for specific owner
    function getCollateralizedSlotAccumulation(address[] calldata, address) external pure returns (uint256) {
        return 0;
    }

    /// @notice Total amount of SLOT that has been slashed but not topped up yet

    function currentSlashedAmountForKnot(bytes calldata) external pure returns (uint256 currentSlashedAmount) {
        return 0;
    }

    /// @notice Total amount of collateralised sETH owned by an account for a given KNOT
    function totalUserCollateralisedSETHBalanceForKnot(
        address,
        address,
        bytes calldata
    ) external pure returns (uint256) {
        return 0;
    }

    function totalUserCollateralisedSETHBalanceInHouse(
        address,
        address
    ) external pure returns (uint256) {
        return 0;
    }

    /// @notice The total collateralised sETH circulating for the house i.e. (8 * number of knots) - total slashed
    function totalCollateralisedSETHForStakehouse(
        address
    ) external pure returns (uint256) {
        return 0;
    }

    /// @notice Minimum amount of collateralised sETH a user must hold at a house level in order to rage quit a healthy knot
    function sETHRedemptionThreshold(address) external pure returns (uint256) {
        return 0;
    }

    /// @notice Given the total SLOT in the house (8 * number of KNOTs), how much is in circulation when filtering out total slashed
    function circulatingSlot(
        address
    ) external pure returns (uint256) {
        return 0;
    }

    /// @notice Given the total amount of collateralised SLOT in the house (4 * number of KNOTs), how much is in circulation when filtering out total slashed
    function circulatingCollateralisedSlot(
        address
    ) external pure returns (uint256) {
        return 0;
    }

    /// @notice Amount of sETH required per SLOT at the house level in order to rage quit
    function redemptionRate(address) external pure returns (uint256) {
        return 0;
    }

    /// @notice Amount of sETH per SLOT for a given house calculated as total dETH minted in house / total SLOT from all KNOTs
    function exchangeRate(address) external pure returns (uint256) {
        return 0;
    }

    mapping(address => address) houseToShareToken;
    function setShareTokenForHouse(address _stakeHouse, address _sETH) external {
        houseToShareToken[_stakeHouse] = _sETH;
    }

    /// @notice Returns the address of the sETH token for a given Stakehouse registry
    function stakeHouseShareTokens(address _stakeHouse) external view returns (address) {
        return houseToShareToken[_stakeHouse];
    }

    /// @notice Returns the address of the associated house for an sETH token
    function shareTokensToStakeHouse(address) external pure returns (address) {
        return address(0);
    }

    /// @notice Returns the total amount of SLOT slashed at the Stakehouse level
    function stakeHouseCurrentSLOTSlashed(address) external pure returns (uint256) {
        return 0;
    }

    /// @notice Returns the total amount of SLOT slashed for a KNOT
    function currentSlashedAmountOfSLOTForKnot(bytes calldata) external pure returns (uint256) {
        return 0;
    }

    /// @notice Total dETH minted by adding knots and minting inflation rewards within a house
    function dETHMintedInHouse(address) external pure returns (uint256) {
        return 0;
    }

    /// @notice Total SLOT minted for all KNOTs that have not rage quit the house
    function activeSlotMintedInHouse(address) external pure returns (uint256) {
        return 0;
    }

    /// @notice Total collateralised SLOT minted for all KNOTs that have not rage quit the house
    function activeCollateralisedSlotMintedInHouse(address) external pure returns (uint256) {
        return 0;
    }

    /// @notice Helper for calculating an active sETH balance from a SLOT amount
    function sETHForSLOTBalance(address, uint256) external pure returns (uint256) {
        return 0;
    }

    /// @notice Helper for calculating a SLOT balance from an sETH amount
    function slotForSETHBalance(address, uint256) external pure returns (uint256) {
        return 0;
    }
}