// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./52222-minting-limit-calculation-may-prevent-legitimate-claims-halb.sol";

/*//////////////////////////////////////////////////////////////
    Pepper — mint limit keyed off totalSupply blocks MINTER airdrops (#52222)
//////////////////////////////////////////////////////////////*/
contract PepperMintLimitTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.pepper().totalSupply(), e.pepper().MINT_LIMIT(), "claims filled limit");
        assertEq(e.pepper().balanceOf(address(e)), 0, "airdrop blocked");
    }

    function test_mintRevertsAfterClaimFillsLimit() public {
        Pepper p = new Pepper();
        address user = makeAddr("user");
        vm.prank(user);
        p.claim();

        vm.expectRevert("Minting exceeds 40% of total supply");
        p.mint(user, 500 ether);
    }
}
