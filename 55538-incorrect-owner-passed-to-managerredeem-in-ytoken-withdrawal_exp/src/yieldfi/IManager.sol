// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.20;

/// @notice Manager interface matching the exact call the audited
/// `YToken._withdraw` makes:
///   IManager(manager).redeem(msg.sender, address(this), asset(), shares, receiver, address(0), "");
interface IManager {
    function redeem(
        address owner,
        address yToken,
        address asset,
        uint256 amount,
        address receiver,
        address affiliate,
        bytes calldata data
    ) external;
}
