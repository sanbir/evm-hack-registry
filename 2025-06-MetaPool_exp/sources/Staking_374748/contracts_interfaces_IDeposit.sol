// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

interface IDeposit {
    function deposit(
        bytes memory pubkey,
        bytes memory withdrawal_credentials,
        bytes memory signature,
        bytes32 deposit_data_root
    ) external payable;

    function get_deposit_root() external view returns (bytes32);
}
