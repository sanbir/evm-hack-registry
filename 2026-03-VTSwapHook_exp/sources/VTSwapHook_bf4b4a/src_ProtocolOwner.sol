// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Context} from "@openzeppelin/contracts/utils/Context.sol";

import {IProtocol} from "src/interfaces/IProtocol.sol";
import {IProtocolOwner} from "src/interfaces/IProtocolOwner.sol";

contract ProtocolOwner is IProtocolOwner, Context {

    address public immutable protocol;

    constructor(address _protocol_) {
        require(_protocol_ != address(0), "Zero address detected");
        protocol = _protocol_;
    }

    function owner() public view returns(address) {
        return IProtocol(protocol).owner();
    }

    modifier onlyOwner() {
        require(_msgSender() == owner(), "Caller is not the owner");
        _;
    }

}