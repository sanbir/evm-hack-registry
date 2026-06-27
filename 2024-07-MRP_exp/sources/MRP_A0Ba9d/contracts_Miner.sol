// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

abstract contract Miner is ERC20 {

    uint8 constant public MINER_DAY = 21;

    address public lastMiner;

    address public highestMiner;

    uint256 public outputTotal;

    uint256 private _minerTotal;

    uint256 private _totalDividends;

    uint256 private _miningDayPool;

    mapping(uint256 => uint256) private _dividendList;

    mapping(address => miner) private _minerInfo;

    mapping(uint256 => uint256) private _daySubMiner;

    mapping(uint256 => uint256) private _dayOutput;

    struct miner {
        bool minerStatus;
        uint256 minerDayOutput;
        uint256 minerBalance;
        uint256 minerDividends;
        uint256 minerStart;
        uint256 minerEnd;
        uint256 minerTotal;
        uint256 minerTokenTotal;
    }

    event WithdrawMiner(
        address indexed miner,
        uint256 indexed minerToken,
        uint256 indexed withdrawTime,
        uint256 oldMinerDividends,
        uint256 newMinerDividends
    );

    event MinerStatus(
        address indexed miner,
        uint256 indexed minerDayOutput,
        bool indexed minerStatus,
        uint256 minerDividends,
        uint256 minerBalance
    );

    event HighestMiner(
        address indexed miner,
        uint256 indexed amount
    );

    event DayOutput(
        uint256 indexed dayNum,
        uint256 indexed output,
        uint256 indexed minerPool
    );

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {

    }

    function getMinerInfo(address _miner) public view returns (miner memory) {
        return _minerInfo[_miner];
    }

    function getMiningTotal() public view returns (uint256 miningTotal) {
        return _minerTotal;
    }

    function getMiningDayPool() public view returns (uint256 miningDayPool) {
        return _miningDayPool;
    }

    function getMinerStatus(address _miner) public view returns (bool){
        if (getDayNum() >= _minerInfo[_miner].minerEnd) {
            return false;
        }
        return _minerInfo[_miner].minerStatus;
    }

    function _addMiner(address _miner, uint256 _minerAmount) internal {
        _minerInfo[_miner].minerTotal += _minerAmount;
        _minerTotal += _minerAmount;
        _withdrawMiner(_miner);
        if (_minerInfo[_miner].minerStatus) {
            _daySubMiner[_minerInfo[_miner].minerEnd] -= _minerInfo[_miner].minerDayOutput;
            _miningDayPool -= _minerInfo[_miner].minerDayOutput;
            uint256 oldBalance = _minerInfo[_miner].minerBalance;
            if(oldBalance > 0){
                uint256 minerBalance = getMinerBalance(_miner);
                _minerInfo[_miner].minerBalance = minerBalance;
                _minerTotal -= (oldBalance - minerBalance);
            }
        }
        _minerInfo[_miner].minerBalance += _minerAmount;
        uint256 minerAmount = _minerInfo[_miner].minerBalance * (100 + MINER_DAY) / 100;
        uint256 minerDayOutput = minerAmount / MINER_DAY;
        _minerInfo[_miner].minerDayOutput = minerDayOutput;
        _minerInfo[_miner].minerStatus = true;
        _minerInfo[_miner].minerDividends = _totalDividends;
        uint256 dayNum = getDayNum();
        uint256 endDayNum = dayNum + MINER_DAY;
        _minerInfo[_miner].minerStart = dayNum;
        _minerInfo[_miner].minerEnd = endDayNum;
        _daySubMiner[endDayNum] += minerDayOutput;
        _miningDayPool += minerDayOutput;
        _setHighestMiner(_miner);
        _setLastMiner(_miner);
        emit MinerStatus(
            _miner,
            minerDayOutput,
            true,
            _totalDividends,
            minerAmount
        );
    }

    function _setHighestMiner(address _miner) internal {
        uint256 minerAmount = getMinerBalance(_miner);
        if (highestMiner != _miner && minerAmount > getMinerBalance(highestMiner) ) {
            highestMiner = _miner;
            emit HighestMiner(_miner, minerAmount);
        }
    }

    function _getHighestMiner() internal {
        if (_minerInfo[highestMiner].minerEnd <= getDayNum()) highestMiner = address(0);
    }

    function getHighestAmount() public view returns (uint256 highestAmount)
    {
        highestAmount = getMinerBalance(highestMiner);
    }

    function _withdrawMiner(address _miner) internal {
        if (_minerInfo[_miner].minerStatus) {
            uint256 minerToken = _minerTokenBalance(_miner);
            if(minerToken > 0){
                uint256 minerEndDay = _minerInfo[_miner].minerEnd;
                _minerInfo[_miner].minerTokenTotal += minerToken;
                uint256 dayNum = getDayNum();
                uint256 dividends = dayNum < minerEndDay ? _dividendList[dayNum] : _dividendList[minerEndDay];
                emit WithdrawMiner(
                    _miner,
                    minerToken,
                    block.timestamp,
                    _minerInfo[_miner].minerDividends,
                    dividends
                );
                _mint(_miner, minerToken);
                _minerInfo[_miner].minerDividends = _totalDividends;
            }
            uint256 minerBalance = getMinerBalance(_miner);
            if (minerBalance <= 0) {
                _minerInfo[_miner].minerStatus = false;
                _minerTotal -= _minerInfo[_miner].minerBalance;
                _minerInfo[_miner].minerBalance = minerBalance;
            }
            emit MinerStatus(
                _miner,
                _minerInfo[_miner].minerDayOutput,
                _minerInfo[_miner].minerStatus,
                _minerInfo[_miner].minerDividends,
                minerBalance
            );
        }
    }

    function getMinerBalance(address _miner) public view returns (uint256 balance) {
        uint256 dayNum = getDayNum();
        if (_minerInfo[_miner].minerEnd <= dayNum) {
            balance = 0;
        } else {
            balance = _minerInfo[_miner].minerBalance * (_minerInfo[_miner].minerEnd - dayNum) / MINER_DAY;
        }
    }

    function getMinerBalanceOf(address _miner) public view returns (uint256 balance) {
        uint256 dayNum = getDayNum();
        if (_minerInfo[_miner].minerEnd <= dayNum) {
            balance = 0;
        } else {
            balance = _minerInfo[_miner].minerBalance;
        }
    }

    function _minerTokenBalance(address _miner) internal view returns (uint256) {
        if (!_minerInfo[_miner].minerStatus) return 0;
        uint256 dayNum = getDayNum();
        uint256 minerEndDay = _minerInfo[_miner].minerEnd;
        uint256 dividends = dayNum < minerEndDay ? _dividendList[dayNum] : _dividendList[minerEndDay];
        dividends = dividends != 0 ? dividends : _totalDividends;
        uint256 minerDividends = dividends - _minerInfo[_miner].minerDividends;
        return _minerInfo[_miner].minerDayOutput * minerDividends / 1 ether;
    }

    function _setLastMiner(address _lastMiner) internal {
        if (lastMiner != _lastMiner) lastMiner = _lastMiner;
    }

    function _addMinerDividend(uint256 _dividends) internal {
        uint256 dayNum = getDayNum();
        if (_dividendList[dayNum] == 0) {
            _totalDividends += _dividends;
            _dividendList[dayNum] = _totalDividends;
            uint256 output = _miningDayPool * _dividends / 1 ether;
            emit DayOutput(
                dayNum,
                output,
                _miningDayPool
            );
            outputTotal += output;
            _miningDayPool -= _daySubMiner[dayNum];
        }
    }


    function getDayNum() internal view returns (uint256) {
        return block.timestamp / 1 days;
    }
}