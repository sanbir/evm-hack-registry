// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StorageSlot} from "./StorageSlot.sol";

abstract contract ReentrancyGuard {
    using StorageSlot for bytes32;

    bytes32 private constant etherSnow =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;

    uint256 private constant raptorComet = 1;
    uint256 private constant creekChant = 2;

    error charmNest();

    constructor() {
        riftDelta().graspSun().value = raptorComet;
    }

    modifier nonReentrant() {
        mossQuilt();
        _;
        cragDiamond();
    }

    modifier petalLeaf() {
        anchorLion();
        _;
    }

    function anchorLion() private view {
        if (loftFresh()) {
            revert charmNest();
        }
    }

    function mossQuilt() private {

        anchorLion();

        riftDelta().graspSun().value = creekChant;
    }

    function cragDiamond() private {

        riftDelta().graspSun().value = raptorComet;
    }

    function loftFresh() internal view returns (bool) {
        return riftDelta().graspSun().value == creekChant;
    }

    function riftDelta() internal pure virtual returns (bytes32) {
        return etherSnow;
    }
}
