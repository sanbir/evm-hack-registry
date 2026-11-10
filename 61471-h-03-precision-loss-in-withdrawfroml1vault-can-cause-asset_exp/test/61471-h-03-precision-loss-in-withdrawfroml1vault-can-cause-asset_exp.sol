// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    L1Write,
    SpotToken,
    USER,
    VaultEscrowFixed
} from "./61471-h-03-precision-loss-in-withdrawfroml1vault-can-cause-asset.sol";

contract Finding61471Test is Test {
    function test_exploit_sendSpot_reverts_and_locks_claim() public {
        Exploit e = new Exploit();
        e.run();
        assertFalse(e.paid(), "settle reported success");
        assertEq(e.claimLeft(), 100001111, "stuck claim");
        assertEq(e.token().balanceOf(USER), 0, "user received nothing");
        assertEq(e.token().balanceOf(address(e.l1())), 100001111, "L1 still holds the spot units");
    }

    function test_control_scaled_spot_pays_fair_amount() public {
        SpotToken token = new SpotToken();
        L1Write l1 = new L1Write(token);
        VaultEscrowFixed escrow = new VaultEscrowFixed(l1);
        token.mint(address(l1), 100001111);
        escrow.requestRedeem(USER, 100001111);
        escrow.withdraw(USER);
        assertEq(token.balanceOf(USER), 100001100, "fair spot amount paid");
        assertEq(token.balanceOf(address(l1)), 11, "11 units of rounding dust remain");
        assertEq(escrow.claimOf(USER), 0, "claim cleared");
        assertEq(escrow._scaleToSpotDecimals(1000011), 100001100, "scale");
    }
}
