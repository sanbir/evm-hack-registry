// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Pay, HoneyJar, HoneyBoxFixed} from
    "./20531-c-03-anyone-can-mint-all-nfts-through-the-public-mint-before.sol";

contract Finding20531Test is Test {
    function test_exploit_mints_all_100_before_any_bundle() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.honey().balanceOf(address(e)), 100, "100 jars");
        assertEq(e.box().minted(0), 100, "supply filled");
        assertEq(e.box().bundlesAdded(), 0, "no bundle");
        assertEq(e.pay().balanceOf(address(e.box())), 9.9 ether, "paid 9.9");
        assertTrue(e.supplyClosed(), "closed");
    }

    function test_control_zero_public_mint_time_reverts() public {
        Pay pay = new Pay();
        HoneyJar honey = new HoneyJar();
        HoneyBoxFixed fixedBox = new HoneyBoxFixed(honey, pay);
        pay.mint(address(this), 9.9 ether);
        pay.approve(address(fixedBox), 9.9 ether);
        vm.expectRevert(bytes("NotSleeping"));
        fixedBox.mekHoneyJarWithERC20(0, 100);
        assertEq(honey.balanceOf(address(this)), 0, "none minted");
    }
}
