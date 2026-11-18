// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Collateral, IndexToken, VaultRouterBranchFixed} from
    "./49975-lps-will-not-recieve-their-full-amount-of-collateral-on-rede.sol";

contract Finding49975Test is Test {
    function test_exploit_redeem_reverts_and_locks_collateral() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stillLocked(), 1800 ether, "1800 stays in the router");
        assertTrue(e.redeemReverted(), "redeem reverted");
        assertGt(e.quoted(), 1800 ether, "quote exceeds assets");
        assertEq(e.fair(), 27272727272727272727, "fair quote");
    }

    function test_control_scaled_supply_pays_fair_collateral() public {
        Collateral collateral = new Collateral();
        IndexToken index = new IndexToken();
        VaultRouterBranchFixed router = new VaultRouterBranchFixed(index, collateral);
        index.mint(address(0xBEEF), 1320e6);
        collateral.mint(address(router), 1800 ether);
        uint256 paid = router.redeem(20 ether);
        assertEq(paid, 27272727272727272727, "pays 27.27");
        assertEq(collateral.balanceOf(address(this)), 27272727272727272727, "lp received it");
        assertEq(collateral.balanceOf(address(router)), 1800 ether - 27272727272727272727, "rest remains for other lps");
    }
}
