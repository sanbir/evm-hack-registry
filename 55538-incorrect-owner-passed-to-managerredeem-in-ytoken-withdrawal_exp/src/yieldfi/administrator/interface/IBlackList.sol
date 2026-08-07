// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.20;

interface IBlackList { 
    //functions
    function blackListUsers(address[] calldata _users) external;
    function removeBlackListUsers(address[] calldata _clearedUsers) external;
    function isBlackListed(address _user) external view returns (bool);

    //events
    event BlackListed(address indexed _sender, address indexed _user);
    event BlackListCleared(address indexed _sender, address indexed _user);
}
