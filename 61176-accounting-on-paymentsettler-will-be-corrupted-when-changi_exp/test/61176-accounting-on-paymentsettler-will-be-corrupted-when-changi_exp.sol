// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    MiniToken,
    PaymentSettler,
    PaymentSettlerFixed
} from "./61176-accounting-on-paymentsettler-will-be-corrupted-when-changi.sol";

contract PaymentSettlerDecimalCorruptionTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_accounting_corrupted_on_stablecoin_change() public {
        Exploit e = new Exploit();
        e.run();

        // True value: 100 USD accrued at 6 decimals -> 100e18 in common 18dp unit.
        assertEq(e.correctUsd18(), 100e18, "true accrued fees should be 100 USD");

        // After switching to an 8-decimal stablecoin without rescaling, the same
        // raw 100e6 reads as only 1 USD.
        assertEq(e.corruptedUsd18(), 1e18, "corrupted reading should be 1 USD");

        // Accounting error magnitude = 99 USD.
        assertEq(e.errorUsd18(), 99e18, "error magnitude should be 99 USD");

        // MARKER: the error magnitude was minted to SINK.
        MiniToken marker = e.marker();
        assertEq(marker.balanceOf(SINK), 99e18, "marker at SINK == accounting error");
        assertEq(marker.decimals(), 18, "marker uses 18 decimals");
    }

    function test_control_fixed_rescales_and_preserves_accounting() public {
        // Same attack inputs, but against the Fixed settler.
        MiniToken usdc6 = new MiniToken("USDC", 6);
        MiniToken usdc8 = new MiniToken("USDX", 8);
        PaymentSettlerFixed settler = new PaymentSettlerFixed(address(usdc6));

        uint256 feesRaw6 = 100 * 1e6; // 100 USD at 6 decimals
        settler.accrueFee(feesRaw6);

        uint256 before = settler.accruedFeesUsd18();
        assertEq(before, 100e18, "pre-swap value 100 USD");

        // Swap stablecoin: the fix rescales raw accounting to new decimals.
        settler.changeStablecoin(address(usdc8));

        uint256 afterVal = settler.accruedFeesUsd18();
        assertEq(afterVal, 100e18, "post-swap value must still be 100 USD");

        // No accounting error remains.
        assertEq(afterVal, before, "fixed settler preserves accounting across decimal change");
    }
}
