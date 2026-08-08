// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    WETH,
    CurveV2Pool,
    CurveConvex2Token,
    CurveConvex2TokenFixed,
    StuckMarker
} from "./62490-h-9-hardcoded-useeth-true-in-remove-liquidity-one-coin-or-.sol";

// Notional Exponent H-9: _exitPool hardcodes use_eth = true. A WETH vault enters
// the Curve V2 pool with WETH (use_eth = false) but exits with use_eth = true, so
// the pool sends native ETH to the WETH vault — which cannot receive it — reverting
// the withdrawal and permanently locking the position.
contract PoC_62490_NotionalHardcodedUseEth is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant DEPOSIT = 10 ether;

    function test_withdrawReverts_fundsStuck() public {
        Exploit exp = new Exploit();
        vm.deal(address(exp), DEPOSIT);
        exp.run();

        CurveConvex2Token vault = exp.vault();
        StuckMarker stuck = exp.stuck();
        WETH weth = exp.weth();

        // The position is stuck: a fresh direct withdraw still reverts on the ETH send.
        vm.expectRevert(bytes("eth transfer failed"));
        vault.withdraw(DEPOSIT);

        emit log_named_decimal_uint("WETH locked in stuck vault position", stuck.balanceOf(SINK), 18);
        emit log_named_decimal_uint("WETH the depositor could recover   ", weth.balanceOf(address(this)), 18);

        // The run() catch confirmed the withdrawal reverted and marked the locked amount.
        assertEq(stuck.balanceOf(SINK), DEPOSIT, "stuck amount mismatch");
        // The vault still holds the LP (never exited) and the depositor got nothing back.
        assertEq(weth.balanceOf(address(this)), 0, "no funds should have been recovered");
    }

    // Control: exiting with use_eth = false (symmetric with entry) returns WETH.
    function test_control_useEthFalse_withdrawSucceeds() public {
        vm.deal(address(this), 100 ether);

        WETH weth = new WETH();
        CurveV2Pool pool = new CurveV2Pool(weth);
        CurveConvex2TokenFixed vault = new CurveConvex2TokenFixed(address(pool), weth);

        weth.deposit{value: DEPOSIT}();
        weth.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT);

        uint256 out = vault.withdraw(DEPOSIT);

        emit log_named_decimal_uint("WETH returned by fixed exit", weth.balanceOf(address(vault)), 18);

        assertEq(out, DEPOSIT, "fixed exit must return the full amount");
        assertEq(weth.balanceOf(address(vault)), DEPOSIT, "fixed vault must hold the returned WETH");
    }
}
