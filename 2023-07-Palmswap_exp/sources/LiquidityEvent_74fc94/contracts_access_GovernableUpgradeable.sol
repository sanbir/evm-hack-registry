// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

contract GovernableUpgradeable is Initializable, ContextUpgradeable {
    address public gov;

    event UpdateGov(address gov);

    function __GovernableUpgradeable_init() internal onlyInitializing {
        __Context_init();

        gov = _msgSender();
    }

    modifier onlyGov() {
        require(_msgSender() == gov, "Governable: forbidden");
        _;
    }

    function setGov(address _gov) external onlyGov {
        require(_gov != address(0), "Governable: zero addr");
        gov = _gov;

        emit UpdateGov(_gov);
    }
}
