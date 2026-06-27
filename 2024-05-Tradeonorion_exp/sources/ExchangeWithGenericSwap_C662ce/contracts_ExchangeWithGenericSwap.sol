// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "./ExchangeWithAtomic.sol";
import "./libs/LibGenericSwap.sol";
import "./interfaces/IAggregationExecutor.sol";

contract ExchangeWithGenericSwap is ExchangeWithAtomic {
	using SafeERC20 for IERC20;
	using SafeTransferHelper for IERC20;

	error InsufficientBalance();
	error ZeroReturnAmount();

	/// @notice Fills user's limit order through pools, delegating all calls encoded in `data` to `executor`. See tests for usage examples
	/// @param order User signed limit order
	/// @param executor Aggregation executor that executes calls described in `data`
	/// @param desc Swap description
	/// @param data Encoded calls that `caller` should execute in between of swaps
	function fillThroughPools(
		uint112 filledAmount,
		LibValidator.Order calldata order,
		IAggregationExecutor executor,
		LibValidator.SwapDescription memory desc,
		bytes calldata permit,
		bytes calldata data
	) external onlyMatcher nonReentrant {
		bytes32 orderHash = LibValidator.checkOrderSingleMatch(order, desc, filledAmount, block.timestamp);
		// if destination token is equal to fee token then fee will be fully paid inside executor contract
		if (address(desc.dstToken) != order.matcherFeeAsset) {
			payMatcherFee(order);
		} else {
			desc.minReturnAmount -= order.matcherFee; // condition desc.minReturnAmount > order.matcher fee was checked in LibValidator
		}
		LibGenericSwap.transferToInitialSource(order.senderAddress, desc, permit, assetBalances, liabilities);
		LibGenericSwap.fillThroughPools(orderHash, order.senderAddress, executor, desc, data);
		updateFilledAmount(orderHash, order.amount, filledAmount);

	}

	/// @notice Performs a swap, delegating all calls encoded in `data` to `executor`. See tests for usage examples
	/// @param executor Aggregation executor that executes calls described in `data`
	/// @param desc Swap description
	/// @param data Encoded calls that `caller` should execute in between of swaps
	/// @return returnAmount Resulting token amount
	/// @return spentAmount Source token amount
	/// @return gasLeft Gas left
	function swap(
		IAggregationExecutor executor,
		LibValidator.SwapDescription memory desc,
		bytes calldata permit,
		bytes calldata data
	) public payable nonReentrant returns (uint256 returnAmount, uint256 spentAmount, uint256 gasLeft) {
		if (desc.minReturnAmount == 0) revert ZeroReturnAmount();
		LibGenericSwap.transferToInitialSource(msg.sender, desc, permit, assetBalances, liabilities);
		(returnAmount, spentAmount, gasLeft) = LibGenericSwap.swap(msg.sender, executor, desc, data);
	}

	function payMatcherFee(LibValidator.Order memory order) internal {
		LibExchange._updateBalance(
			order.senderAddress,
			order.matcherFeeAsset,
			-int(uint(order.matcherFee)),
			assetBalances,
			liabilities
		);
		if (assetBalances[order.senderAddress][order.matcherFeeAsset] < 0) revert InsufficientBalance();
		LibExchange._updateBalance(
			order.matcherAddress,
			order.matcherFeeAsset,
			int(uint(order.matcherFee)),
			assetBalances,
			liabilities
		);
	}
}
