// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Collateral, VaultFixed} from
    "./40211-calculating-interest-without-considering-the-collateral-deci.sol";

contract Finding40211Test is Test {
    function test_exploit_interest_scale_locks_usdc() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.quotedInterest(), 0.1 ether, "quotes 0.1e18");
        assertTrue(e.withdrawReverted(), "withdraw underflows");
        assertEq(e.stillLocked(), 100e6, "100 USDC locked");
        assertEq(e.collateral().balanceOf(address(e.vault())), 100e6, "vault still holds it");
    }

    function test_control_scaled_interest_releases_usdc() public {
        Collateral collateral = new Collateral();
        VaultFixed vault = new VaultFixed(collateral);
        collateral.mint(address(vault), 100e6);
        vault.fundPocket(address(this), 1, 100e6, 0.1 ether);
        uint256 got = vault.withdraw(address(this), 1);
        assertEq(vault.outstandingInterestOf(address(this), 1), 0.1e6, "interest is 0.1 USDC");
        assertEq(got, 100e6 - 0.1e6, "user receives 99.9 USDC");
        assertEq(collateral.balanceOf(address(this)), 100e6 - 0.1e6, "balance");
    }
}
