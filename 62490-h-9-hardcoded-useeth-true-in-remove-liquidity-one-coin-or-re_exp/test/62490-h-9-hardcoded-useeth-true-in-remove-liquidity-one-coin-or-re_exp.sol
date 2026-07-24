// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./62490-h-9-hardcoded-useeth-true-in-remove-liquidity-one-coin-or-re.sol";
contract PoC_62490 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
