// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";

contract Log is Ownable {

    string public name;

    mapping(address => bool) public operatorMap;

    uint256[] public blockIdList;

    constructor(string memory _name) Ownable(msg.sender){
        name = _name;
    }

    modifier onlyOperator() {
        require(operatorMap[msg.sender], "not operator");
        _;
    }

    function setOperator(address _address,bool _state) external onlyOwner{
        operatorMap[_address] = _state;
    }

    function addBlockId() external onlyOperator{
        blockIdList.push(block.number);
    }

    function getBlockIdListCount() external view returns (uint256){
        return blockIdList.length;
    }

    function getBlockIdListHistory(uint256 from, uint256 to) external view returns (uint256[] memory, uint256[] memory){
        require(from <= to, "from error");
        require(to < blockIdList.length, "to error");
        uint256[] memory _ids = new uint256[](to - from + 1);
        uint256[] memory _blockNumbers = new uint256[](to - from + 1);
        for(uint256 i = from; i <= to; i++){
            _ids[i - from] = i;
            _blockNumbers[i - from] = blockIdList[i];
        }
        return (_ids, _blockNumbers);
    }
}