// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/Strings.sol';
import '@openzeppelin/contracts/utils/Context.sol';
import '../core/SafeOwnable.sol';
import 'hardhat/console.sol';
import '../core/Random.sol';

contract RoomExtention is SafeOwnable {
    using SafeMath for uint256;
    using Strings for uint256;

    event NewRoomExtention(address roomManager, uint rid, bytes32 roomId, bytes32 name, string rules, string logo, uint position, bool display);

    struct RoomInfo {
        uint256 rid;
        bytes32 roomId;
        bytes32 name;
        string rules;
        string logo;
        uint position;
        bool display;
    }

    mapping(uint256 => RoomInfo) public roomInfo;
    address public roomManager;

    constructor(address _roomManager) SafeOwnable(msg.sender) {
        roomManager = _roomManager;
    }

    function addOrSetRoomInfo(
        uint rid, bytes32 roomId, bytes32 name, string memory rules, string memory logo, uint position, bool display
    ) external onlyOwner {
        RoomInfo storage room = roomInfo[rid];
        room.rid = rid;
        room.roomId = roomId;
        room.name = name;
        room.rules = rules;
        room.logo = logo;
        room.position = position;
        room.display = display;
        emit NewRoomExtention(roomManager, rid, roomId, name, rules, logo, position, display);
    }
}
