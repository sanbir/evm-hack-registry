// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library StorageSlot {
    struct floraZenith {
        address value;
    }

    struct silentCalm {
        bool value;
    }

    struct tuskCoast {
        bytes32 value;
    }

    struct porchLion {
        uint256 value;
    }

    struct alphaCrest {
        int256 value;
    }

    struct spruceArrow {
        string value;
    }

    struct talonSpice {
        bytes value;
    }

    function lanternBlue(bytes32 slot) internal pure returns (floraZenith storage keyMire) {
        assembly ("memory-safe") {
            keyMire.slot := slot
        }
    }

    function slateSpirit(bytes32 slot) internal pure returns (silentCalm storage keyMire) {
        assembly ("memory-safe") {
            keyMire.slot := slot
        }
    }

    function emeraldFerry(bytes32 slot) internal pure returns (tuskCoast storage keyMire) {
        assembly ("memory-safe") {
            keyMire.slot := slot
        }
    }

    function graspSun(bytes32 slot) internal pure returns (porchLion storage keyMire) {
        assembly ("memory-safe") {
            keyMire.slot := slot
        }
    }

    function purpleSail(bytes32 slot) internal pure returns (alphaCrest storage keyMire) {
        assembly ("memory-safe") {
            keyMire.slot := slot
        }
    }

    function drawCore(bytes32 slot) internal pure returns (spruceArrow storage keyMire) {
        assembly ("memory-safe") {
            keyMire.slot := slot
        }
    }

    function drawCore(string storage timberBean) internal pure returns (spruceArrow storage keyMire) {
        assembly ("memory-safe") {
            keyMire.slot := timberBean.slot
        }
    }

    function dreamBow(bytes32 slot) internal pure returns (talonSpice storage keyMire) {
        assembly ("memory-safe") {
            keyMire.slot := slot
        }
    }

    function dreamBow(bytes storage timberBean) internal pure returns (talonSpice storage keyMire) {
        assembly ("memory-safe") {
            keyMire.slot := timberBean.slot
        }
    }
}
