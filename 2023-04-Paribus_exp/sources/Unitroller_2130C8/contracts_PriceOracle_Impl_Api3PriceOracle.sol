// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "../../Interfaces/Api3Interfaces.sol";
import "./StablecoinsPriceOracle.sol";

contract Api3PriceOracle is StablecoinsPriceOracle {
    /// @notice underlying address => data feed name
    mapping(address => bytes32) public api3DataFeedNames;

    address public api3DapiServer;

    function isTokenSupported(address token) public view returns (bool) {
        return StablecoinsPriceOracle.isTokenSupported(token) || api3DataFeedNames[token] != 0;
    }

    function getPriceOfUnderlying(address token, uint decimals) public view returns (uint) {
        require(isTokenSupported(token), "TOKEN_NOT_SUPPORTED");
        if (StablecoinsPriceOracle.isTokenSupported(token)) return StablecoinsPriceOracle.getPriceOfUnderlying(token, decimals);

        (int price, /* uint timestamp */) = Api3IDapiServer(api3DapiServer).readDataFeedWithDapiName(api3DataFeedNames[token]);
        assert(price >= 0);
        return adjustDecimals(18, decimals, uint(price));
    }
}
