// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

interface IProtocolSettings {

    event UpdateTreasury(address prevTreasury, address newTreasury);

    event UpsertParamConfig(bytes32 indexed name, uint256 defaultValue, uint256 min, uint256 max);

    event UpdateVaultParamValue(address indexed vault, bytes32 indexed param, uint256 value);

    struct ParamConfig {
        uint256 defaultValue;
        uint256 min;
        uint256 max;
    }

    function treasury() external view returns (address);

    function decimals() external view returns (uint256);

    function isValidParam(bytes32 param, uint256 value) external view returns (bool);

    function paramDefaultValue(bytes32 param) external view returns (uint256);

    function vaultParamValue(address vault, bytes32 param) external view returns (uint256);
  
}