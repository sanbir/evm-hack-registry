// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Miner} from "./Miner.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

abstract contract RaiseFunds is Miner,Ownable {

    constructor(string memory name_, string memory symbol_) Miner(name_, symbol_) Ownable(_msgSender())
    {

    }

    uint256 private _raiseFundsTotal;

    uint256 private _dividends;

    mapping(address => uint256) internal _raiseFunds;

    mapping(address => uint256) private _raiseDividend;

    event AddRaiseFunds(
        address indexed account,
        uint256 indexed amount,
        uint256 indexed time
    );

    event WithdrawRaiseFunds(
        address indexed account,
        uint256 indexed amount,
        uint256 indexed time
    );

    event WithdrawRaiseDividend(
        address indexed account,
        uint256 indexed amount,
        uint256 indexed time
    );

    function _addRaiseFunds() internal {
        uint256 _amount = msg.value;
        _raiseFundsTotal += _amount;
        _raiseFunds[_msgSender()] += _amount;
        emit AddRaiseFunds(_msgSender(), _amount, block.timestamp);
    }

    function _withdrawRaiseFundsHandle() internal
    {
        uint256 _amount = _raiseFunds[_msgSender()];
        _raiseFundsTotal -= _amount;
        _raiseFunds[_msgSender()] = 0;
        payable(_msgSender()).transfer(_amount);
        emit WithdrawRaiseFunds(_msgSender(), _amount, block.timestamp);
    }


    function _addRaiseDividends(uint256 dividend) internal {
        if (_raiseFundsTotal > 0) {
            uint256 _dividend = dividend * 1 ether / _raiseFundsTotal;
            _dividends += _dividend;
        }
    }

    function getRaiseFundsTotal() public view returns (uint256) {
        return _raiseFundsTotal;
    }

    function getRaiseAmount(address _account) public view returns (uint256){
        return _raiseFunds[_account];
    }

    function getRaiseTokenAmount(address _account) public view returns (uint256) {
        uint256 balance = _raiseFunds[_account];
        if (balance <= 0) {
            return 0;
        }
        return balance * (_dividends - _raiseDividend[_account]) / 1 ether;
    }

    function _withdrawRaiseDividend(address _account) internal {
        uint256 tokenAmount = getRaiseTokenAmount(_account);
        if (tokenAmount > 0) {
            _raiseDividend[_account] = _dividends;
            _mint(_account, tokenAmount);
            emit WithdrawRaiseDividend(_account, tokenAmount, block.timestamp);
        }
    }
}
