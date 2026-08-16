// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import {Exploit, RebaseReward, VotingEscrow, MiniToken} from "./58205-c-01-rebasereward-fails-because-of-incorrect-token-handling.sol";
contract Finding58205Test is Test {
    function test_rebaseReward_wrongToken() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.kittenWronglyDeposited(), 100 ether, "kitten deposited for token0 reward");
        assertEq(e.token0Locked(), 100 ether, "token0 locked");
    }
}
