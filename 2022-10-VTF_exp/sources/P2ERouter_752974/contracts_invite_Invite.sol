// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/Strings.sol';
import '@openzeppelin/contracts/utils/Context.sol';
import '../libraries/TransferHelper.sol';
import '../interfaces/IP2EERC1155.sol';
import '../interfaces/IWETH.sol';
import '../core/SafeOwnable.sol';
import 'hardhat/console.sol';
import '../core/Random.sol';

contract Invite {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    event InviteUser(address user, address inviter);
    event InviterReward(address user, IERC20 _token, address invitee, uint relation, uint amount);
    event ClaimReward(address user, IERC20 token, uint amount);

    uint public constant MAX_HEIGHT = 5;

    address public immutable rootInviter;
    address public immutable WETH;
    mapping(address => address) inviter;
    mapping(address => mapping(IERC20 => uint256[])) inviterReward;
    mapping(IERC20 => uint) lastBalance;

    constructor(address _WETH, address _rootInviter) {
        require(_WETH != address(0), "WETH address is zero");
        WETH = _WETH;
        rootInviter = _rootInviter;
        inviter[_rootInviter] = address(this);
        emit InviteUser(_rootInviter, address(this));
    }

    function registeInviter(address _inviter) external {
        require(inviter[msg.sender] == address(0), "user already have inviter");
        require(inviter[_inviter] != address(0), "inviter have no inviter");
        inviter[msg.sender] = _inviter;
        emit InviteUser(msg.sender, _inviter);
    }

    function inviterTree(address _user, uint _height) external view returns (address[] memory) {
        require(_height < MAX_HEIGHT, "height too much");
        address[] memory inviters = new address[](_height);
        address lastUser = _user;
        for (uint i = 0; i < _height; i ++) {
            lastUser = inviter[lastUser];
            if(lastUser == address(0)){
                break; 
            }
            inviters[i] = lastUser;
        }
        return inviters;
    }

    function sendReward(address _user, IERC20 _token, uint[] memory amounts) external returns (uint) {
        address lastUser = _user;
        uint totalAmount = 0;
        for (uint i = 0; i < amounts.length; i ++) {
            lastUser = inviter[lastUser];
            if (lastUser == address(0)) {
                break;
            }
            uint[] storage reward = inviterReward[lastUser][_token];
            while (reward.length <= i) {
                reward.push(0); 
            }
            reward[i] = reward[i].add(amounts[i]);
            totalAmount = totalAmount.add(amounts[i]);
            emit InviterReward(lastUser, _token, _user, i, amounts[i]);
        }
        uint currentBalance = _token.balanceOf(address(this));
        uint tokenLastBalance = lastBalance[_token];
        require(currentBalance.sub(tokenLastBalance) >= totalAmount, "amount not enough");
        lastBalance[_token] = lastBalance[_token].add(totalAmount);
        if (currentBalance.sub(tokenLastBalance) > totalAmount) {
            _token.safeTransfer(msg.sender, currentBalance.sub(tokenLastBalance).sub(totalAmount));
        }
        return currentBalance.sub(tokenLastBalance).sub(totalAmount);
    }

    function pending(address _user, IERC20[] memory _tokens) public view returns (uint[] memory) {
        uint[] memory userAmounts = new uint[](_tokens.length);
        for (uint i = 0; i < _tokens.length; i ++) {
            uint[] storage amounts = inviterReward[_user][_tokens[i]];
            for (uint j = 0; j < amounts.length; j ++) {
                userAmounts[i] = userAmounts[i].add(amounts[j]);
            }
        }
        return userAmounts;
    }

    function tokenTransfer(IERC20 _token, address _to, uint _amount) internal returns (uint) {
        if (_amount == 0) {
            return 0;
        }
        if (address(_token) == WETH) {
            IWETH(address(_token)).withdraw(_amount);
            TransferHelper.safeTransferETH(_to, _amount);
        } else {
            _token.safeTransfer(_to, _amount);
        }
        return _amount;
    }

    function claim(address _user, IERC20[] memory _tokens) external {
        uint[] memory amounts = pending(_user, _tokens);
        for (uint i = 0; i < amounts.length; i ++) {
            if (amounts[i] > 0) {
                for (uint j = 0; j < inviterReward[_user][_tokens[i]].length; j ++) {
                    inviterReward[_user][_tokens[i]][j] = 0;
                }
                lastBalance[_tokens[i]] = lastBalance[_tokens[i]].sub(amounts[i]);
            }
        }
        for (uint i = 0; i < amounts.length; i ++) {
            tokenTransfer(_tokens[i], _user, amounts[i]);
            emit ClaimReward(_user, _tokens[i], amounts[i]);
        }
    }

    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }
}
