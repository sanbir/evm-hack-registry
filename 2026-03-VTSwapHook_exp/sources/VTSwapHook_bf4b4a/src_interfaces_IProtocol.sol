// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

interface IProtocol {

    event UpdateSettings(address prevSettings, address newSettings);

    event UpdateLntMarket(address prevLntMarket, address newLntMarket);

    event UpdateVTSwapHookHelper(address prevVTSwapHookHelper, address newVTSwapHookHelper);

    event UpdateVTFactory(address prevVTFactory, address newVTFactory);

    event AddOperator(address operator);
    event RemoveOperator(address operator);

    event AddUpgrader(address upgrader);
    event RemoveUpgrader(address upgrader);

    function owner() external view returns (address);

    function isOperator(address account) external view returns (bool);

    function isUpgrader(address account) external view returns (bool);

    function settings() external view returns (address);

    function lntMarket() external view returns (address);

    function vtSwapHookHelper() external view returns (address);

    function vtFactory() external view returns (address);

}