// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Token, Handler, SignatureVerifier, Settlement, SettlementFixed} from
    "./49147-h-14-malicious-actors-can-manipulate-the-cross-chain-callbac.sol";

contract Finding49147Test is Test {
    uint256 internal constant PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function test_exploit_forged_chain_locks_10_tokens() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.statusAfter(), uint8(Settlement.CrossChainMsgStatus.Failed), "failed");
        assertTrue(e.retryReverted(), "retry reverted");
        assertEq(e.locked(), 10 ether, "escrow stuck");
        assertEq(e.userBal(), 0, "user got nothing");
    }

    function test_control_signing_from_chain_releases_the_escrow() public {
        Token token = new Token();
        Handler handler = new Handler();
        SignatureVerifier verifier = new SignatureVerifier(vm.addr(PK));
        SettlementFixed fixedSettlement = new SettlementFixed(token, handler, verifier);
        address user = address(0x3333);
        token.mint(address(this), 10 ether);
        token.approve(address(fixedSettlement), 10 ether);
        fixedSettlement.escrow(7, user, 10 ether);

        bytes32 messageHash = keccak256(
            abi.encodePacked(uint256(7), "ethereum", uint256(42), address(handler), Settlement.CrossChainMsgStatus.Success)
        );
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK, ethHash);

        fixedSettlement.receive_cross_chain_callback(
            7, "ethereum", 42, address(handler), Settlement.CrossChainMsgStatus.Success, 1, abi.encode(r, s, v)
        );

        assertEq(token.balanceOf(user), 10 ether, "user received 10");
        assertEq(token.balanceOf(address(fixedSettlement)), 0, "settlement empty");
    }
}
