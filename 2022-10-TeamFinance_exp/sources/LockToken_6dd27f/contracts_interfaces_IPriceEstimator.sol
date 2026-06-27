pragma solidity 0.6.2;

interface IPriceEstimator {
    function getEstimatedETHforERC20(
        uint256 erc20Amount,
        address token
    ) external view returns (uint256[] memory);

    function getEstimatedERC20forETH(
        uint256 etherAmountInWei,
        address tokenAddress
    ) external view returns (uint256[] memory);

    function getFeeInETHWithOracle(
        uint256 _feesInUSD
    ) external view returns (uint256);

    function setOracleParams(address _dataFeed, bool _useOracle) external;

    function getUseOracle() external view returns (bool);
}
