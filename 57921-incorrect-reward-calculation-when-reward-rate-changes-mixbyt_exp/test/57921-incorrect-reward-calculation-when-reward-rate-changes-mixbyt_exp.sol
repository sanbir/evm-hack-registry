// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {DIAWhitelistedStakingFixed, Exploit, StakeToken} from "./57921-incorrect-reward-calculation-when-reward-rate-changes-mixbyt.sol";

contract Finding57921Test is Test {
    function test_live_rate_is_applied_to_the_old_window() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.quoted(), 10_000 ether, "new rate quotes 10000");
        assertEq(e.received(), 10_000 ether, "user is paid 10000");
        assertEq(e.token().balanceOf(address(e.staking())), 0, "reward pool emptied");
    }

    function test_control_uses_the_old_rate() public {
        StakeToken token = new StakeToken();
        DIAWhitelistedStakingFixed staking = new DIAWhitelistedStakingFixed(token, 1000, 100);
        token.mint(address(staking), 10_000 ether);
        uint256 index = staking.openStake(10_000 ether);
        uint256 paid = staking.unstake(index);
        assertEq(paid, 1_000 ether, "old rate pays 1000");
        assertEq(token.balanceOf(address(staking)), 9_000 ether, "9000 stays for other stakers");
    }
}
