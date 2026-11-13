// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Asset, Treasury, ERC4626iFixed} from
    "./46676-amount-of-protocol-fees-owed-will-be-more-than-intended-in-f.sol";

contract Finding46676Test is Test {
    function test_exploit_first_claim_bills_1700_extra() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.vault().amountOwed(), 1_700_086_400 * 1e12, "billed");
        assertEq(e.vault().fairOwed(), 86_400 * 1e12, "fair");
        assertEq(e.vault().amountOwed() - e.vault().fairOwed(), 1_700 ether, "excess");
        assertEq(e.asset().balanceOf(address(e.treasury())), 1_700_086_400 * 1e12, "treasury");
        assertEq(e.asset().balanceOf(address(e.vault())), 0, "vault empty");
    }

    function test_control_first_claim_uses_campaign_start() public {
        Asset asset = new Asset();
        Treasury treasury = new Treasury();
        ERC4626iFixed fixedVault = new ERC4626iFixed(asset);
        uint256 start = 1_700_000_000;
        uint256 end = 1_700_086_400;
        uint256 rate = 1e12;
        fixedVault.configure(address(treasury), 1, start, end, rate);
        uint256 billed = end * rate;
        asset.mint(address(fixedVault), billed);
        fixedVault.claimProtocolFees(1);
        assertEq(fixedVault.amountOwed(), 86_400 * rate, "fair fee");
        assertEq(asset.balanceOf(address(treasury)), 86_400 * rate, "treasury fair");
        assertEq(asset.balanceOf(address(fixedVault)), 1_700 ether, "depositors keep 1700");
    }
}
