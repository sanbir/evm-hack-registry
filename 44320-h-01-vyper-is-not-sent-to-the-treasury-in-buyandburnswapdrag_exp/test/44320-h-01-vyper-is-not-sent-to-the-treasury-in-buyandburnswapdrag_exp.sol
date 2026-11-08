// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BuyAndBurn, Exploit, Token} from "./44320-h-01-vyper-is-not-sent-to-the-treasury-in-buyandburnswapdrag.sol";

contract BuyAndBurnFixed is BuyAndBurn {
    constructor(Token _dragonX, Token _vyper, address _liquidity) BuyAndBurn(_dragonX, _vyper, _liquidity) {}

    function swapDragonXToVyperAndBurn(uint32 _deadline) external override intervalUpdate notExpired(_deadline) {
        uint256 incentive = wmul(currInterval.amountAllocated, INCENTIVE_FEE);
        uint256 dragonXToSwapAndBurn = currInterval.amountAllocated - incentive;
        uint256 vyperAmount = swapExactInput(address(dragonX), address(vyper), dragonXToSwapAndBurn, 0, _deadline);
        vyper.transfer(liquidity, wmul(vyperAmount, uint256(0.08e18)));
        vyper.transfer(address(vyper.treasury()), wmul(vyperAmount, uint256(0.5e18)));
        burnVyper();
        dragonX.transfer(msg.sender, incentive);
    }
}

contract Finding44320Test is Test {
    function test_exploit_treasury_gets_zero_and_92_is_burned() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.vyper().balanceOf(address(e.treasury())), 0, "treasury 0");
        assertEq(e.vyper().balanceOf(address(e.liquidity())), 8 ether, "lp 8");
        assertEq(e.vyper().balanceOf(e.burner().DEAD()), 92 ether, "burned 92");
        assertEq(e.vyper().balanceOf(address(e.burner())), 0, "contract empty");
        console.log("treasury", e.vyper().balanceOf(address(e.treasury())));
        console.log("liquidity", e.vyper().balanceOf(address(e.liquidity())));
        console.log("burned", e.vyper().balanceOf(e.burner().DEAD()));
    }

    function test_control_treasury_receives_50_and_42_is_burned() public {
        Token dragonX = new Token("DragonX", "DRX", address(0));
        Token vyper = new Token("Vyper", "VYPER", address(0));
        address treasury = address(0xBEEF);
        // treasury() on the token must be the receiver. Redeploy with that address.
        vyper = new Token("Vyper", "VYPER", treasury);
        BuyAndBurnFixed fixedBurner = new BuyAndBurnFixed(dragonX, vyper, address(0xCAFE));
        dragonX.mint(address(fixedBurner), 1000 ether);
        fixedBurner.seed(1000 ether);
        fixedBurner.swapDragonXToVyperAndBurn(type(uint32).max);
        assertEq(vyper.balanceOf(treasury), 50 ether, "treasury 50");
        assertEq(vyper.balanceOf(address(0xCAFE)), 8 ether, "lp 8");
        assertEq(vyper.balanceOf(fixedBurner.DEAD()), 42 ether, "burned 42");
        console.log("control treasury", vyper.balanceOf(treasury));
        console.log("control burned", vyper.balanceOf(fixedBurner.DEAD()));
    }
}
