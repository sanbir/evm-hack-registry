// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./62808-h-1-gas-consumed-in-notifyunsubscribe-is-underestimated-duri.sol";

contract NotifyGasTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
