// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {Exploit} from "./52752-h-7-incorrect-reserve-mapping-leads-to-fault-swap-sherlock-p.sol";
contract Finding52752Test is Test {
    function test_exploit_wrong_reserve_dumps_scarce_token() public {
        Exploit e = new Exploit();
        e.run();
        emit log_named_uint("buggy", e.pod().buggyAmt());
        emit log_named_uint("fair", e.pod().fairAmt());
        emit log_named_uint("extra", e.pod().buggyAmt() - e.pod().fairAmt());
        assertGt(e.pod().buggyAmt(), e.pod().fairAmt() + 400 ether, "extra");
        assertEq(e.high().balanceOf(address(e.pair())), 10 ether + e.pod().buggyAmt(), "pair");
    }
}
