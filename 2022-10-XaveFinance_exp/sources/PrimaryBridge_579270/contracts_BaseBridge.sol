// SPDX-License-Identifier: MIT
pragma solidity =0.8.6;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

abstract contract BaseBridge is Ownable {
    address internal _token;
    address internal _authorised;
    mapping (uint256 => uint256) internal _balances;

    function balanceOf(uint256 chainId) external view returns (uint256) {
        return _balances[chainId];
    }

    function bridgeToken() external view returns(address) {
        return address(_token);
    }

    function updateAuthorised(address who) public onlyOwner() {
        require(who != address(0), "Invalid account");
        _authorised = who;        
    }

    modifier onlyAuthorised() {
        require(msg.sender == _authorised, "Caller cannot excute this function");
        _;
    }
}
