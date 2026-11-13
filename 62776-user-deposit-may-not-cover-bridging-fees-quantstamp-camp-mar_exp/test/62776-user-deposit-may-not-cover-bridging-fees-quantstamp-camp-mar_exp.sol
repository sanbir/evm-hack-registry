// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, FeeSink, CampBridgeFixed, DepositorFixed} from
    "./62776-user-deposit-may-not-cover-bridging-fees-quantstamp-camp-mar.sol";

contract Finding62776Test is Test {
    function test_exploit_fee_comes_out_of_the_next_deposit() public {
        Exploit e = new Exploit();
        e.run{value: 200 ether}();

        assertEq(address(e.feeSink()).balance, 10 ether, "fee sink took 10");
        assertEq(address(e.bridge()).balance, 90 ether, "90 of Bob stays stuck");
        assertEq(address(e.bob()).balance, 0, "Bob received 0");
        assertEq(address(e.alice()).balance, 100 ether, "Alice was fully paid");
    }

    function test_control_collects_the_fee_up_front() public {
        FeeSink feeSink = new FeeSink();
        CampBridgeFixed bridge = new CampBridgeFixed(feeSink);
        DepositorFixed alice = new DepositorFixed(bridge);
        DepositorFixed bob = new DepositorFixed(bridge);

        alice.deposit{value: 110 ether}(100 ether);
        bob.deposit{value: 110 ether}(100 ether);
        bridge.send(0);
        bridge.send(1);

        assertEq(address(alice).balance, 100 ether, "alice received 100");
        assertEq(address(bob).balance, 100 ether, "bob received 100");
        assertEq(address(feeSink).balance, 20 ether, "both fees were prepaid");
        assertEq(address(bridge).balance, 0, "nothing stuck");
    }
}
