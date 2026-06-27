// SPDX-License-Identifier: MIT
pragma solidity ^0.5.17;
import "../PriceOracle/PriceOracleInterfaces.sol";

contract IAlgebraSingleAssetOracle is ISourceOracle{
    function setupAsset(
        address _asset,
        address _quoteToken,
        address _underlyingPriceFeed,
        address[] calldata _pools
    ) external;

    function changePeriodForAvgPrice(uint32 _period) external;

}
