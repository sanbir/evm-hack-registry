// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    FunnelVaultUpgradeable,
    FunnelVaultUpgradeableFixed,
    MockSwapX,
    MiniToken,
    ISwapX
} from "./62621-h-02-swaptokens-does-not-account-for-swapx-router-fees-when.sol";

// Funnel H-02: swapTokens credits the pool with SwapX's returned PRE-FEE amountOut,
// while the vault only received amountOut - fee (SwapX skims a native-out fee on the
// output). The pool is over-credited by the fee on every native-out swap; the
// shortfall accumulates and leaves the last withdrawer(s) insolvent.
contract SwapXNativeOutFeeOvercreditTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_nativeOutFee_overcreditsPoolAccounting() public {
        Exploit e = new Exploit();
        vm.deal(address(e), 1000 ether); // fund the driver so it can pre-fund the router
        e.run();

        // The router returned the full 100 ETH pre-fee amountOut, which the vault
        // credited to the pool verbatim...
        assertEq(e.buggyPoolCredited(), 100 ether, "pool credited pre-fee amountOut");
        // ...but the vault actually received only 100 - 3 = 97 ETH.
        assertEq(e.buggyVaultBalance(), 97 ether, "vault only received post-fee ETH");
        // Over-credit == the skimmed native-out fee (3 ETH), a phantom balance the
        // vault never held. This is the accumulating shortfall.
        assertEq(e.buggyOverCredit(), 3 ether, "over-credit == native-out fee");
        assertGt(e.buggyOverCredit(), 0, "over-credit must be strictly positive");

        // The shortfall magnitude is recorded on the marker minted to the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 3 ether, "SINK marker records the shortfall");
        assertEq(e.sinkMarkerBalance(), 3 ether, "exposed sink marker balance");

        // The real vault genuinely holds less native than its books claim: books say
        // 100 ETH credited, chain says 97 ETH held -> a 3 ETH insolvency.
        assertLt(
            e.buggyVaultBalance(),
            e.buggyPoolCredited(),
            "vault holds less native than the pool books credit"
        );
    }

    function test_control_balanceBeforeAfterFix_noOvercredit() public {
        Exploit e = new Exploit();
        vm.deal(address(e), 1000 ether);
        e.run();

        // Negative control: the audit's fix (credit balance-after minus balance-before)
        // credits the actually-received 97 ETH, so books == holdings, zero over-credit.
        assertEq(e.fixedPoolCredited(), 97 ether, "fixed credits actually-received amount");
        assertEq(e.fixedVaultBalance(), 97 ether, "fixed vault holds what it credited");
        assertEq(e.fixedOverCredit(), 0, "fix eliminates the over-credit");

        // Same scenario, only the accounting method differs -> proves the bug causes
        // the harm, not the test setup.
        assertGt(e.buggyOverCredit(), e.fixedOverCredit(), "buggy over-credits, fix does not");
    }
}
