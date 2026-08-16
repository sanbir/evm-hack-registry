// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import {Exploit, ZKPay, MiniToken} from "./63315-c-02-emptying-eth-from-zkpaysol-pashov-audit-group-none-sxt.sol";
contract Finding63315Test is Test {
    function test_emptyEthFromZKPay() public {
        Exploit e = new Exploit();
        vm.deal(address(this), 20 ether);
        e.run{value: 10 ether}();
        assertEq(e.withdrawnByAttacker(), 10 ether, "attacker withdrew 10 ETH");
        assertEq(e.depositedByAttacker(), 0, "deposited nothing");
    }
}
