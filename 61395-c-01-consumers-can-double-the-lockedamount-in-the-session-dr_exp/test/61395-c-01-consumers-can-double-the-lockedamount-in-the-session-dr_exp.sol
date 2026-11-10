// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    CredibleAccountModuleFixed,
    Exploit,
    SmartWallet,
    Token
} from "./61395-c-01-consumers-can-double-the-lockedamount-in-the-session-dr.sol";

contract Finding61395Test is Test {
    function test_exploit_takes_extra_and_claim_pays_zero() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.claimed(), 2_000 ether, "claimedAmount is twice the lock");
        assertEq(e.extraTaken(), 1_000 ether, "session caller took the extra lock");
        assertEq(e.token().balanceOf(address(this)), 1_000 ether, "attacker balance is the extra");
        assertEq(e.token().balanceOf(e.INVOICE()), 1_000 ether, "invoice received one lock");
        assertEq(e.token().balanceOf(address(e.wallet())), 0, "wallet lost both");
        assertFalse(e.sessionSettled(), "claimed no longer equals locked");
        assertEq(e.claimPaid(), 0, "claim pays 0");
        assertEq(e.EXTRA(), 1_000 ether, "harm magnitude");
    }

    function test_control_counts_the_lock_once() public {
        Token token = new Token();
        CredibleAccountModuleFixed module = new CredibleAccountModuleFixed();
        SmartWallet wallet = new SmartWallet();
        address invoice = address(0x2222222222222222222222222222222222222222);
        uint256 lock = 1_000 ether;

        token.mint(address(wallet), lock * 2);
        wallet.approveToken(token, address(module));
        module.enableSession(address(this), address(token), lock);

        uint256 taken = module.executeBatch(address(this), address(wallet), address(token), invoice, address(this));
        assertEq(taken, lock, "only one item executes");
        assertEq(module.claimedAmountOf(address(this)), lock, "lock counted once");
        assertEq(token.balanceOf(address(this)), 0, "caller received no extra");
        assertEq(token.balanceOf(invoice), lock, "invoice received the single lock");
        assertEq(token.balanceOf(address(wallet)), lock, "second lock stayed in the wallet");
        assertTrue(module.isSessionClaimed(address(this)), "session can be claimed");
        assertEq(module.claim(address(this)), lock, "claim pays the lock");
    }
}
