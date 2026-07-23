// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63422-h-4-bucket-rewards-will-be-wiped-by-stakeunstake-before-accr.sol";

contract SuperDCARewardWipeTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
