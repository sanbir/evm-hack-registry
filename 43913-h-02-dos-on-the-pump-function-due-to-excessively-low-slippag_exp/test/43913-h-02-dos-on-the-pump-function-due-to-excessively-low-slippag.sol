// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  ULTI — pump reverts because 99 bps of slippage cannot cover a 1% pool fee
    (Pashov, November 2024, H-02, finding 43913).
    SYNTHETIC, cheatcode-free.
    The min-out lines are the audited slippage check. The expected quote uses
    1e18, which is the correction of the sibling precision bug. The report says
    that correction is exactly when this 99 bps cap denies every pump. */

contract MiniToken {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _symbol) {
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockSwap {
    uint256 public constant POOL_FEE_BPS = 100;

    function swap(MiniToken inputToken, MiniToken ulti, uint256 amountIn, uint256 expectedOut)
        external
        returns (uint256 amountOut)
    {
        inputToken.transferFrom(msg.sender, address(this), amountIn);
        amountOut = expectedOut * (10000 - POOL_FEE_BPS) / 10000;
        ulti.mint(msg.sender, amountOut);
    }
}

contract UltiPump {
    uint256 public constant ULTI_NUMBER = 33;
    uint256 public constant MAX_SWAP_SLIPPAGE_BPS = 3 * ULTI_NUMBER;

    MiniToken public inputToken;
    MiniToken public ulti;
    MockSwap public router;
    uint256 public lastMinInternal;
    uint256 public lastEffectiveMin;

    constructor(MiniToken _input, MiniToken _ulti, MockSwap _router) {
        inputToken = _input;
        ulti = _ulti;
        router = _router;
    }

    function approveRouter() external {
        inputToken.approve(address(router), type(uint256).max);
    }

    function pump(uint256 inputAmountToSwap, uint256 minUltiAmount) external returns (uint256) {
        return _swapInputTokenForUlti(inputAmountToSwap, minUltiAmount, 1e18);
    }

    function _swapInputTokenForUlti(uint256 inputAmountToSwap, uint256 minUltiAmount, uint256 twap)
        internal
        returns (uint256 ultiAmount)
    {
        uint256 expectedUltiAmountWithoutSlippage = inputAmountToSwap * 1e18 / twap;
        uint256 minUltiAmountInternal = (expectedUltiAmountWithoutSlippage * (10000 - MAX_SWAP_SLIPPAGE_BPS)) / 10000; // @> VULN: 99 bps of room is below the pool's 1% fee, so a fair quote is rejected
        uint256 effectiveMinUltiAmount = minUltiAmount > minUltiAmountInternal ? minUltiAmount : minUltiAmountInternal;
        lastMinInternal = minUltiAmountInternal;
        lastEffectiveMin = effectiveMinUltiAmount;
        ultiAmount = router.swap(inputToken, ulti, inputAmountToSwap, expectedUltiAmountWithoutSlippage);
        require(ultiAmount >= effectiveMinUltiAmount, "slippage");
    }
}

contract UltiPumpFixed {
    uint256 public constant MAX_SWAP_SLIPPAGE_BPS = 200;

    MiniToken public inputToken;
    MiniToken public ulti;
    MockSwap public router;

    constructor(MiniToken _input, MiniToken _ulti, MockSwap _router) {
        inputToken = _input;
        ulti = _ulti;
        router = _router;
    }

    function approveRouter() external {
        inputToken.approve(address(router), type(uint256).max);
    }

    function pump(uint256 inputAmountToSwap, uint256 minUltiAmount) external returns (uint256 ultiAmount) {
        uint256 expectedUltiAmountWithoutSlippage = inputAmountToSwap * 1e18 / 1e18;
        uint256 minUltiAmountInternal = (expectedUltiAmountWithoutSlippage * (10000 - MAX_SWAP_SLIPPAGE_BPS)) / 10000;
        uint256 effectiveMinUltiAmount = minUltiAmount > minUltiAmountInternal ? minUltiAmount : minUltiAmountInternal;
        ultiAmount = router.swap(inputToken, ulti, inputAmountToSwap, expectedUltiAmountWithoutSlippage);
        require(ultiAmount >= effectiveMinUltiAmount, "slippage");
    }
}

contract Exploit {
    MiniToken public inputToken;
    MiniToken public ulti;
    MockSwap public router;
    UltiPump public pump;

    bool public pumpReverted;
    uint256 public inputLeft;
    uint256 public ultiBought;
    uint256 public minInternal;

    constructor() {
        inputToken = new MiniToken("WETH");
        ulti = new MiniToken("ULTI");
        router = new MockSwap();
        pump = new UltiPump(inputToken, ulti, router);
        inputToken.mint(address(pump), 1000e18);
    }

    function run() external {
        pump.approveRouter();
        uint256 expected = 1000e18;
        minInternal = expected * (10000 - pump.MAX_SWAP_SLIPPAGE_BPS()) / 10000;

        try pump.pump(1000e18, 1) returns (uint256 out) {
            pumpReverted = false;
            ultiBought = out;
        } catch {
            pumpReverted = true;
            ultiBought = 0;
        }

        inputLeft = inputToken.balanceOf(address(pump));
        require(pump.MAX_SWAP_SLIPPAGE_BPS() == 99, "bps");
        require(minInternal == 9901e17, "min out");
        require(pumpReverted, "pump did not revert");
        require(ultiBought == 0, "ulti was bought");
        require(inputLeft == 1000e18, "input was spent");
        require(ulti.balanceOf(address(pump)) == 0, "ulti balance");
    }
}
