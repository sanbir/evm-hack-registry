// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit} from "./55383-incorrect-fee-handling-during-withdrawals-fixed-consensys-no.sol";

contract Finding55383Test is Test {
    function test_harm_and_control() public {
        Exploit e = new Exploit();
        e.run();
        emit log_string("harm path executed");
    }
}
