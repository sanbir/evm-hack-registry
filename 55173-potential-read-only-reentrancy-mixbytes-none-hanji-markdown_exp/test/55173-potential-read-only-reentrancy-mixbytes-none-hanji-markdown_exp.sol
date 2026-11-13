// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit} from "./55173-potential-read-only-reentrancy-mixbytes-none-hanji-markdown.sol";

contract Finding55173Test is Test {
    function test_harm_and_control() public {
        Exploit e = new Exploit();
        e.run();
        emit log_string("harm path executed");
    }
}
