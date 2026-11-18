// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, V3QuoteVerifier} from
    "./53370-risc0-and-sp1-based-attestation-may-accept-expired-certifica.sol";

contract Finding53370Test is Test {
    function test_expired_timestamp_still_pays_bounty() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.timestamp(), 500, "proof timestamp");
        assertLt(e.timestamp(), e.verifier().CERT_NOT_AFTER(), "after cert expiry the timestamp is still older");
        assertLt(e.timestamp(), e.verifier().CRL_ISSUED_AT(), "CRL is newer than the proof");
        assertTrue(e.entry().accepted(address(e)), "accepted");
        assertEq(e.paid(), 10 ether, "10 bounty tokens");
        assertEq(e.bounty().balanceOf(address(e.entry())), 0, "entrypoint empty");
    }

    function test_control_timestamp_after_crl_rejects_this_proof() public {
        Exploit e = new Exploit();
        bytes memory outputBytes = e.proof();
        uint256 ts = e.verifier().embeddedTimestamp(outputBytes);
        uint256 crl = e.verifier().CRL_ISSUED_AT();
        assertLt(ts, crl, "stale");
        vm.expectRevert(bytes("stale timestamp"));
        this.requireFresh(ts, crl);
    }

    function requireFresh(uint256 ts, uint256 crlIssuedAt) external pure {
        require(ts >= crlIssuedAt, "stale timestamp");
    }
}
