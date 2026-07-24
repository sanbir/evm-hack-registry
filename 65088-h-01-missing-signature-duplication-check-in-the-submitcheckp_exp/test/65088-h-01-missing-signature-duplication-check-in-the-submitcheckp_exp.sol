// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./65088-h-01-missing-signature-duplication-check-in-the-submitcheckp.sol";

contract PoC_65088_h_01_missing_signature_duplication_check_in_the_submitcheckp is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        // fund Exploit for findings that need ETH
        vm.deal(address(e), 100 ether);
        e.run();
    }
}
