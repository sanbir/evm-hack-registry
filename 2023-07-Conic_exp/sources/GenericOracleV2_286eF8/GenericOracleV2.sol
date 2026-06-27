// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import "Ownable.sol";

import "IOracle.sol";

contract GenericOracleV2 is IOracle, Ownable {
    event CustomOracleAdded(address token, address oracle);

    mapping(address => IOracle) public customOracles;

    IOracle public immutable chainlinkOracle;
    IOracle public immutable curveLpOracle;

    constructor(address _curveLpOracle, address _chainlinkOracle) {
        chainlinkOracle = IOracle(_chainlinkOracle);
        curveLpOracle = IOracle(_curveLpOracle);
    }

    function isTokenSupported(address token) external view override returns (bool) {
        return
            address(customOracles[token]) != address(0) ||
            chainlinkOracle.isTokenSupported(token) ||
            curveLpOracle.isTokenSupported(token);
    }

    function getUSDPrice(address token) external view virtual returns (uint256) {
        if (chainlinkOracle.isTokenSupported(token)) {
            return chainlinkOracle.getUSDPrice(token);
        }
        if (address(customOracles[token]) != address(0)) {
            return customOracles[token].getUSDPrice(token);
        }
        return curveLpOracle.getUSDPrice(token);
    }

    function setCustomOracle(address token, address oracle) external onlyOwner {
        customOracles[token] = IOracle(oracle);
        emit CustomOracleAdded(token, oracle);
    }
}
