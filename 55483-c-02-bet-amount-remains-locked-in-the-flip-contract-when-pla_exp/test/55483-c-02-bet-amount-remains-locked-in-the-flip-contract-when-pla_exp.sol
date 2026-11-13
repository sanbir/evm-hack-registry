// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit} from "./55483-c-02-bet-amount-remains-locked-in-the-flip-contract-when-pla.sol";

contract Finding55483Test is Test {
    function test_harm_and_control() public {
        Exploit e = new Exploit();
        e.run();
        emit log_string("harm path executed");
    }
}
