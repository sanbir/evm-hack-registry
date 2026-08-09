// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    NFTFloorOracle,
    NFTFloorOracleFixed,
    MiniToken
} from "./25724-h-08-nftfloororacles-asset-and-feeder-structures-can-be-corr.sol";

contract NFTFloorOracleIndexTruncationTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_uint8IndexTruncation_corruptsExistingAsset() public {
        Exploit e = new Exploit();
        e.run();

        // The 257th distinct asset's stored index truncated to 0, colliding with asset #1.
        assertEq(e.buggyAsset257Index(), 0, "asset #257 index did not wrap to 0");

        // Removing asset #257 zeroed asset #1's array slot...
        assertTrue(e.buggySlotZeroed(), "asset #1 array slot was not corrupted");
        // ...while asset #1 is STILL registered -> registry is now inconsistent.
        assertTrue(e.buggyAsset1StillRegistered(), "asset #1 lost its registration (expected still-registered)");

        // Read the corruption directly off the deployed vulnerable oracle too.
        NFTFloorOracle vuln = NFTFloorOracle(e.vulnAddr());
        assertEq(vuln.assets(0), address(0), "vuln oracle: assets[0] not zeroed");
        (bool reg1, , ) = vuln.assetFeederMap(e.asset1());
        assertTrue(reg1, "vuln oracle: asset #1 registration wrongly cleared");
        // The array never shrank (delete does not pop): length stays 257.
        assertEq(vuln.assetsLength(), 257, "vuln oracle: assets array length changed");

        // Harm marker: 1 corrupted oracle asset entry recorded at the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 1 ether, "SINK marker did not record the corrupted entry");
        assertEq(e.sinkMarkerBalance(), 1 ether, "exploit-reported sink balance mismatch");
    }

    function test_control_uint32Index_removesOwnSlotAndLeavesAssetOneIntact() public {
        Exploit e = new Exploit();
        e.run();

        // Negative control: the uint32-index variant, identical scenario.
        // asset #1's slot is untouched and still registered...
        assertTrue(e.fixedSlotIntact(), "fixed oracle wrongly corrupted asset #1's slot");
        assertTrue(e.fixedAsset1StillRegistered(), "fixed oracle dropped asset #1 registration");
        // ...and the removal correctly zeroed asset #257's OWN slot.
        assertTrue(e.fixedOwnSlotZeroed(), "fixed oracle did not remove asset #257's own slot");

        // Direct read: no truncation, so asset #1 survives in the fixed oracle.
        NFTFloorOracleFixed fixedOracle = NFTFloorOracleFixed(e.fixedAddr());
        assertEq(fixedOracle.assets(0), e.asset1(), "fixed oracle: asset #1 slot altered");
    }
}
