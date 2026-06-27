// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '../interfaces/IP2EToken.sol';
import '../token/TokenLocker.sol';
import '../core/SafeOwnable.sol';
import 'hardhat/console.sol';

contract P2EIco {
    using SafeMath for uint256;
    using SafeERC20 for ERC20;

    event NewReceiver(address receiver, uint sendAmount, uint lastReleaseAt);
    event ReleaseToken(address receiver, uint releaseAmount, uint nextReleaseAmount, uint nextReleaseBlockNum);

    uint256 public constant PRICE_BASE = 1e6;
    ERC20 public immutable sendToken;
    address public immutable sendTokenReceiver;
    IP2EToken public immutable receiveToken;
    uint public immutable icoPrice;
    TokenLocker public tokenLocker;
    uint256 public immutable totalAmount;
    uint256 public remainRelease;

    uint256 public totalReceived;
    uint256 public totalRelease;

    constructor(
        ERC20 _sendToken, address _sendTokenReceiver, IP2EToken _receiveToken, uint _icoPrice, uint256 _totalAmount
    ) {
        require(address(_sendToken) != address(0), "ilelgal send token");
        sendToken = _sendToken;
        //require(_sendTokenReceiver != address(0), "send token receiver is zero");
        //zero address is ok, so no one can retrive the sendToken
        sendTokenReceiver = _sendTokenReceiver;
        require(address(_receiveToken) != address(0), "illegal token");
        receiveToken = _receiveToken;
        require(address(_sendToken) != address(_receiveToken), "sendToken and receiveToken is the same");
        require(_icoPrice > 0, "illegal icoPrice");
        icoPrice = _icoPrice;
        remainRelease = totalAmount = _totalAmount;
    }

    function initTokenLocker(TokenLocker _tokenLocker) external {
        require(address(tokenLocker) == address(0), "tokenLocker already setted");
        tokenLocker = _tokenLocker;
    }

    function deposit(address _receiver, uint256 _amount) external {
        uint balanceBefore = sendToken.balanceOf(address(this));
        sendToken.safeTransferFrom(msg.sender, address(this), _amount);
        uint balanceAfter = sendToken.balanceOf(address(this));
        _amount = balanceAfter.sub(balanceBefore);
        require(_receiver != address(0), "receiver address is zero");
        require(_amount > 0, "release amount is zero");

        uint sendTokenMisDecimal = uint(18).sub(sendToken.decimals());
        uint receiveTokenMisDecimal = uint(18).sub(ERC20(address(receiveToken)).decimals());
        uint receiveAmount = _amount.mul(uint(10) ** (sendTokenMisDecimal)).mul(PRICE_BASE).div(icoPrice).div(uint(10) ** (receiveTokenMisDecimal));
        require(remainRelease >= receiveAmount, "release amount is bigger than reaminRelease");
        totalReceived = totalReceived.add(_amount);
        remainRelease = remainRelease.sub(receiveAmount);
        totalRelease = totalRelease.add(receiveAmount);
        receiveToken.mint(address(this), receiveAmount);
        receiveToken.approve(address(tokenLocker), receiveAmount);
        tokenLocker.addReceiver(_receiver, receiveAmount);
        emit NewReceiver(_receiver, _amount, block.timestamp);
    }

    function claim(address _receiver) external {
        tokenLocker.claim(_receiver); 
    }

    function totalLockAmount() external view returns (uint256) {
        return tokenLocker.totalLockAmount();
    }


    //response1: the timestamp for next release
    //response2: the amount for next release
    //response3: the total amount already released
    //response4: the remain amount for the receiver to release
    function getReleaseInfo(address _receiver) public view returns (uint256 nextReleaseAt, uint256 nextReleaseAmount, uint256 alreadyReleaseAmount, uint256 remainReleaseAmount) {
        if (false) {
            alreadyReleaseAmount = 0;
        }
        (nextReleaseAt, nextReleaseAmount, remainReleaseAmount) = tokenLocker.pending(_receiver);
    }

    function withdraw(uint amount) external {
        uint balance = sendToken.balanceOf(address(this));
        if (amount > balance) {
            amount = balance;
        }
        if (amount > 0) {
            sendToken.safeTransfer(sendTokenReceiver, amount);
        }
    }
}
