// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "../Utils/ExponentialNoError.sol";
import "./ComptrollerInterfaces.sol";

contract ComptrollerNoNFTCommonImpl is ComptrollerNoNFTCommonInterface, ExponentialNoError {
    constructor() internal { }

    /**
     * @notice Admin function, part of the upgradable contracts system, use to set the implementation contract
     * @param unitrollerAddress The unitroller storage contract that this contract is supposed to be implementation of
     */
    function _become(address unitrollerAddress) external {
        UnitrollerInterface unitroller = UnitrollerInterface(unitrollerAddress);
        require(msg.sender == unitroller.admin(), "only unitroller admin can change brains");
        unitroller._acceptImplementation();
    }

    function getBlockNumber() internal view returns (uint) {
        return block.number;
    }

    /// @notice Checks caller is admin, or this contract is becoming the new implementation
    function adminOrInitializing() internal view {
        require(msg.sender == admin || msg.sender == comptrollerPart1Implementation || msg.sender == comptrollerPart2Implementation, "only admin or initializing");
    }

    /// @notice Checks caller is admin
    function onlyAdmin() internal view {
        require(msg.sender == admin, "only admin");
    }

    /// @notice Indicator that this is a Comptroller contract (for inspection). Partial implementation should never return true here (see isComptrollerPart1, isComptrollerPart2)
    function isComptroller() external pure returns (bool) {
        return false;
    }
}

contract ComptrollerNFTCommonImpl is ComptrollerNoNFTCommonImpl, ComptrollerNFTCommonInterface { }
