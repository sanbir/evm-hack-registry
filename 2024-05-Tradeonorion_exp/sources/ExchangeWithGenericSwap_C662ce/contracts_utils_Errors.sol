// SPDX-License-Identifier: MIT

pragma solidity 0.8.15;
pragma abicoder v1;

library Errors {
	error ReturnAmountIsNotEnough();
	error InvalidMsgValue();
	error ERC20TransferFailed();
}
