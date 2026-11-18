// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit, WETH, Treasury, Auction, OwnerSink} from "./44395-c-01-frontrunning-the-auction-creation-and-settlement-to-low.sol";

contract Finding44395Test is Test {
    function test_exploit_frontrun_pays_owner_10_and_attacker_90() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.fairFloor(), 100 ether, "fair");
        assertEq(e.auction().listedPrice(), 10 ether, "listed");
        assertEq(e.auction().ownerReceived(), 10 ether, "owner paid");
        assertEq(e.weth().balanceOf(address(e.owner())), 10 ether, "owner bal");
        assertEq(e.weth().balanceOf(address(e)), 90 ether, "attacker");
    }

    function test_control_no_claim_pays_the_full_floor() public {
        WETH weth = new WETH();
        Treasury treasury = new Treasury(weth);
        OwnerSink owner = new OwnerSink();
        Auction auction = new Auction(treasury, weth, address(owner));
        weth.mint(address(treasury), 100 ether);
        auction.createAuction();
        assertEq(auction.listedPrice(), 100 ether, "full list");
        auction.settle();
        assertEq(auction.ownerReceived(), 100 ether, "full pay");
        assertEq(weth.balanceOf(address(owner)), 100 ether, "owner");
    }
}
