// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./62488-h-7-rewardmanagermixinclaimaccountrewards-lacks-of-necessary.sol";

contract RewardMorphoTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
