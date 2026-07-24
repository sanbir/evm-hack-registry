// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./37916-h-02-griefing-attack-on-sellers-airdrop-benefits-code4rena-t.sol";

contract GriefAirdropTest is Test {
    function test_buyer_burn_slashes_seller_airdrop() public {
        Exploit exp = new Exploit();
        Airdrop airdrop = exp.airdrop();
        SellerActor seller = exp.seller();

        exp.run();

        assertEq(airdrop.userInfo(address(seller)), 0, "seller airdrop slashed");
        assertEq(airdrop.totalValue(), 0, "total airdrop zero");
    }

    /// @notice Control: if the original minter burns their own token, airdrop
    ///         reduction is intended behaviour (not griefing).
    function test_control_minter_self_burn_is_intended() public {
        Airdrop airdrop = new Airdrop();
        TraitForgeNft nft = new TraitForgeNft(airdrop);
        SellerActor seller = new SellerActor(nft);

        uint256 id = nft.mint(address(seller), 500);
        assertEq(airdrop.userInfo(address(seller)), 500);

        // Self-burn via temporary ownership: seller already owns it.
        // Use a self-burn helper on SellerActor path — mint to this test contract instead.
        Airdrop a2 = new Airdrop();
        TraitForgeNft n2 = new TraitForgeNft(a2);
        uint256 id2 = n2.mint(address(this), 500);
        n2.burn(id2);
        assertEq(a2.userInfo(address(this)), 0, "self-burn correctly removes own airdrop");
        id; seller; // silence
    }
}
