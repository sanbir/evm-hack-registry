// SPDX-License-Identifier: MIT


pragma solidity 0.7.6;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import './SmartChefInitializable.sol';

contract PoolFactory is SafeOwnable {
    event NewSmartChefContract(address indexed smartChef);

    address[] public allPools;

    function poolLength() external view returns (uint) {
        return allPools.length;
    }

    constructor() SafeOwnable(msg.sender) {
    }

    function deployPool(
        IERC20 _stakedToken,
        IERC20 _rewardToken,
        uint256 _rewardPerBlock,
        uint256 _startBlock,
        uint256 _bonusEndBlock,
        uint256 _poolLimitPerUser,
        address _admin
    ) external onlyOwner {
        require(_stakedToken.totalSupply() >= 0);
        require(_rewardToken.totalSupply() >= 0);
        require(_stakedToken != _rewardToken, "Tokens must be be different");

        bytes memory bytecode = type(SmartChefInitializable).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(_stakedToken, _rewardToken, _startBlock));
        address smartChefAddress;

        assembly {
            smartChefAddress := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        SmartChefInitializable(smartChefAddress).initialize(
            _stakedToken,
            _rewardToken,
            _rewardPerBlock,
            _startBlock,
            _bonusEndBlock,
            _poolLimitPerUser,
            _admin
        );
        allPools.push(smartChefAddress);
        emit NewSmartChefContract(smartChefAddress);
    }
}
