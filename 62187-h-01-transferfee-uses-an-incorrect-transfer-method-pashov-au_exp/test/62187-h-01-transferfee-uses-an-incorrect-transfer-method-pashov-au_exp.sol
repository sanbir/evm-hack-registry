// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import {Exploit, TheCounter, MiniToken} from "./62187-h-01-transferfee-uses-an-incorrect-transfer-method-pashov-au.sol";
contract Finding62187Test is Test {
    function test_transferFeeReverts_feesStuck() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.transferFeeReverts(), "transferFee reverts");
        assertEq(e.stuckFee(), 100 ether, "100e18 fees stuck");
    }
}
