// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { ERC7579HookDestruct } from "src/ERC7579HookDestruct.sol";
import { IERC7579Account } from "src/external/ERC7579.sol";
import {
    ModeLib,
    CallType,
    ModeCode,
    CALLTYPE_SINGLE,
    CALLTYPE_BATCH,
    CALLTYPE_DELEGATECALL
} from "erc7579/lib/ModeLib.sol";
import "forge-std/Test.sol";
import { ExecutionLib, Execution } from "erc7579/lib/ExecutionLib.sol";
import { IAccountExecute, PackedUserOperation } from "src/external/ERC4337.sol";

contract HookDestructTest is Test, ERC7579HookDestruct {
    struct Log {
        address msgSender;
        uint256 msgValue;
        bytes msgData;
        mapping(uint256 index => Execution) executions;
        uint256 executionsLength;
    }

    struct InstallLog {
        address module;
        uint256 moduleType;
        bytes initData;
    }

    Log _log;
    InstallLog _installLog;

    function setUp() public { }

    function test_executeSingle(
        address msgSender,
        uint256 msgValue,
        address target,
        uint256 value,
        bytes memory data
    )
        public
    {
        vm.assume(data.length > 0);
        ModeCode mode = ModeLib.encodeSimpleSingle();
        bytes memory execution = ExecutionLib.encodeSingle(target, value, data);
        bytes memory callData =
            abi.encodeCall(IERC7579Account.executeFromExecutor, (mode, execution));
        _log.msgData = callData;
        _log.msgValue = msgValue;
        _log.msgSender = msgSender;

        _log.executionsLength = 1;
        _log.executions[0].target = target;
        _log.executions[0].value = value;
        _log.executions[0].callData = data;

        bytes memory hookData =
            ERC7579HookDestruct(address(this)).preCheck(msgSender, msgValue, callData);
        assertEq(hookData, "onExecute");
    }

    function test_executeBatch(
        address msgSender,
        uint256 msgValue,
        Execution[] memory _execution
    )
        public
    {
        vm.assume(_execution.length > 0);
        ModeCode mode = ModeLib.encodeSimpleBatch();
        bytes memory execution = ExecutionLib.encodeBatch(_execution);
        bytes memory callData =
            abi.encodeCall(IERC7579Account.executeFromExecutor, (mode, execution));

        _log.msgData = callData;
        _log.msgValue = msgValue;
        _log.msgSender = msgSender;

        _log.executionsLength = _execution.length;
        for (uint256 i; i < _execution.length; i++) {
            _log.executions[i].target = _execution[i].target;
            _log.executions[i].value = _execution[i].value;
            _log.executions[i].callData = _execution[i].callData;
        }

        bytes memory hookData =
            ERC7579HookDestruct(address(this)).preCheck(msgSender, msgValue, callData);
        assertEq(hookData, "onExecuteBatch");
    }

    function test_installModule(
        address msgSender,
        uint256 msgValue,
        address moduleAddress,
        uint256 moduleType,
        bytes memory data
    )
        public
    {
        vm.assume(data.length > 0);
        moduleType = moduleType % 5;
        bytes memory callData =
            abi.encodeCall(IERC7579Account.installModule, (moduleType, moduleAddress, data));
        _log.msgData = callData;
        _log.msgValue = msgValue;
        _log.msgSender = msgSender;

        _installLog.module = moduleAddress;
        _installLog.moduleType = moduleType;
        _installLog.initData = data;

        bytes memory hookData =
            ERC7579HookDestruct(address(this)).preCheck(msgSender, msgValue, callData);
        assertEq(hookData, "onInstall", "return value wrong");
    }

    function test_executeUserOp(
        address msgSender,
        uint256 msgValue,
        address target,
        uint256 value,
        bytes memory data
    )
        public
    {
        vm.assume(data.length > 0);
        ModeCode mode = ModeLib.encodeSimpleSingle();
        bytes memory execution = ExecutionLib.encodeSingle(target, value, data);
        bytes memory callData = abi.encodeCall(IERC7579Account.execute, (mode, execution));
        PackedUserOperation memory userOp = PackedUserOperation({
            sender: makeAddr("account"),
            nonce: 0,
            initCode: abi.encodePacked(makeAddr("factory"), bytes("initCode")),
            callData: abi.encodeCall(IERC7579Account.execute, (mode, execution)),
            accountGasLimits: bytes32(abi.encodePacked(uint128(2e6), uint128(2e6))),
            preVerificationGas: 2e6,
            gasFees: bytes32(abi.encodePacked(uint128(2e6), uint128(2e6))),
            paymasterAndData: bytes(""),
            signature: abi.encodePacked(hex"41414141")
        });
        bytes memory userOpCallData =
            abi.encodeCall(IAccountExecute.executeUserOp, (userOp, keccak256(abi.encode(userOp))));
        _log.msgData = callData;
        _log.msgValue = msgValue;
        _log.msgSender = msgSender;

        _log.executionsLength = 1;
        _log.executions[0].target = target;
        _log.executions[0].value = value;
        _log.executions[0].callData = data;

        bytes memory hookData =
            ERC7579HookDestruct(address(this)).preCheck(msgSender, msgValue, userOpCallData);
        assertEq(hookData, "onExecute");
    }

    function onExecute(
        address, /* account */
        address msgSender,
        address target,
        uint256 value,
        bytes calldata callData
    )
        internal
        virtual
        override
        returns (bytes memory hookData)
    {
        assertTrue(_log.msgSender == msgSender);
        assertTrue(_log.executionsLength == 1);

        assertEq(_log.executions[0].callData, callData, "callData decoding failed");
        assertEq(_log.executions[0].value, value);
        assertEq(_log.executions[0].target, target);

        hookData = "onExecute";
    }

    function onExecuteBatch(
        address, /* account */
        address msgSender,
        Execution[] calldata executions
    )
        internal
        virtual
        override
        returns (bytes memory hookData)
    {
        assertTrue(_log.msgSender == msgSender);
        assertEq(_log.executionsLength, executions.length);

        for (uint256 i; i < executions.length; i++) {
            assertEq(_log.executions[i].callData, executions[i].callData);
            assertEq(_log.executions[i].value, executions[i].value);
            assertEq(_log.executions[i].target, executions[i].target);
        }

        return "onExecuteBatch";
    }

    function onExecuteFromExecutor(
        address, /* account */
        address msgSender,
        address target,
        uint256 value,
        bytes calldata callData
    )
        internal
        virtual
        override
        returns (bytes memory hookData)
    {
        assertTrue(_log.msgSender == msgSender);
        assertTrue(_log.executionsLength == 1);

        assertEq(_log.executions[0].callData, callData, "callData decoding failed");
        assertEq(_log.executions[0].value, value);
        assertEq(_log.executions[0].target, target);

        hookData = "onExecute";
    }

    function onExecuteBatchFromExecutor(
        address, /* account */
        address msgSender,
        Execution[] calldata executions
    )
        internal
        virtual
        override
        returns (bytes memory hookData)
    {
        assertTrue(_log.msgSender == msgSender);
        assertEq(_log.executionsLength, executions.length);

        for (uint256 i; i < executions.length; i++) {
            assertEq(_log.executions[i].callData, executions[i].callData);
            assertEq(_log.executions[i].value, executions[i].value);
            assertEq(_log.executions[i].target, executions[i].target);
        }

        return "onExecuteBatch";
    }

    function onInstallModule(
        address, /* account */
        address msgSender,
        uint256 moduleType,
        address module,
        bytes calldata initData
    )
        internal
        virtual
        override
        returns (bytes memory hookData)
    {
        assertEq(_log.msgSender, msgSender);

        assertEq(_installLog.module, module);
        assertEq(_installLog.moduleType, moduleType);
        assertEq(_installLog.initData, initData);

        hookData = "onInstall";
    }

    function onUninstallModule(
        address account,
        address msgSender,
        uint256 moduleType,
        address module,
        bytes calldata deInitData
    )
        internal
        virtual
        override
        returns (bytes memory hookData)
    { }

    function onPostCheck(address account, bytes calldata hookData) internal virtual override { }

    function onInstall(bytes calldata) public { }
    function onUninstall(bytes calldata) public { }

    function isInitialized(address smartAccount) public view returns (bool) { }
    function isModuleType(uint256 moduleType) public pure returns (bool) { }
}
