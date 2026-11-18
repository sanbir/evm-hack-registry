// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit, BuyOrder, MockToken, MockNFT, Creator, Seller} from "./44228-h-5-after-the-buyorder-is-completed-the-order-creator-does-n.sol";

contract Finding44228Test is Test {
    function test_creator_does_not_receive_nft() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.nftOwnerAfter(), address(e.order()), "stuck");
        assertEq(e.aero().balanceOf(address(e.seller())), 1000 ether, "seller paid");
        assertEq(e.aero().balanceOf(address(e.creator())), 0, "creator paid");
    }

    function test_control_fixed_delivers_nft_to_creator() public {
        MockToken aero = new MockToken("AERO");
        MockNFT nft = new MockNFT();
        BuyOrder order = new BuyOrder(aero, nft);
        Creator creator = new Creator();
        Seller seller = new Seller();
        aero.mint(address(creator), 1000 ether);
        nft.mint(address(seller), 7);
        creator.open(order, aero);
        // sell via the fixed path
        vm.prank(address(seller));
        nft.approve(address(order), 7);
        vm.prank(address(seller));
        order.sellNFTFixed(7);
        assertEq(nft.ownerOf(7), address(creator), "creator received NFT");
    }
}
