// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit, ClaimToken, FundingVault, Claimant} from "./45529-c-01-disburseclaims-allows-theft-of-unclaimed-funds-pashov-a.sol";

contract Finding45529Test is Test {
    function test_exploit_period3_takes_alices_unclaimed() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.vault().paid(address(e)), 300 ether, "bob");
        assertEq(e.token().balanceOf(address(e)), 300 ether, "bob bal");
        assertEq(e.vault().paid(address(e.carol())), 1200 ether, "carol");
        assertEq(e.vault().paid(address(e.alice())), 0, "alice");
        assertEq(e.token().balanceOf(address(e.vault())), 0, "empty");
        assertTrue(e.vault().hasClaimed(2, address(e.alice())), "alice claimed");
    }

    function test_control_explicit_new_rewards_pay_alice() public {
        ClaimToken token = new ClaimToken();
        FundingVault vault = new FundingVault(address(token), address(this));
        Claimant alice = new Claimant(vault);
        Claimant bob = new Claimant(vault);
        Claimant carol = new Claimant(vault);
        token.mint(address(vault), 1000 ether);
        vault.setPeriod(2);
        vault.setWeight(2, address(alice), 1000);
        vault.disburseClaimsFixed(1000 ether);
        token.mint(address(vault), 500 ether);
        vault.setPeriod(3);
        vault.setWeight(3, address(bob), 100);
        vault.setWeight(3, address(carol), 400);
        vault.disburseClaimsFixed(500 ether);
        bob.claim(3);
        carol.claim(3);
        alice.claim(2);
        assertEq(vault.paid(address(bob)), 100 ether, "bob fair");
        assertEq(vault.paid(address(carol)), 400 ether, "carol fair");
        assertEq(vault.paid(address(alice)), 1000 ether, "alice whole");
    }
}
