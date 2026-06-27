// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

// Custom interfaces for IClientReportsVerifier
interface IOracleMiddleware {
    /**
     * @notice Verifies an unverified data report if at least maxTimeDelta seconds have passed since the last verified price.
     */
    function verifyReportIfNecessary(bytes memory unverifiedReport) external;

    /**
     * @notice Returns the price data from the last verified report if the freshness is acceptable, reverts otherwise.
     * @return price The price of the last verified report.
     */
    function getPrice () external view returns (int192 price);

    /** @notice returns a boolean representing wether the priceToCheck is acceptable according to time weighted average price threshold. 
     * @param priceToCheck price value whose volatility needs to be checked against the previous trend of the prices stored locally.
     * @param priceValidFromTimestamp timestamp at which priceToCheck has been generated.
     */
    function checkLastPriceVolatility (int192 priceToCheck, uint192 priceValidFromTimestamp) external view returns (bool acceptable);

    //returns if value is inside confidence interval of target
    function inConfidenceInterval(uint256 value, uint256 target, uint256 tolerance) external pure returns (bool);   
    
}