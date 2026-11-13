// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, BridgeFixed, BobFixed} from
    "./62775-missing-check-of-msgvalue-in-bridgeout-function-allows-dos-o.sol";

contract Finding62775Test is Test {
    function test_exploit_zero_value_deposit_takes_next_deposit() public {
        Exploit e = new Exploit();
        e.run{value: 10 ether}();

        assertEq(address(e).balance, 10 ether, "attacker received 10");
        assertEq(address(e.bridge()).balance, 0, "bridge empty");
        assertEq(address(e.bob()).balance, 0, "bob received 0");
    }

    function test_control_requires_msg_value() public {
        BridgeFixed bridge = new BridgeFixed();
        BobFixed bob = new BobFixed(bridge);

        bool queued = true;
        try bridge.bridgeOut{value: 0}(10 ether) {
            queued = true;
        } catch {
            queued = false;
        }
        assertFalse(queued, "zero value rejected");

        bob.deposit{value: 10 ether}();
        assertEq(address(bridge).balance, 10 ether, "bob's 10 is escrowed");
        bridge.releaseNext();
        assertEq(address(bob).balance, 10 ether, "bob is paid his own 10");
        assertEq(address(bridge).balance, 0, "bridge settled");
    }
}
