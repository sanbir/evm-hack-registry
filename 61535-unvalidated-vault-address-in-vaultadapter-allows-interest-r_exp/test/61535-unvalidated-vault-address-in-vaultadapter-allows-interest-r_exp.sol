// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Coll, VaultAdapter, HonestVault} from
    "./61535-unvalidated-vault-address-in-vaultadapter-allows-interest-r.sol";

contract Finding61535Test is Test {
    function test_evil_vault_charges_5000_instead_of_100() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.charged(), 5_000 ether, "charged");
        assertEq(e.fair(), 100 ether, "fair");
        assertEq(e.coll().balanceOf(address(e)), 5_000 ether, "lender received 5000");
        assertEq(e.coll().balanceOf(address(e.adapter())), 1_000 ether, "1000 collateral left");
    }

    function test_control_honest_vault_charges_100() public {
        Coll coll = new Coll();
        VaultAdapter adapter = new VaultAdapter(coll);
        HonestVault honest = new HonestVault();
        coll.mint(address(adapter), 6_000 ether);
        uint256 quote = adapter.rate(address(honest), address(0xA55E7));
        uint256 charged = adapter.accrue(address(0xA55E7), address(this));
        assertEq(quote, 0.1 ether, "honest util");
        assertEq(charged, 100 ether, "interest");
        assertEq(coll.balanceOf(address(adapter)), 5_900 ether, "borrower keeps 5900");
    }
}
