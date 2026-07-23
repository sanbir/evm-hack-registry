// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./53125-reserve-sales-vulnerable-to-mev-due-to-missing-slippage-prot.sol";

contract ReserveMevTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
