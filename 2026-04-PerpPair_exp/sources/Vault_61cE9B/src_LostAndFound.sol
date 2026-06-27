// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "./interfaces/ILostAndFound.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LostAndFound is ILostAndFound, AccessControl {
    using SafeERC20 for IERC20;

    ///@dev role for the vault contract
    bytes32 public VAULT_ROLE = keccak256("VAULT_ROLE");

    mapping(address => mapping(address => uint256)) public userBalances;

    constructor(){
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    ///@dev function to add funds coming from the vault in case of blacklisted users. Can only be called from the vault.
    ///@param user user that owns the funds.
    ///@param stable stablecoin to deposit.
    ///@param amount amount to deposit.
    function depositLostFunds(address user, address stable, uint256 amount) public onlyRole(VAULT_ROLE) {
        IERC20(stable).safeTransferFrom(msg.sender, address(this), amount);
        userBalances[user][stable] += amount;
    }                                                                     

    ///@dev Allows the users to withdraw their funds once they are no more blacklisted
    ///@param stable stablecoin to withdraw.
    ///@param amount amount to withdraw.
    function retrieveLostFunds(address stable, uint256 amount) public {
        require(amount > 0, "Amount must be positive");
        require(userBalances[_msgSender()][stable] >= amount, "Not enough funds");
        userBalances[_msgSender()][stable] -= amount;
        IERC20(stable).safeTransfer(_msgSender(), amount);
    }

    ///@dev Overload to withdraw all of the stablecoin of one kind.
    ///@param stable stablecoin to withdraw.
    function retrieveLostFunds(address stable) public {
        require(userBalances[_msgSender()][stable] > 0, "Amount must be positive");
        uint256 transferAmount = userBalances[_msgSender()][stable];
        userBalances[_msgSender()][stable] = 0;
        IERC20(stable).safeTransfer(_msgSender(), transferAmount);
    }

}