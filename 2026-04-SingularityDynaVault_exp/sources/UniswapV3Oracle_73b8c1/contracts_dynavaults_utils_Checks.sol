// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library Checks {
	error MaxFee();
	error ZeroAddress();
	error AlreadyInitialized();

	function isNotAlreadyInitialized(address _address) internal pure {
		if (_address != address(0)) revert AlreadyInitialized();
	}

	function requireNonZeroAddress(address _address) internal pure {
		if (_address == address(0)) revert ZeroAddress();
	}

	function requireMaxFee(uint256 _fee, uint256 _maxFee) internal pure {
		if (_fee > _maxFee) revert MaxFee();
	}
}
