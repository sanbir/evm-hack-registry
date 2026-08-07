// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.20;

import {IManager} from "./IManager.sol";

interface IYTokenBurn {
    function managerBurn(address account, uint256 shares) external;
}

/// @notice Minimal faithful stand-in for YieldFi's `Manager` (the real one lived
/// in the deleted repo). It implements the exact `redeem(...)` entry point the
/// audited `YToken._withdraw` calls, records the redemption order (as the real
/// Manager does for off-chain processing), and executes it by burning the given
/// owner's shares. The real Manager queues then executes off-chain/on-chain; we
/// execute inline so the harm is observable in a single transaction — the
/// account whose shares are burned is identical either way.
///
/// It is NOT the contract the finding is about; the vulnerable contract is
/// `YToken`, which passes the WRONG owner (`msg.sender`) into `redeem` below.
contract Manager is IManager {
    event OrderRequest(
        address indexed owner, address indexed yToken, address indexed asset, address receiver, uint256 amount, bool isDeposit
    );

    function redeem(
        address owner,
        address yToken,
        address asset,
        uint256 amount,
        address receiver,
        address, /* affiliate */
        bytes calldata /* data */
    ) external {
        // The order is recorded against `owner` as supplied by YToken._withdraw.
        emit OrderRequest(owner, yToken, asset, receiver, amount, false);
        // Execution burns `owner`'s shares. With the bug, `owner == msg.sender`
        // (the third-party caller): this reverts "!balance" if the caller holds
        // no shares, or burns the caller's own shares if they do.
        IYTokenBurn(yToken).managerBurn(owner, amount);
    }
}
