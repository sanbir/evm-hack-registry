// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

interface IAddressProvider {
    function getDelegateBundler() external view returns (address);

    function getPermissionsManager() external view returns (address);

    function getWETH() external view returns (address);
}
