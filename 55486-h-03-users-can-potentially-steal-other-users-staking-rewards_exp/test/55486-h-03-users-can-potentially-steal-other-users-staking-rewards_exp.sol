// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit} from "./55486-h-03-users-can-potentially-steal-other-users-staking-rewards.sol";

contract Finding55486Test is Test {
    function test_harm_and_control() public {
        Exploit e = new Exploit();
        e.run();
        emit log_string("harm path executed");
    }
}
