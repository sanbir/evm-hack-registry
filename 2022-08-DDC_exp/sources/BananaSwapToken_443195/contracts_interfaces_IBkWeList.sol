//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IBkWeList {
    function isWeList(address _address)external view returns(bool);

    function isBkList(address _address)external view returns(bool);
}