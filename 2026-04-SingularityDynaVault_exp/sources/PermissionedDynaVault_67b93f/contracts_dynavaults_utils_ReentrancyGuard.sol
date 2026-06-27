// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// we use internal functions instead modifiers to save gas
abstract contract ReentrancyGuard {
	uint256 private constant _NOT_ENTERED = 1;
	uint256 private constant _ENTERED = 2;

	uint256 private _status;

	error Reentrancy();

	function before_nonReentrant() internal {
		if (!(_status != _ENTERED)) {
			revert Reentrancy();
		}
		_status = _ENTERED;
	}

	function after_nonReentrant() internal {
		_status = _NOT_ENTERED;
	}
}
