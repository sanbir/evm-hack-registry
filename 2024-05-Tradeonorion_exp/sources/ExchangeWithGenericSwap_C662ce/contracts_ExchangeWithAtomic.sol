// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "./Exchange.sol";
import "./libs/LibAtomic.sol";

contract ExchangeWithAtomic is Exchange {
	uint256[2] private gap;
	address public WETH;
	mapping(bytes32 => LibAtomic.LockInfo) public atomicSwaps;
	mapping(bytes32 => bool) public secrets;

	event AtomicLocked(address sender, address asset, bytes32 secretHash);
	event AtomicRedeemed(address sender, address receiver, address asset, bytes secret);
	event AtomicClaimed(address receiver, address asset, bytes secret);
	event AtomicRefunded(address receiver, address asset, bytes32 secretHash);

	function setBasicParams(
		address orionToken,
		address priceOracleAddress,
		address allowedMatcher,
		address WETH_
	) public onlyOwner {
		_orionToken = IERC20(orionToken);
		_oracleAddress = priceOracleAddress;
		_allowedMatcher = allowedMatcher;
		WETH = WETH_;
	}

	function _lockAtomic(address account, LibAtomic.LockOrder memory lockOrder) internal nonReentrant {
		LibAtomic.doLockAtomic(account, lockOrder, atomicSwaps, assetBalances, liabilities);

		if (!checkPosition(account)) revert IncorrectPosition();

		emit AtomicLocked(lockOrder.sender, lockOrder.asset, lockOrder.secretHash);
	}

	function lockAtomic(LibAtomic.LockOrder memory swap) public payable {
		_lockAtomic(msg.sender, swap);
	}

	function redeemAtomic(LibAtomic.RedeemOrder calldata order, bytes calldata secret) public {
		LibAtomic.doRedeemAtomic(order, secret, secrets, assetBalances, liabilities);
		if (!checkPosition(order.sender)) revert IncorrectPosition();

		emit AtomicRedeemed(order.sender, order.receiver, order.asset, secret);
	}

	function redeem2Atomics(
		LibAtomic.RedeemOrder calldata order1,
		bytes calldata secret1,
		LibAtomic.RedeemOrder calldata order2,
		bytes calldata secret2
	) public {
		redeemAtomic(order1, secret1);
		redeemAtomic(order2, secret2);
	}

	function claimAtomic(address receiver, bytes calldata secret, bytes calldata matcherSignature) public {
		LibAtomic.LockInfo storage swap = LibAtomic.doClaimAtomic(
			receiver,
			secret,
			matcherSignature,
			_allowedMatcher,
			atomicSwaps,
			assetBalances,
			liabilities
		);

		emit AtomicClaimed(receiver, swap.asset, secret);
	}

	function refundAtomic(bytes32 secretHash) public {
		LibAtomic.LockInfo storage swap = LibAtomic.doRefundAtomic(secretHash, atomicSwaps, assetBalances, liabilities);

		emit AtomicRefunded(swap.sender, swap.asset, secretHash);
	}

	/* Error Codes
        E1: Insufficient Balance, flavor A - Atomic, PA - Position Atomic
        E17: Incorrect atomic secret, flavor: U - used, NF - not found, R - redeemed, E/NE - expired/not expired, ETH
   */
}
