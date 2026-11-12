// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {
    Exploit,
    MarketBank,
    CollateralToken
} from "./18636-h-10-collateral-cannot-be-claimed-because-there-is-no-mechan.sol";

contract Finding18636Test is Test {
    address internal constant TRADER = 0x2222222222222222222222222222222222222222;

    function test_claim_reverts_and_collateral_stays_in_the_market() public {
        Exploit e = new Exploit();
        e.run();

        MarketBank bank = e.bank();
        CollateralToken token = e.token();
        console2.log("recorded", e.recorded());
        console2.log("stuck", e.stuck());
        console2.log("trader", e.traderBal());
        console2.log("factor", e.factor());
        console2.log("claim paid", e.claimPaid());
        console2.log("factor set", e.factorSet());

        assertEq(e.recorded(), 1000 ether, "1000 recorded");
        assertEq(e.claimPaid(), false, "claim reverted");
        assertEq(e.factorSet(), false, "keeper cannot set the factor");
        assertEq(e.factor(), 0, "factor stays 0");
        assertEq(e.stuck(), 1000 ether, "1000 USDC stays in the market");
        assertEq(e.traderBal(), 0, "trader received nothing");
        assertEq(token.balanceOf(address(bank)), 1000 ether, "market escrow");
        assertEq(token.balanceOf(TRADER), 0, "trader token balance");
        assertEq(bank.recorded(), 1000 ether, "claimable record");
    }

    function test_allowing_the_key_still_reverts_on_the_audited_comparison() public {
        Exploit e = new Exploit();
        e.runFactorOnly();

        console2.log("factor-only factor", e.factor());
        console2.log("factor-only stuck", e.stuck());
        console2.log("factor-only trader", e.traderBal());

        assertEq(e.claimPaid(), false, "audited >= still reverts");
        assertEq(e.stuck(), 1000 ether, "1000 still stuck");
        assertEq(e.traderBal(), 0, "trader still unpaid");
        assertEq(e.token().balanceOf(address(e.bank())), 1000 ether, "escrow");
    }

    function test_control_allows_the_claim_path_and_pays_n() public {
        Exploit e = new Exploit();
        e.runControl();

        console2.log("control factor", e.controlFactor());
        console2.log("control paid", e.controlPaid());
        console2.log("control stuck", e.controlStuck());

        assertEq(e.controlFactor() > 0, true, "factor was set");
        assertEq(e.controlPaid(), 1000 ether, "trader paid 1000");
        assertEq(e.controlStuck(), 0, "market escrow released");
        assertEq(e.token().balanceOf(TRADER), 1000 ether, "trader token balance");
    }
}
