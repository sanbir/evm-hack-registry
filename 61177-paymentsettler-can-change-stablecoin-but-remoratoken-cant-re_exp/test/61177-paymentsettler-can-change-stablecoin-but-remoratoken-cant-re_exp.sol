// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Stablecoin, PaymentSettler, RemoraToken} from
    "./61177-paymentsettler-can-change-stablecoin-but-remoratoken-cant-re.sol";

contract Finding61177Test is Test {
    function test_exploit_dividend_claim_reverts_and_locks_1000() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.claimReverted(), "claim reverted");
        assertEq(address(e.token().stablecoin()), address(e.oldCoin()), "token still on the old coin");
        assertEq(e.settler().stablecoin(), address(e.newCoin()), "settler moved");
        assertEq(e.oldCoin().balanceOf(address(e.settler())), 1000, "1000 locked");
        assertEq(e.oldCoin().balanceOf(address(e)), 0, "user paid nothing");
    }

    function test_control_claim_pays_before_the_coin_changes() public {
        Exploit e = new Exploit();
        e.oldCoin().mint(address(e.settler()), 1000);
        e.token().setDividend(address(e), 1000);
        e.claimBeforeChange();
        assertEq(e.oldCoin().balanceOf(address(e)), 1000, "user received the dividend");
        assertEq(e.oldCoin().balanceOf(address(e.settler())), 0, "settler empty");
    }
}
