// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./11323-h12-unresponsive-service-provider-locks-delegator-stake-open.sol";

contract Finding11323Test is Test {
    function test_exploit_undelegate_reverts_and_locks_1000() public {
        vm.roll(100);
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e.mgr())), e.LOCKED(), "1000 locked");
        assertEq(e.token().balanceOf(address(e)), 0, "delegator received nothing");
    }

    function test_control_claim_for_sp_then_exit() public {
        vm.roll(100);
        Exploit e = new Exploit();
        e.token().mint(address(this), 1000 ether);
        e.mgr().delegate(1000 ether);
        e.staking().updateClaimHistory(address(uint160(0x2222)), 1);
        uint256 got = e.mgr().undelegateStake();
        assertEq(got, 1000 ether, "exited");
        assertEq(e.token().balanceOf(address(this)), 1000 ether, "delegator received 1000");
        assertEq(e.token().balanceOf(address(e.mgr())), 0, "manager empty");
    }
}
