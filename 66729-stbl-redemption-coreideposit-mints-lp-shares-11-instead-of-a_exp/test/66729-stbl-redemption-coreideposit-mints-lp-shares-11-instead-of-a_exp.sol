// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, USST, YLD, RedemptionFixed, Actor} from
    "./66729-stbl-redemption-coreideposit-mints-lp-shares-11-instead-of-a.sol";

contract Finding66729Test is Test {
    function test_exploit_charlie_loses_750_to_alice() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.charlieClaim(), 2250 ether, "charlie claim");
        assertEq(e.aliceGain(), 750 ether, "alice gain");
        assertEq(e.usst().balanceOf(address(e.alice())), 3750 ether, "alice paid");
    }

    function test_control_exchange_rate_mint_lets_charlie_withdraw_3000() public {
        USST usst = new USST();
        YLD yld = new YLD();
        RedemptionFixed redemption = new RedemptionFixed(usst, yld);
        Actor alice = new Actor();
        Actor bob = new Actor();
        Actor charlie = new Actor();
        uint256 aliceId = yld.issue(address(alice), 5000 ether);
        alice.call(address(redemption), abi.encodeWithSignature("deposit(uint256)", aliceId));
        usst.mint(address(redemption), 5000 ether);
        usst.mint(address(bob), 2000 ether);
        bob.approve(usst, address(redemption), 2000 ether);
        bob.call(address(redemption), abi.encodeWithSignature("redeem(uint256)", 2000 ether));
        uint256 charlieId = yld.issue(address(charlie), 3000 ether);
        charlie.call(address(redemption), abi.encodeWithSignature("deposit(uint256)", charlieId));
        usst.mint(address(redemption), 3000 ether);
        assertEq(redemption.iFetchShare(address(charlie)), 3000 ether, "par");
        charlie.call(address(redemption), abi.encodeWithSignature("withdraw()"));
        assertEq(usst.balanceOf(address(charlie)), 3000 ether, "full");
    }
}
