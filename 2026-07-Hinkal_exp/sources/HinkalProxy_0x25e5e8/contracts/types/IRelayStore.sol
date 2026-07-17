// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

interface IRelayStore {
    event RelayAdded(address relayAddress);
    event RelayRemoved(address relayAddress);

    function isRelayInList(address relay) external view returns (bool);

    function getRelayStore() external view returns (address[] memory);

    function removeRelay(address _relayAddress) external;

    function addRelay(address relayAddress) external;

    function calculateRelayFee(
        uint256 balance,
        uint256 flatFee,
        uint256 variableRate
    ) external view returns (uint256 relayFee);
}
