
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../oracle/OracleModule.sol";
import "../oracle/Oracle.sol";
import "../utils/Uint256Mask.sol";
import "../chain/Chain.sol";

/**
 * @title OracleModuleTest
 * @dev Contract to help test the OracleModule contract
 */
contract OracleModuleTest is OracleModule {
    using Uint256Mask for Uint256Mask.Mask;

    function withOraclePricesTest(
        Oracle oracle,
        DataStore dataStore,
        EventEmitter eventEmitter,
        OracleUtils.SetPricesParams memory oracleParams
    ) external payable withOraclePrices(oracle, dataStore, eventEmitter, oracleParams) {
    }

    function getTokenOracleType(DataStore dataStore, address token) external view returns (bytes32) {
        return dataStore.getBytes32(Keys.oracleTypeKey(token));
    }


    function validateSignerWithSalt(
        bytes32 SALT,
        OracleUtils.ReportInfo memory info,
        bytes memory signature,
        address expectedSigner
    ) external pure {
        OracleUtils.validateSigner(
            SALT,
            info,
            signature,
            expectedSigner
        );
    }

    function validateSigner(
        OracleUtils.ReportInfo memory info,
        bytes memory signature,
        address expectedSigner
    ) external view {
        OracleUtils.validateSigner(
            getSalt(),
            info,
            signature,
            expectedSigner
        );
    }

    function getSalt() public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, "xget-oracle-v1"));
    }
}
