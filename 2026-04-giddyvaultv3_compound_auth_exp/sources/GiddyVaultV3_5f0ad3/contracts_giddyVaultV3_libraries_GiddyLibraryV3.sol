// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

struct SwapInfo {
  address fromToken;
  address toToken;
  uint256 amount;
  address aggregator;
  bytes data;
}

error SwapExecutionFailed(address aggregator, address fromToken, address toToken, uint256 amount, bytes revertData);

library GiddyLibraryV3 {
  using SafeERC20 for IERC20;

  address private constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  function executeSwap(SwapInfo calldata swap, address srcAccount, address dstAccount) internal returns (uint256 returnAmount) {
    // If same token, no swap needed - just transfer if destinations differ
    if (swap.fromToken == swap.toToken) {
      if (srcAccount != dstAccount) {
        IERC20(swap.fromToken).safeTransfer(dstAccount, swap.amount);
      }
      return swap.amount;
    }

    bool isFromTokenNative = swap.fromToken == NATIVE_TOKEN || swap.fromToken == address(0);
    bool isToTokenNative = swap.toToken == NATIVE_TOKEN || swap.toToken == address(0);

    if (!isFromTokenNative) {
      SafeERC20.forceApprove(IERC20(swap.fromToken), swap.aggregator, swap.amount);
    }

    uint256 srcBalanceBefore = isFromTokenNative ? srcAccount.balance : IERC20(swap.fromToken).balanceOf(srcAccount);
    uint256 dstBalanceBefore = isToTokenNative ? dstAccount.balance : IERC20(swap.toToken).balanceOf(dstAccount);
    
    (bool swapSuccess, bytes memory swapResult) = isFromTokenNative ? swap.aggregator.call{value: swap.amount}(swap.data) : swap.aggregator.call(swap.data);

    if (!swapSuccess) {
      _revertSwapExecutionFailed(swap, swapResult);
    }
    
    uint256 srcBalanceAfter = isFromTokenNative ? srcAccount.balance : IERC20(swap.fromToken).balanceOf(srcAccount);
    uint256 actualSrcChange = srcBalanceBefore - srcBalanceAfter;
    require(actualSrcChange > 0 && actualSrcChange <= swap.amount, "INVALID_SRC_BALANCE_CHANGE");

    uint256 dstBalanceAfter = isToTokenNative ? dstAccount.balance : IERC20(swap.toToken).balanceOf(dstAccount);
    returnAmount = dstBalanceAfter - dstBalanceBefore;
    require(returnAmount > 0, "SWAP_NO_TOKENS_RECEIVED");
  }

  function _revertSwapExecutionFailed(SwapInfo calldata swap, bytes memory revertData) private pure {
    revert SwapExecutionFailed(swap.aggregator, swap.fromToken, swap.toToken, swap.amount, revertData);
  }
}
