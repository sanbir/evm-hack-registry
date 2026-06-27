// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IShareTokenOwner {
    /// @notice Address of the share token.
    function shareToken() external view returns (address);

    /// @notice Address of the accounting token.
    function accountingToken() external view returns (address);
}
