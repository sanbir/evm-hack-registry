// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./65094-h-07-incorrect-loop-indexing-in-libaddressstakingreleasescom.sol";

contract PoC_65094_h_07_incorrect_loop_indexing_in_libaddressstakingreleasescom is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        // fund Exploit for findings that need ETH
        vm.deal(address(e), 100 ether);
        e.run();
    }
}
