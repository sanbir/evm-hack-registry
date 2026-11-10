// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, VeryFastRouter, LSSVMPair, Erc20} from "./18413-linearity-assumption-on-the-royalty-can-lead-to-denial-of-se.sol";

contract Finding18413Test is Test {
    function test_exploit_linear_quote_reverts_and_nfts_stay() public {
        Exploit e = new Exploit();
        e.run();

        assertFalse(e.sold(), "sold");
        assertEq(e.linearQuote(), 0.9 ether, "linear");
        assertEq(e.actualQuote(), 0.2 ether, "actual");
        assertEq(e.nftsStuck(), 2, "stuck");
        assertEq(e.nft().balanceOf(address(e.pair())), 2, "pair nfts");
        assertEq(e.nft().balanceOf(address(e)), 0, "seller still holds nfts");
        assertEq(e.ethPaid(), 0, "paid");
        assertEq(e.weth().balanceOf(address(e.pair())), 1 ether, "weth");

        console2.log("linear min output");
        console2.log(e.linearQuote());
        console2.log("actual output the curve can pay");
        console2.log(e.actualQuote());
        console2.log("NFTs stuck in the pair");
        console2.log(e.nftsStuck());
    }

    function test_control_actual_curve_pays_and_releases_nfts() public {
        Exploit e = new Exploit();
        uint256 paid = e.runControl();

        assertEq(paid, 0.2 ether, "paid");
        assertEq(e.weth().balanceOf(address(e)), 0.2 ether, "seller weth");
        assertEq(e.nft().balanceOf(address(e.pair())), 0, "nfts stuck");
        assertEq(e.nft().balanceOf(address(e.router())), 2, "nfts sold");
        assertEq(e.weth().balanceOf(address(e.pair())), 0.8 ether, "royalty stayed with the pair");

        console2.log("control paid");
        console2.log(paid);
        console2.log("NFTs left in the pair");
        console2.log(e.nft().balanceOf(address(e.pair())));
    }
}
