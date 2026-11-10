// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    GaugeFixed,
    Lp,
    PositionManagerFixed,
    Token
} from "./62813-h-6-reward-token-loss-for-lps-during-nft-position-transfer-s.sol";

contract Finding62813Test is Test {
    function test_exploit_buyer_takes_the_lp_rewards() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.oldBalance(), 0, "old LP holds nothing");
        assertEq(e.buyerBalance(), 1_000 ether, "buyer was paid N");
        assertEq(e.stillClaimable(), 0, "nothing left to claim");
        assertEq(e.pm().ownerOf(1), address(e), "buyer holds the NFT");
        assertEq(e.bmx().balanceOf(address(e.lp())), 0, "old LP balance");
    }

    function test_control_checkpoints_to_the_old_lp() public {
        Token bmx = new Token();
        GaugeFixed gauge = new GaugeFixed(bmx);
        PositionManagerFixed pm = new PositionManagerFixed(gauge);
        gauge.setManager(address(pm));
        Lp lp = new Lp();
        address buyer = address(0xBEEF);
        uint256 n = 1_000 ether;

        bmx.mint(address(gauge), n);
        pm.mint(address(lp), 1);
        lp.openFixed(pm, 1, n);
        lp.sellFixed(pm, buyer, 1);

        assertEq(bmx.balanceOf(address(lp)), n, "control pays the recorded LP");
        assertEq(bmx.balanceOf(buyer), 0, "buyer is not paid");
        assertEq(pm.ownerOf(1), buyer, "buyer still receives the NFT");
    }
}
