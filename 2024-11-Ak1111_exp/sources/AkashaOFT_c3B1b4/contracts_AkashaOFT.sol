// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma abicoder v2;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFT } from "./token/oft/v1/OFT.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

contract AkashaOFT is OFT {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint,
        address _delegate
    ) OFT(_name, _symbol, _lzEndpoint) Ownable() {
        // _mint(_delegate, 1000000000 * 10**decimals());
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    // allow this contract to receive ether
    receive() external payable {}
}