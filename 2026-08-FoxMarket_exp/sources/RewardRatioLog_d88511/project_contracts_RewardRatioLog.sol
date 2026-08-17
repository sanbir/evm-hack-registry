// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";

contract RewardRatioLog is Ownable {

    uint256 public constant BASE_100 = 10000;
    uint256 private constant TIME_BASE = 8 hours;

    string public name;
    uint256 public startTimestamp;
    uint256 public lastTimestamp;

    mapping(address => bool) public operatorMap;
    mapping(uint256 => uint256) public ratioMap;

    event RewardRatioLogged(uint256 timestamp, uint256 ratio);

    constructor(string memory _name, uint256 _ratio) Ownable(msg.sender){
        name = _name;
        
        uint256 timestamp = block.timestamp / TIME_BASE * TIME_BASE;
        ratioMap[timestamp] = _ratio;
        startTimestamp = timestamp;
        lastTimestamp = timestamp;
        emit RewardRatioLogged(timestamp, _ratio);
    }

    modifier onlyOperator() {
        require(operatorMap[msg.sender], "not operator");
        _;
    }

    function setOperator(address _address,bool _state) external onlyOwner{
        operatorMap[_address] = _state;
    }

    function logRatio(uint256 _ratio) external onlyOperator {
        require(_ratio <= BASE_100, "ratio error");
        
        uint256 timestamp = block.timestamp / TIME_BASE * TIME_BASE;
        require(timestamp > lastTimestamp, "ratio exist");        

        for(uint256 i = 1; i < (timestamp - lastTimestamp) / TIME_BASE; i++){
            uint256 _timestamp = lastTimestamp + (i * TIME_BASE);
            ratioMap[_timestamp] = ratioMap[lastTimestamp];
            emit RewardRatioLogged(_timestamp, ratioMap[_timestamp]);
        }

        ratioMap[timestamp] = _ratio;
        lastTimestamp = timestamp;
        emit RewardRatioLogged(timestamp, _ratio);
    }

    function getRatio(uint256 _timestamp) external view returns (uint256){
        uint256 ratio = ratioMap[_timestamp];
        if(ratio == 0){
            return ratioMap[lastTimestamp];
        }
        return ratio;
    }

    function getAlignedRatio(uint256 _timestamp) external view returns (uint256){
        _timestamp = _timestamp / TIME_BASE * TIME_BASE;
        uint256 ratio = ratioMap[_timestamp];
        if(ratio == 0){
            return ratioMap[lastTimestamp];
        }
        return ratio;
    }

}