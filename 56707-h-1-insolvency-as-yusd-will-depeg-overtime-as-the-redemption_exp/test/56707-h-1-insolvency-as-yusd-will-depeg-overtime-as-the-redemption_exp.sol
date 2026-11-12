// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Token, Insurance, AegisMinting} from "./56707-h-1-insolvency-as-yusd-will-depeg-overtime-as-the-redemption.sol";

contract AegisMintingFixed is AegisMinting {
    constructor(Token yusd_, Token collateral_, address insurance_, uint256 feeBP)
        AegisMinting(yusd_, collateral_, insurance_, feeBP)
    {}

    function approveRedeemRequest(address userWallet, uint256 amount)
        external
        override
        returns (uint256 collateralAmount, uint256 burnAmount, uint256 fee)
    {
        (burnAmount, fee) = _calculateInsuranceFundFeeFromAmount(amount, redeemFeeBP);
        collateralAmount = _calculateRedeemMinCollateralAmount(burnAmount);
        paidCollateral = collateralAmount;
        if (fee > 0) {
            yusd.transfer(insuranceFund, fee);
        }
        collateral.transfer(userWallet, collateralAmount);
        yusd.burn(burnAmount);
        shortfall = 0;
    }
}

contract Finding56707Test is Test {
    function test_exploit_pays_100_when_fair_is_90() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.collateral().balanceOf(address(e)), 100, "redeemer received 100");
        assertEq(e.minting().shortfall(), 10, "pool is short 10");
        assertEq(e.yusd().totalSupply(), 10, "10 unbacked yusd remain");
    }

    function test_control_pays_the_fair_90() public {
        Token collateral = new Token();
        Token yusd = new Token();
        Insurance insurance = new Insurance();
        AegisMintingFixed minting = new AegisMintingFixed(yusd, collateral, address(insurance), 1000);
        collateral.mint(address(minting), 100);
        yusd.mint(address(minting), 100);
        (uint256 received, uint256 burned, uint256 fee) = minting.approveRedeemRequest(address(this), 100);
        assertEq(received, 90, "fair collateral is 90");
        assertEq(burned, 90, "90 burned");
        assertEq(fee, 10, "fee 10");
        assertEq(minting.shortfall(), 0, "not short");
        assertEq(collateral.balanceOf(address(this)), 90, "redeemer got 90");
        assertEq(collateral.balanceOf(address(minting)), 10, "10 collateral still backs the fee");
        assertEq(yusd.balanceOf(address(insurance)), 10, "fee yusd is backed");
    }
}
