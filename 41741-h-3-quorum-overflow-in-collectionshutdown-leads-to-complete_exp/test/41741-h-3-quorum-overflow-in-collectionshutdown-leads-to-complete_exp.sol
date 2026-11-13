// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Eth, CollectionToken, CollectionShutdownFixed} from
    "./41741-h-3-quorum-overflow-in-collectionshutdown-leads-to-complete.sol";

contract Finding41741Test is Test {
    function test_exploit_wrapped_quorum_pays_20646_ether() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.paid(), 20646851990532126875611, "paid");
        assertEq(e.eth().balanceOf(address(e)), 20646851990532126875611, "attacker");
        assertEq(uint256(e.shutdown().quorumVotes()), 14990178654931275218944, "quorum");
        assertEq(e.eth().balanceOf(address(e.shutdown())), 30000 ether - e.paid(), "left");
    }

    function test_control_full_quorum_pays_the_1_ether_sale() public {
        Eth eth = new Eth();
        CollectionToken token = new CollectionToken();
        CollectionShutdownFixed fixedShutdown = new CollectionShutdownFixed(token, eth);
        uint256 supply = 0.6190 ether * 10 ** 9;
        token.mint(address(this), supply);
        eth.mint(address(fixedShutdown), 30000 ether);
        token.approve(address(fixedShutdown), supply);
        fixedShutdown.start(address(token));
        uint256 paid = fixedShutdown.claim(address(token), address(this));

        assertEq(paid, 1 ether, "fair share of the sale");
        assertEq(eth.balanceOf(address(this)), 1 ether, "claimant");
        assertEq(eth.balanceOf(address(fixedShutdown)), 29999 ether, "pot remains");
    }
}
