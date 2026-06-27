// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

library Permissions {
    string internal constant ALL_PERMISSION = "*";
    string internal constant APPROVAL_PERMISSION = "APPROVE";
    string internal constant DEPOSIT_PERMISSION = "DEPOSIT";
    string internal constant WITHDRAW_PERMISSION = "WITHDRAW";
    string internal constant SWAP_PERMISSION = "SWAP";
    string internal constant BRIDGE_DEPOSIT_PERMISSION = "BRIDGE_DEPOSIT";
    string internal constant WRAP_NATIVE_PERMISSION = "WRAP";
    string internal constant UNWRAP_NATIVE_PERMISSION = "UNWRAP";
    string internal constant SIGN_PERMISSION = "SIGN";
    string internal constant UNSIGN_PERMISSION = "UNSIGN";
    string internal constant COLLECT_PERMISSION = "COLLECT";
}
