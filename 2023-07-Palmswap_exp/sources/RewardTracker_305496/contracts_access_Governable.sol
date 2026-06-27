// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

contract Governable {
    address public gov;

    event UpdateGov(address gov);

    constructor() {
        gov = msg.sender;
    }

    modifier onlyGov() {
        require(msg.sender == gov, "Governable: forbidden");
        _;
    }

    function setGov(address _gov) external onlyGov {
        require(_gov != address(0), "Governable: zero addr");
        gov = _gov;

        emit UpdateGov(_gov);
    }
}
