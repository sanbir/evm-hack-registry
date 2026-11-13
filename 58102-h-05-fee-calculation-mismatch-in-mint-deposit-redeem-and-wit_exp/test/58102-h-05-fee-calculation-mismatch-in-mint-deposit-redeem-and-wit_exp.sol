// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {As4626Fixed, Asset, Exploit} from "./58102-h-05-fee-calculation-mismatch-in-mint-deposit-redeem-and-wit.sol";

contract Finding58102Test is Test {
    function test_deposit_and_redeem_overcharge_by_one() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.mintCost(), 110 ether, "mint of 100 costs 110");
        assertEq(e.depositedShares(), 99 ether, "deposit of 110 mints 99");
        assertEq(e.fairDeposit(), 100 ether, "fair deposit mints 100");
        assertEq(e.redeemed(), 99 ether, "redeem of 110 pays 99");
        assertEq(e.fairRedeem(), 100 ether, "fair redeem pays 100");
    }

    function test_control_charges_the_gross_fee() public {
        Asset asset = new Asset();
        As4626Fixed vault = new As4626Fixed(asset);
        asset.mint(address(this), 220 ether);
        asset.approve(address(vault), type(uint256).max);
        vault.seed(address(this), 110 ether, 110 ether);
        uint256 shares = vault.deposit(110 ether, address(this));
        uint256 assets = vault.redeem(110 ether, address(this));
        assertEq(shares, 100 ether, "deposit mints 100");
        assertEq(assets, 100 ether, "redeem pays 100");
    }
}
