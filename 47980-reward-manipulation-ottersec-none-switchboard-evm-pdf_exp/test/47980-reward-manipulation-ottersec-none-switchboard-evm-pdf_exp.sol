// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {DiamondFixed, Exploit} from "./47980-reward-manipulation-ottersec-none-switchboard-evm-pdf.sol";

contract Finding47980Test is Test {
    function test_raised_reward_drains_the_diamond() public {
        Exploit e = new Exploit();
        vm.deal(address(e.diamond()), 10 ether);
        uint256 before = address(e).balance;
        e.run();
        assertEq(address(e).balance - before, 10 ether, "attacker gained the victim's 10 ETH");
        assertEq(address(e.diamond()).balance, 0, "diamond is empty");
    }

    function test_control_payout_cannot_exceed_the_enclave_balance() public {
        DiamondFixed diamond = new DiamondFixed();
        vm.deal(address(diamond), 10 ether);
        diamond.updateEnclave{value: 0}(address(this));
        diamond.forceOverrideVerify(address(this));
        diamond.setAttestationQueueConfig(10 ether);
        vm.expectRevert(bytes("reward exceeds enclave balance"));
        diamond.failEnclave(address(this), address(this));
        assertEq(address(diamond).balance, 10 ether, "victim ETH stays");
    }
}
