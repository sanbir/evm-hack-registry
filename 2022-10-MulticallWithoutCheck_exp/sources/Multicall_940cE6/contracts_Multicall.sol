// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "./interfaces/IERC20.sol";

struct Call {
    address target;
    bytes callData;
    uint256 value;
}
    
contract Multicall {

    address private owner;

    event Received(address, uint);

    constructor() {
        owner = msg.sender;
    }

    function multicall(Call[] memory calls) external payable {
        uint256 balBefore = address(this).balance;


        for(uint256 i = 0; i < calls.length; i++) {
            (bool success, ) = calls[i].target.call{value: calls[i].value}(calls[i].callData);
            require(success, "Contract call failed");
        }

        require(address(this).balance > balBefore, "No profits");
    }

    function multicallWithoutCheck(Call[] memory calls) external payable {
        for(uint256 i = 0; i < calls.length; i++) {
            (bool success, ) = calls[i].target.call{value: calls[i].value}(calls[i].callData);
            require(success, "Contract call failed");
        }
    }

    /** 
     * Approve the contract for spending given token for a specific sender.
    */
    function approveToken(
        address token, 
        address spender, 
        uint256 amount
    ) external onlyOwner returns (bool) {
        return IERC20(token).approve(spender, amount);
    }

    /** 
     * Withdraw the specific token from the contract.
    */
    function withdrawToken(
        address token
    ) external onlyOwner returns (bool) {
        return IERC20(token).transfer(owner, IERC20(token).balanceOf(address(this)));
    }

    /** 
     * Withdraw all the ethers from the contract.
    */
    function withdraw() external onlyOwner {
        (bool sent,) = owner.call{value: address(this).balance}("");
        require(sent, "Failed to send Ether");
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(owner == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }
}