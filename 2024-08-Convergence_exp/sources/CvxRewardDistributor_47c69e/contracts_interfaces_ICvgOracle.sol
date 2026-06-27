// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./IOracleStruct.sol";

interface ICvgOracle {
    function getPriceVerified(address erc20) external view returns (uint256);

    function getPriceUnverified(address erc20) external view returns (uint256);

    function getAndVerifyTwoPrices(address tokenIn, address tokenOut) external view returns (uint256, uint256);

    function getTwoPricesAndIsValid(
        address tokenIn,
        address tokenOut
    ) external view returns (uint256, uint256, bool, uint256, uint256, bool);

    function getPriceAndValidationData(
        address erc20Address
    ) external view returns (uint256, uint256, bool, bool, bool, bool);

    function getPoolAddressByToken(address erc20) external view returns (address);

    function poolTypePerErc20(address) external view returns (IOracleStruct.PoolType);

    //OWNER

    function setPoolTypeForToken(address _erc20Address, IOracleStruct.PoolType _poolType) external;

    function setStableParams(address _erc20Address, IOracleStruct.StableParams calldata _stableParams) external;

    function setCurveDuoParams(address _erc20Address, IOracleStruct.CurveDuoParams calldata _curveDuoParams) external;

    function setCurveTriParams(address _erc20Address, IOracleStruct.CurveTriParams calldata _curveTriParams) external;

    function setUniV3Params(address _erc20Address, IOracleStruct.UniV3Params calldata _uniV3Params) external;

    function setUniV2Params(address _erc20Address, IOracleStruct.UniV2Params calldata _uniV2Params) external;
}
