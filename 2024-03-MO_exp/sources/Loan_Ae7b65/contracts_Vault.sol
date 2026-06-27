// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Vault is Ownable {
    using SafeERC20 for IERC20;

    mapping(address => bool) public operators;

    event OperatorUpdated(address indexed operator, bool state);

    error NotOperator();

    modifier onlyOperator() {
        if (operators[msg.sender] == false) revert NotOperator();
        _;
    }

    constructor() Ownable(msg.sender) {}

    function setOperator(address _operator, bool _state) public onlyOwner {
        operators[_operator] = _state;
        emit OperatorUpdated(_operator, _state);
    }

    function transfer(address token, address to, uint256 amount) public onlyOperator {
        if (token == address(0)) {
            payable(to).transfer(amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
