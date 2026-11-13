// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    PartnerNFT,
    Reward,
    CollectionFixed
} from "./37688-unrestricted-repeated-minting-via-partner-nft-transfer-explo.sol";

contract Finding37688Test is Test {
    function test_exploit_one_partner_nft_mints_three_times() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.mintedCount(), 3, "3 mints");
        assertEq(e.lootBalance(), 3 ether, "3 reward tokens");
        assertEq(e.lootBalance() - 1 ether, 2 ether, "2 extra");
        assertEq(e.reward().balanceOf(address(e.collection())), 0, "treasury empty");
        assertEq(e.partner().ownerOf(1), address(e.third()), "same partner id moved");
    }

    function test_control_per_id_limit_pays_once() public {
        PartnerNFT partner = new PartnerNFT();
        Reward reward = new Reward();
        CollectionFixed collection = new CollectionFixed(partner, reward);
        reward.mint(address(collection), 3 ether);
        partner.mint(address(this), 7);
        collection.partnerFreeMint(address(this), 7);
        partner.transfer(address(0xBEEF), 7);
        vm.prank(address(0xBEEF));
        vm.expectRevert(bytes("24h"));
        collection.partnerFreeMint(address(0xBEEF), 7);
        assertEq(reward.balanceOf(address(this)), 1 ether, "one payout");
        assertEq(reward.balanceOf(address(collection)), 2 ether, "rest stays");
    }
}
