// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./64681-h-01-protocol-insolvency-risk-lack-on-chain-oracle.sol";

contract PoC_64681 is Test {
    function test_underwater_pawn_cannot_liquidate_before_deadline() public {
        Exploit exploit = new Exploit();
        exploit.run();
        assertTrue(exploit.earlyLiquidationBlocked());
        assertEq(exploit.badDebt(), 200);
    }
}
