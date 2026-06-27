//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./interfaces/IBkWeList.sol";

// //import "hardhat/console.sol";

abstract contract BkWeList is IBkWeList {
    using EnumerableSet for EnumerableSet.AddressSet;

    event AddWeList(address[] _address);
    event RemoveWeList(address _address);
    event AddBkList(address[] _address);
    event RemoveBkList(address _address);

    EnumerableSet.AddressSet private bkList;
    EnumerableSet.AddressSet private weList;

    function validateBkWe(address _address)internal view virtual {
        if (!weList.contains(_address)) {
            require(!bkList.contains(_address), "address in bl");
        }
    }

    function _addWeList(address[] memory _address) internal virtual {
        for (uint i = 0; i < _address.length; i++) {
            require(!bkList.contains(_address[i]), "address is bl");
            weList.add(_address[i]);
        }
        emit AddWeList(_address);
    }

    function _removeWeList(address _address) internal virtual {
        weList.remove(_address);
        emit RemoveWeList(_address);
    }

    function isWeList(address _address) public view override returns (bool) {
        return weList.contains(_address);
    }

    function _addBkList(address[] memory _address) internal virtual {
        for (uint i = 0; i < _address.length; i++) {
            require(!weList.contains(_address[i]), "address is wl");
            bkList.add(_address[i]);
        }
        emit AddBkList(_address);
    }

    function _removeBkList(address _address) internal virtual {
        bkList.remove(_address);
        emit RemoveBkList(_address);
    }

    function isBkList(address _address) public view override returns (bool) {
        return bkList.contains(_address);
    }
}
