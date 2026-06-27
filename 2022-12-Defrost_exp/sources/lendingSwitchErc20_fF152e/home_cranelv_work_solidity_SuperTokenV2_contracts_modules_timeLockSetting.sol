/**
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2020 defrost Protocol
 */
pragma solidity >=0.7.0 <0.8.0;
abstract contract timeLockSetting{
    struct settingInfo {
        uint256 info;
        uint256 acceptTime;
    }
    mapping(uint256=>settingInfo) public settingMap;
    uint256 public constant timeSpan = 2 days;

    event SetValue(address indexed from,uint256 indexed key, uint256 value,uint256 acceptTime);
    event AcceptValue(address indexed from,uint256 indexed key, uint256 value);
    function _set(uint256 key, uint256 _value)internal{
        settingMap[key] = settingInfo(_value,block.timestamp+timeSpan);
        emit SetValue(msg.sender,key,_value,block.timestamp+timeSpan);
    }
    function _remove(uint256 key)internal{
        settingMap[key] = settingInfo(0,0);
        emit SetValue(msg.sender,key,0,0);
    }
    function _accept(uint256 key)internal returns(uint256){
        require(settingMap[key].acceptTime>0 && settingMap[key].acceptTime < block.timestamp , "timeLock error!");
        emit AcceptValue(msg.sender,key,settingMap[key].info);
        return settingMap[key].info;
    }
}
