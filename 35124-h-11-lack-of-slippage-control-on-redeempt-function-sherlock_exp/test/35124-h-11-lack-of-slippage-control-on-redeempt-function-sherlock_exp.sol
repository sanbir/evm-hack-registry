// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Asset,
    Exploit,
    MockMarket,
    MockSY,
    PendlePrincipalToken,
    PtToken,
    Terms
} from "./35124-h-11-lack-of-slippage-control-on-redeempt-function-sherlock.sol";

/// Fix: SY.redeem receives the caller's minTokenOut instead of 0.
contract GuardedPendle {
    PtToken public immutable PT;
    MockMarket public immutable MARKET;
    MockSY public immutable SY;
    address public immutable TOKEN_OUT_SY;
    address public immutable BORROW_TOKEN;
    Asset public immutable asset;

    constructor(Asset _asset, PtToken _pt, MockSY _sy, MockMarket _market) {
        asset = _asset;
        PT = _pt;
        SY = _sy;
        MARKET = _market;
        TOKEN_OUT_SY = address(_asset);
        BORROW_TOKEN = address(_asset);
    }

    function executeInstantRedemption(address account, uint256 vaultShares, uint256 minPurchaseAmount)
        external
        returns (uint256 borrowedCurrencyAmount)
    {
        uint256 netPtIn = vaultShares;
        PT.transfer(address(MARKET), netPtIn);
        (uint256 netSyOut,) = MARKET.swapExactPtForSy(address(SY), netPtIn, "");
        uint256 netTokenOut = SY.redeem(address(this), netSyOut, TOKEN_OUT_SY, minPurchaseAmount, true);
        require(TOKEN_OUT_SY == BORROW_TOKEN, "token");
        borrowedCurrencyAmount = netTokenOut;
        asset.transfer(account, borrowedCurrencyAmount);
    }
}

contract Finding35124Test is Test {
    address constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address constant EXPLOIT = 0x15452EC016c4dc8c549E7fe6Ff4b26324Ea8b7A4;
    address constant ASSET = 0x8ea53755A6CB335DD77e8DfBE91078CF210015C7;
    address constant PT = 0x671D353A77015fA0B747f24eb2a50b0E3340BD1d;
    address constant SY = 0xce01759B82FD6cbf9DA468ae79fdcACc4605a5c5;
    address constant MARKET = 0xbd4Fd5A3ceb32dA8dB79559A1C535578c0F8E57D;
    address constant VAULT = 0xE3a787A4E4d21C593625713f44F859D64D7ccfCE;

    function _deploy() internal returns (Exploit e) {
        vm.setNonce(ATTACKER, 1);
        vm.prank(ATTACKER);
        e = new Exploit();
    }

    function test_sandwich_redeems_below_stated_minimum() public {
        Exploit e = _deploy();
        assertEq(address(e), EXPLOIT, "exploit");
        assertEq(address(e.asset()), ASSET, "asset");
        assertEq(address(e.pt()), PT, "pt");
        assertEq(address(e.sy()), SY, "sy");
        assertEq(address(e.market()), MARKET, "market");
        assertEq(address(e.vault()), VAULT, "vault");

        e.run();

        assertEq(e.asset().balanceOf(Terms.USER), Terms.RECEIVED, "user");
        assertEq(e.asset().balanceOf(address(e)), Terms.SKIM, "searcher");
        assertLt(e.asset().balanceOf(Terms.USER), Terms.MIN_OUT, "below min");
        assertEq(Terms.MIN_OUT - e.asset().balanceOf(Terms.USER), Terms.SKIM, "gap");
        assertEq(e.sy().lastMinTokenOut(), 0, "min out");
        assertEq(e.vault().ignoredMin(), Terms.MIN_OUT, "ignored");
        assertEq(e.sy().tokenPerSy(), Terms.WORSE, "price");
    }

    function test_control_min_out_reverts_on_the_same_price() public {
        Asset asset = new Asset();
        PtToken pt = new PtToken();
        MockSY sy = new MockSY(asset);
        MockMarket market = new MockMarket();
        GuardedPendle vault = new GuardedPendle(asset, pt, sy, market);
        pt.mint(address(vault), Terms.SHARES);
        asset.setMinter(address(sy));
        sy.setTokenPerSy(Terms.WORSE);

        vm.expectRevert(bytes("Slippage: INSUFFICIENT_TOKEN_OUT"));
        vault.executeInstantRedemption(Terms.USER, Terms.SHARES, Terms.MIN_OUT);

        assertEq(asset.balanceOf(Terms.USER), 0, "user untouched");
        assertEq(asset.balanceOf(address(this)), 0, "no skim");
    }

    function test_control_fair_price_meets_minimum() public {
        Asset asset = new Asset();
        PtToken pt = new PtToken();
        MockSY sy = new MockSY(asset);
        MockMarket market = new MockMarket();
        GuardedPendle vault = new GuardedPendle(asset, pt, sy, market);
        pt.mint(address(vault), Terms.SHARES);
        asset.setMinter(address(sy));

        uint256 got = vault.executeInstantRedemption(Terms.USER, Terms.SHARES, Terms.MIN_OUT);
        assertEq(got, Terms.MIN_OUT, "full");
        assertEq(asset.balanceOf(Terms.USER), Terms.MIN_OUT, "user");
        assertEq(asset.balanceOf(address(this)), 0, "no skim");
    }
}
