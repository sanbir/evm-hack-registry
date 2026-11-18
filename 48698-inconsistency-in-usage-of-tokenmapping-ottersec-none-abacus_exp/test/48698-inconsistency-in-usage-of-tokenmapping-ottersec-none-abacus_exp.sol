// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, Vault, Factory, Lend} from
    "./48698-inconsistency-in-usage-of-tokenmapping-ottersec-none-abacus.sol";

contract Finding48698Test is Test {
    address constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_wrong_key_closes_pool_and_bricks_liquidation() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.vault().closed(), "closed");
        assertTrue(e.liquidateReverted(), "liquidate reverted");
        assertEq(e.lend().debt(e.NFT(), e.ID()), 100e18, "unpaid debt");
        assertEq(e.token().balanceOf(SINK), 100e18, "borrower kept 100");
        assertTrue(e.vault().getHeldTokenExistence(e.NFT(), e.ID()), "real slot still set");
        assertFalse(e.vault().tokenMapping(e.vault().removeKey(e.NFT(), e.ID())), "wrong slot cleared");
        assertTrue(e.vault().includeKey(e.NFT(), e.ID()) != e.vault().removeKey(e.NFT(), e.ID()), "keys differ");
    }

    function test_control_consistent_key_removes_once_and_liquidation_works() public {
        Token token = new Token();
        Vault vault = new Vault();
        Factory factory = new Factory(vault, 2);
        Lend lend = new Lend(vault, token);
        vault.setFactory(address(factory));
        address nft = address(0xA11C);
        factory.include(nft, 1, address(this));
        factory.include(nft, 2, address(0xB0B));
        token.mint(address(lend), 100e18);
        lend.borrow(nft, 1, 100e18);

        factory.signMultiAssetVault(nft, 1);
        factory.removeConsistent(nft, 1);

        assertFalse(vault.getHeldTokenExistence(nft, 1), "include slot cleared");
        assertEq(factory.nftRemoved(), 1, "one removal");
        assertFalse(vault.closed(), "pool stays open");
        vm.expectRevert(bytes("not held"));
        factory.signMultiAssetVault(nft, 1);

        lend.liquidate(nft, 1);
        assertEq(lend.debt(nft, 1), 0, "debt cleared");
    }
}
