// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, Pool, Router, Vault} from
    "./41475-h-1-lack-of-slippage-protection-leads-to-loss-of-protocol-fu.sol";

contract Finding41475Test is Test {
    function test_exploit_zero_slippage_redeems_150_ra() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.vault().raGot(), 150 ether, "vault received 150 RA");
        assertEq(e.ct().balanceOf(address(e.attacker())), 19_459_459459459459459459, "attacker CT");
        assertEq(
            e.ct().balanceOf(address(e.attacker())) - 18_000 ether,
            1_459_459459459459459459,
            "profit"
        );
    }

    function test_control_unskewed_redeem_returns_1500_ra() public {
        Token ra = new Token("RA");
        Token ct = new Token("CT");
        Pool pool = new Pool(ra, ct);
        Router router = new Router(pool);
        pool.setRouter(address(router));
        Vault vault = new Vault(pool, router);
        ra.mint(address(pool), 2_000 ether);
        ct.mint(address(pool), 2_000 ether);
        router.seed(address(vault), address(0xBEEF));

        vault.redeemEarly();

        assertEq(vault.raGot(), 1_500 ether, "fair redeem is 1500 RA");
    }
}
