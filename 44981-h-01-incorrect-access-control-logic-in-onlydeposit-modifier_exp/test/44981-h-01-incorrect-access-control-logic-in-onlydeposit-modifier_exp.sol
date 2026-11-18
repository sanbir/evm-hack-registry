// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Messaging, Deposit} from
    "./44981-h-01-incorrect-access-control-logic-in-onlydeposit-modifier.sol";

contract Finding44981Test is Test {
    function test_exploit_both_deposit_contracts_are_rejected() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.ethRejected(), "eth");
        assertTrue(e.usdRejected(), "usd");
        assertEq(e.messaging().sent(), 0, "no message");
    }

    function test_control_and_lets_either_deposit_contract_send() public {
        Messaging m = new Messaging(true);
        Deposit ethDep = new Deposit(m);
        Deposit usdDep = new Deposit(m);
        m.setDeposits(address(ethDep), address(usdDep));
        ethDep.bridge(bytes("eth-user"));
        usdDep.bridge(bytes("usd-user"));
        assertEq(m.sent(), 2, "both messages delivered");
        (bool ok,) = address(this).call(abi.encodeWithSelector(this.bridgeFromStranger.selector, m));
        assertFalse(ok, "stranger must still revert");
    }

    function bridgeFromStranger(Messaging m) external {
        m.sendMessage(bytes("nope"), 101, 0);
    }
}
