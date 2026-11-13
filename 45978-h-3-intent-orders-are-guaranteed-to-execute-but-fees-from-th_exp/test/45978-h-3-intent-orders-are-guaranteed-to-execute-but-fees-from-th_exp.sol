// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Collateral, MarketFixed} from
    "./45978-h-3-intent-orders-are-guaranteed-to-execute-but-fees-from-th.sol";

contract Finding45978Test is Test {
    function test_exploit_withdraws_margin_and_claims_referral() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.claimed(), 100 ether, "claimed");
        assertEq(e.debt(), -500 ether, "debt");
        assertEq(e.token().balanceOf(address(e)), 200 ether, "balance");
        assertEq(e.token().balanceOf(address(e.market())), 900 ether, "market");
    }

    function test_control_pending_fee_blocks_the_full_withdraw() public {
        Collateral token = new Collateral();
        MarketFixed fixedM = new MarketFixed(token);
        token.mint(address(this), 100 ether);
        token.approve(address(fixedM), 100 ether);
        fixedM.deposit(address(this), 100 ether);
        fixedM.openAndCloseIntent(address(this), address(this), 5000 ether);
        vm.expectRevert(bytes("MarketInsufficientMarginError"));
        fixedM.withdraw(address(this), 100 ether);
        assertEq(token.balanceOf(address(fixedM)), 100 ether, "margin stays");
        assertEq(fixedM.pendingFee(address(this)), 500 ether, "fee reserved");
    }
}
