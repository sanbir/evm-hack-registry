// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63224-mechanism-to-prevent-donation-attack-can-be-gamed-to-cause-w.sol";

contract StrataDonationMinSharesTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
