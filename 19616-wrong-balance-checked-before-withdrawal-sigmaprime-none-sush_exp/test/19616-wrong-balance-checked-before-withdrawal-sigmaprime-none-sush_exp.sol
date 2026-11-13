// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Asset,
    BentoBox,
    SushiXSwap
} from "./19616-wrong-balance-checked-before-withdrawal-sigmaprime-none-sush.sol";

contract SushiXSwapFixed is SushiXSwap {
    constructor(BentoBox bento_) SushiXSwap(bento_) {}

    function cook(uint8 action, bytes calldata data) external override {
        if (action == ACTION_DST_WITHDRAW_FROM_BENTOBOX) {
            (address token, address to, uint256 amount, uint256 shares) =
                abi.decode(data, (address, address, uint256, uint256));
            if (amount == 0 && shares == 0) {
                shares = bento.balanceOf(token, address(this));
            }
            bento.withdraw(token, address(this), to, amount, shares);
        }
    }
}

contract Finding19616Test is Test {
    address internal victim = address(0xBEEF);

    function test_exploit_zero_shortcut_leaves_shares_for_anyone() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e)), 1000, "attacker received the stuck shares");
        assertEq(e.token().balanceOf(victim), 0, "intended recipient got 0");
        assertEq(e.bento().balanceOf(address(e.token()), address(e.swap())), 0, "box cleared by attacker");
    }

    function test_control_zero_shortcut_pays_the_recipient() public {
        Asset token = new Asset();
        BentoBox bento = new BentoBox();
        SushiXSwapFixed swap = new SushiXSwapFixed(bento);
        bento.credit(address(token), address(swap), 1000);
        bytes memory sweep = abi.encode(address(token), victim, uint256(0), uint256(0));
        swap.cook(swap.ACTION_DST_WITHDRAW_FROM_BENTOBOX(), sweep);
        assertEq(token.balanceOf(victim), 1000, "recipient received the bento balance");
        assertEq(bento.balanceOf(address(token), address(swap)), 0, "nothing left to steal");
        bytes memory steal = abi.encode(address(token), address(this), uint256(1000), uint256(0));
        (bool ok,) = address(swap).call(
            abi.encodeWithSelector(swap.cook.selector, swap.ACTION_DST_WITHDRAW_FROM_BENTOBOX(), steal)
        );
        assertFalse(ok, "second withdraw must revert");
        assertEq(token.balanceOf(address(this)), 0, "attacker got nothing");
    }
}
