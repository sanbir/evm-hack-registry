// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../interfaces/IWETH.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../helpers/RevertReasonForwarder.sol";
import "../interfaces/IDaiLikePermit.sol";


library SafeTransferHelper {
	using SafeERC20 for IERC20;

	error InsufficientBalance();
	error ForceApproveFailed();
	error ApproveCalledOnETH();
	error NotEnoughValue();
	error FromIsNotSender();
	error ToIsNotThis();
	error ETHTransferFailed();
	error SafePermitBadLength();

	uint256 private constant _RAW_CALL_GAS_LIMIT = 5000;
	IERC20 private constant _ETH_ADDRESS = IERC20(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
	IERC20 private constant _ZERO_ADDRESS = IERC20(address(0));

	/// @dev Returns true if `token` is ETH.
	function isETH(IERC20 token) internal pure returns (bool) {
		return (token == _ZERO_ADDRESS || token == _ETH_ADDRESS);
	}

	/// @dev Returns `account` ERC20 `token` balance.
	function uniBalanceOf(IERC20 token, address account) internal view returns (uint256) {
		if (isETH(token)) {
			return account.balance;
		} else {
			return token.balanceOf(account);
		}
	}

	/// @dev `token` transfer `to` `amount`.
	/// Note that this function does nothing in case of zero amount.
	/// @dev `token` transfer `to` `amount`.
	/// Note that this function does nothing in case of zero amount.
	function uniTransfer(IERC20 token, address payable to, uint256 amount) internal {
		if (amount > 0) {
			if (isETH(token)) {
				if (address(this).balance < amount) revert InsufficientBalance();
				// solhint-disable-next-line avoid-low-level-calls
				(bool success, ) = to.call{value: amount, gas: _RAW_CALL_GAS_LIMIT}("");
				if (!success) revert ETHTransferFailed();
			} else {
				token.safeTransfer(to, amount);
			}
		}
	}

	/// @dev Reverts if `token` is ETH, otherwise performs ERC20 forceApprove.
	function uniApprove(IERC20 token, address to, uint256 amount) internal {
		if (isETH(token)) revert ApproveCalledOnETH();

		forceApprove(token, to, amount);
	}

	/// @dev If `approve(from, to, amount)` fails, try to `approve(from, to, 0)` before retry.
	function forceApprove(IERC20 token, address spender, uint256 value) internal {
		if (!_makeCall(token, token.approve.selector, spender, value)) {
			if (
				!_makeCall(token, token.approve.selector, spender, 0) ||
				!_makeCall(token, token.approve.selector, spender, value)
			) {
				revert ForceApproveFailed();
			}
		}
	}

	function safeAutoTransferFrom(address weth, address token, address from, address to, uint value) internal {
		if (isETH(IERC20(token))) {
			require(from == address(this), "TransferFrom: this");
			IWETH(weth).deposit{value: value}();
			assert(IWETH(weth).transfer(to, value));
		} else {
			if (from == address(this)) {
				SafeERC20.safeTransfer(IERC20(token), to, value);
			} else {
				SafeERC20.safeTransferFrom(IERC20(token), from, to, value);
			}
		}
	}

	function safeAutoTransferTo(address weth, address token, address to, uint value) internal {
		if (address(this) != to) {
			if (isETH(IERC20(token))) {
				IWETH(weth).withdraw(value);
				Address.sendValue(payable(to), value);
			} else {
				SafeERC20.safeTransfer(IERC20(token), to, value);
			}
		}
	}

	function safeTransferTokenOrETH(address token, address to, uint value) internal {
		if (value > 0) {
			if (isETH(IERC20(token))) {
				if (address(this).balance < value) revert InsufficientBalance();
				// solhint-disable-next-line avoid-low-level-calls
				(bool success, ) = to.call{value: value, gas: _RAW_CALL_GAS_LIMIT}("");
				if (!success) revert ETHTransferFailed();
			} else {
				IERC20(token).safeTransfer(to, value);
			}
		}
	}

	function safePermit(IERC20 token, bytes calldata permit) internal {
		bool success;
		if (permit.length == 32 * 7) {
			// solhint-disable-next-line avoid-low-level-calls
			success = _makeCalldataCall(token, IERC20Permit.permit.selector, permit);
		} else if (permit.length == 32 * 8) {
			// solhint-disable-next-line avoid-low-level-calls
			success = _makeCalldataCall(token, IDaiLikePermit.permit.selector, permit);
		} else {
			revert SafePermitBadLength();
		}

		if (!success) {
			RevertReasonForwarder.reRevert();
		}
	}

    function _makeCall(IERC20 token, bytes4 selector, address to, uint256 amount) private returns (bool success) {
		assembly ("memory-safe") {
			// solhint-disable-line no-inline-assembly
			let data := mload(0x40)

			mstore(data, selector)
			mstore(add(data, 0x04), to)
			mstore(add(data, 0x24), amount)
			success := call(gas(), token, 0, data, 0x44, 0x0, 0x20)
			if success {
				switch returndatasize()
				case 0 {
					success := gt(extcodesize(token), 0)
				}
				default {
					success := and(gt(returndatasize(), 31), eq(mload(0), 1))
				}
			}
		}
	}

	function _makeCalldataCall(IERC20 token, bytes4 selector, bytes calldata args) private returns (bool done) {
		/// @solidity memory-safe-assembly
		assembly {
			// solhint-disable-line no-inline-assembly
			let len := add(4, args.length)
			let data := mload(0x40)

			mstore(data, selector)
			calldatacopy(add(data, 0x04), args.offset, args.length)
			let success := call(gas(), token, 0, data, len, 0x0, 0x20)
			done := and(success, or(iszero(returndatasize()), and(gt(returndatasize(), 31), eq(mload(0), 1))))
		}
	}
}
