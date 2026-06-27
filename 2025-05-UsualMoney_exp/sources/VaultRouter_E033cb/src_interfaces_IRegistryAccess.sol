// SPDX-License-Identifier: Apache-2.0

pragma solidity 0.8.26;

// solhint-disable-next-line no-empty-blocks
interface IRegistryAccess {
    function grantRole(bytes32 role, address account) external;

    function hasRole(
        bytes32 role,
        address account
    )
        external
        view
        returns (bool);
}
