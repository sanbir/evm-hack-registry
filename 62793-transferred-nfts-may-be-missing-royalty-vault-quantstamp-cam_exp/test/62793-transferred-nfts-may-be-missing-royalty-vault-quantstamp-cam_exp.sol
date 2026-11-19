// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Erc20, IpNFT, MarketplaceFixed} from "./62793-transferred-nfts-may-be-missing-royalty-vault-quantstamp-cam.sol";

contract PoC_62793_RoyaltyPaidToZero is Test {
    uint256 internal constant SHARE = 100 ether;
    address internal constant ALICE = address(0x000000000000000000000000000000000000a11c);
    address internal constant BOB = address(0x0000000000000000000000000000000000000B0b);

    function test_royalty_for_new_owner_is_burned() public {
        Exploit exp = new Exploit();
        exp.run();

        assertEq(exp.pay().balanceOf(address(0)), SHARE, "100 PAY burned");
        assertEq(exp.market().paidTo(), address(0), "vault was zero");
        assertEq(exp.nft().royaltyVaults(BOB), address(0), "bob has no vault");
        assertTrue(exp.nft().royaltyVaults(ALICE) != address(0), "alice vault exists");
    }

    function test_control_getOrCreate_pays_the_new_owner() public {
        Erc20 pay = new Erc20("PAY");
        IpNFT nft = new IpNFT();
        MarketplaceFixed market = new MarketplaceFixed(nft);
        pay.mint(address(this), SHARE);
        nft.mint(ALICE);
        nft.transfer(ALICE, BOB);
        pay.approve(address(market), SHARE);

        market.buyAccess(address(pay), address(this), BOB, SHARE);

        address vault = nft.royaltyVaults(BOB);
        assertTrue(vault != address(0), "vault created");
        assertEq(pay.balanceOf(address(0)), 0, "nothing burned");
        assertEq(pay.balanceOf(vault), SHARE, "bob's vault received the share");
    }
}
