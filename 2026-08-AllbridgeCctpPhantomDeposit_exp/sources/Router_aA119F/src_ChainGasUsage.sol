// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IGasUsage} from "./interfaces/IGasUsage.sol";
import {IGasOracle} from "./interfaces/IGasOracle.sol";

abstract contract ChainGasUsage is IGasUsage, Ownable {
    uint32 public constant DEFAULT_ACTION = 0;
    mapping(uint32 chainId => mapping(uint32 action => uint256 gasAmount)) public chainGasUsage;
    address public gasOracle;

    function setGasOracle(address _gasOracle) external onlyOwner {
        gasOracle = _gasOracle;
    }

    function setChainGasUsage(uint32 chainId, uint256 gasAmount) external onlyOwner {
        chainGasUsage[chainId][DEFAULT_ACTION] = gasAmount;
    }

    function setChainGasUsage(uint32 chainId, uint32 action, uint256 gasAmount) external onlyOwner {
        chainGasUsage[chainId][action] = gasAmount;
    }

    function gasUsage(uint32 chainId) public view virtual override returns (uint256) {
        return chainGasUsage[chainId][DEFAULT_ACTION];
    }

    function gasUsage(uint32 chainId, uint32 action) public view virtual override returns (uint256) {
        return chainGasUsage[chainId][action];
    }

    function getTransactionFeeInNative(uint32 chainId) public view virtual override returns (uint256) {
        return getTransactionFeeInNative(chainId, DEFAULT_ACTION);
    }

    function getTransactionFeeInNative(uint32 chainId, uint32 action) public view virtual override returns (uint256) {
        if (gasOracle == address(0)) {
            return 0;
        }
        return IGasOracle(gasOracle).getTransactionFeeInNative(uint256(chainId), chainGasUsage[chainId][action]);
    }

    function getTransactionFeeInStable(uint32 chainId) public view virtual override returns (uint256) {
        return getTransactionFeeInStable(chainId, DEFAULT_ACTION);
    }

    function getTransactionFeeInStable(uint32 chainId, uint32 action) public view virtual override returns (uint256) {
        if (gasOracle == address(0)) {
            return 0;
        }
        return IGasOracle(gasOracle).getTransactionFeeInStable(uint256(chainId), chainGasUsage[chainId][action]);
    }
}
