pragma solidity 0.8.13;

// SPDX-License-Identifier: MIT

import { IStakeHouseUniverse } from "@blockswaplab/stakehouse-contract-interfaces/contracts/interfaces/IStakeHouseUniverse.sol";

contract MockStakeHouseUniverse is IStakeHouseUniverse {

    function numberOfStakeHouses() external override pure returns (uint256) {
        return 0;
    }

    function stakeHouseAtIndex(uint256) external override pure returns (address) {
        return address(0);
    }

    function numberOfSubKNOTsAtIndex(uint256) external override pure returns (uint256) {
        return 0;
    }

    function subKNOTAtIndexCoordinates(uint256, uint256) external override pure returns (bytes memory) {
        bytes memory ret = abi.encode("");
        return ret;
    }

    function stakeHouseKnotInfoGivenCoordinates(uint256, uint256) external override pure returns (
        address stakeHouse,     // Address of registered StakeHouse
        address sETHAddress,    // Address of sETH address associated with StakeHouse
        address applicant,      // Address of ETH account that added the member to the StakeHouse
        uint256 knotMemberIndex,// KNOT Index of the member within the StakeHouse
        uint256 flags,          // Flags associated with the member
        bool isActive           // Whether the member is active or knot
    ) {
        return (
            address(0),
            address(0),
            address(0),
            0,
            0,
            true
        );
    }

    mapping(bytes => bool) isKnotActive;
    function setIsActive(bytes calldata _blsPublicKey, bool _isActive) external {
        isKnotActive[_blsPublicKey] = _isActive;
    }

    mapping(bytes => address) associatedHouseForKnot;
    function setAssociatedHouseForKnot(bytes calldata _blsPublicKey, address _house) external {
        associatedHouseForKnot[_blsPublicKey] = _house;
    }

    function stakeHouseKnotInfo(bytes calldata _blsPublicKey) external override view returns (
        address stakeHouse,     // Address of registered StakeHouse
        address sETHAddress,    // Address of sETH address associated with StakeHouse
        address applicant,      // Address of ETH account that added the member to the StakeHouse
        uint256 knotMemberIndex,// KNOT Index of the member within the StakeHouse
        uint256 flags,          // Flags associated with the member
        bool isActive           // Whether the member is active or knot
    ) {
        return (
            associatedHouseForKnot[_blsPublicKey] != address(0) ? associatedHouseForKnot[_blsPublicKey] : address(uint160(5)) ,
            address(0),
            address(0),
            0,
            0,
            true
        );
    }

    function memberKnotToStakeHouse(bytes calldata _blsPublicKey) external override view returns (address) {
        return associatedHouseForKnot[_blsPublicKey];
    }
}