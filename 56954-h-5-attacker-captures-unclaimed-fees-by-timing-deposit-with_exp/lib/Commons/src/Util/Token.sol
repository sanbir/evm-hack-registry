// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright 2023 Itos Inc.
pragma solidity ^0.8.17;

import {IERC20Minimal} from "../ERC/interfaces/IERC20Minimal.sol";
import {ContractLib} from "./Contract.sol";

type Token is address;

library TokenImpl {
    error TokenBalanceInvalid();
    error TokenTransferFailure();
    error TokenApproveFailure();

    /// Wrap an address into a Token and verify it's a contract.
    // @dev It's important to verify addr is a contract before we
    // transfer to it or else it will be a false success.
    function make(address _addr) internal view returns (Token) {
        ContractLib.assertContract(_addr);
        return Token.wrap(_addr);
    }

    /// Unwrap into an address
    function addr(Token self) internal pure returns (address) {
        return Token.unwrap(self);
    }

    /// Query the balance of this token for the caller.
    function balance(Token self) internal view returns (uint256) {
        (bool success, bytes memory data) =
            addr(self).staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        if (!(success && data.length >= 32)) {
            revert TokenBalanceInvalid();
        }
        return abi.decode(data, (uint256));
    }

    /// Query the balance of this token for another address.
    function balanceOf(Token self, address owner) internal view returns (uint256) {
        (bool success, bytes memory data) =
            addr(self).staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, owner));
        if (!(success && data.length >= 32)) {
            revert TokenBalanceInvalid();
        }
        return abi.decode(data, (uint256));
    }

    /// Transfer this token from caller to recipient.
    function transfer(Token self, address recipient, uint256 amount) internal {
        if (amount == 0) return; // Short circuit

        (bool success, bytes memory data) =
            addr(self).call(abi.encodeWithSelector(IERC20Minimal.transfer.selector, recipient, amount));
        if (!(success && (data.length == 0 || abi.decode(data, (bool))))) {
            revert TokenTransferFailure();
        }
    }

    /// Approve a future transferFrom of the given amount.
    function approve(Token self, address spender, uint256 amount) internal {
        if (amount == 0) return;

        (bool success, bytes memory data) =
            addr(self).call(abi.encodeWithSelector(IERC20Minimal.approve.selector, spender, amount));
        if (!(success && (data.length == 0 || abi.decode(data, (bool))))) {
            revert TokenApproveFailure();
        }
    }
}
