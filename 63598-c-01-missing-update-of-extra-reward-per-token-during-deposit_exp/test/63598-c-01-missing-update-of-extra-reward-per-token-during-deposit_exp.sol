// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63598-c-01-missing-update-of-extra-reward-per-token-during-deposit.sol";

contract StakeDAOExtraRewardTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
