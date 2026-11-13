// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, Treasury, FeeCollectorFixed, Payer} from
    "./57207-treasury-balance-tracking-bypass-in-feecollector-codehawks-r.sol";

contract Finding57207Test is Test {
    function test_exploit_direct_transfer_locks_1000_raac_in_treasury() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stuck(), 1000 ether, "1000 stuck");
        assertEq(e.token().balanceOf(address(e.treasury())), 1000 ether, "actual");
        assertEq(e.treasury().getBalance(address(e.token())), 0, "accounted stays 0");
        assertEq(e.token().balanceOf(address(e.collector())), 0, "collector empty");
    }

    function test_control_deposit_lets_the_treasury_withdraw_1000() public {
        Token token = new Token();
        Treasury treasury = new Treasury();
        FeeCollectorFixed collector = new FeeCollectorFixed(token, treasury, address(this));
        Payer payer = new Payer();
        token.mint(address(payer), 1000 ether);

        payer.payFixed(collector, token, 1000 ether);
        collector.distributeCollectedFees();

        assertEq(treasury.getBalance(address(token)), 1000 ether, "accounted");
        assertEq(token.balanceOf(address(treasury)), 1000 ether, "actual");
        treasury.withdraw(address(token), 1000 ether, address(this));
        assertEq(token.balanceOf(address(treasury)), 0, "swept");
        assertEq(token.balanceOf(address(this)), 1000 ether, "recovered");
        assertEq(treasury.getBalance(address(token)), 0, "accounted cleared");
    }
}
