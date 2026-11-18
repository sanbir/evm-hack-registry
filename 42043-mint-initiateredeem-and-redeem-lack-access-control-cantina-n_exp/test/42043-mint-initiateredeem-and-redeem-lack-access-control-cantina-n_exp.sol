// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, LevelMintingFixed, Victim, Order, OrderType} from
    "./42043-mint-initiateredeem-and-redeem-lack-access-control-cantina-n.sol";

contract Finding42043Test is Test {
    function test_exploit_redeem_pulls_victim_collateral() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stolen(), 50 ether, "50 stETH");
        assertEq(e.collateral().balanceOf(address(e)), 50 ether, "attacker");
        assertEq(e.lvlusd().balanceOf(address(e.victim())), 0, "lvl taken");
        assertEq(e.collateral().balanceOf(address(e.minting())), 0, "pool empty");
    }

    function test_control_benefactor_must_be_caller() public {
        Token lvl = new Token("lvlUSD");
        Token col = new Token("stETH");
        LevelMintingFixed minting = new LevelMintingFixed(lvl, col);
        Victim victim = new Victim(lvl, address(minting));
        lvl.mint(address(victim), 50 ether);
        col.mint(address(minting), 50 ether);

        Order memory stolen = Order({
            order_type: OrderType.REDEEM,
            nonce: 3,
            benefactor: address(victim),
            beneficiary: address(this),
            collateral_asset: address(col),
            lvlusd_amount: 50 ether,
            collateral_amount: 50 ether
        });
        vm.expectRevert(bytes("benefactor"));
        minting.initiateRedeem(stolen);

        assertEq(lvl.balanceOf(address(victim)), 50 ether, "lvl stays");
        assertEq(col.balanceOf(address(minting)), 50 ether, "collateral stays");

        lvl.mint(address(this), 50 ether);
        lvl.approve(address(minting), 50 ether);
        col.mint(address(minting), 50 ether);
        Order memory self = Order({
            order_type: OrderType.REDEEM,
            nonce: 4,
            benefactor: address(this),
            beneficiary: address(this),
            collateral_asset: address(col),
            lvlusd_amount: 50 ether,
            collateral_amount: 50 ether
        });
        minting.initiateRedeem(self);
        assertEq(col.balanceOf(address(this)), 50 ether, "self redeem pays 50");
        assertEq(lvl.balanceOf(address(victim)), 50 ether, "victim untouched");
    }
}
