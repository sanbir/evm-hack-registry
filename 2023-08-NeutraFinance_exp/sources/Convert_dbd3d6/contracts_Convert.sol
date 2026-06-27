// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/Pausable.sol";
import {Governable} from "./libraries/Governable.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {ICamelotPair} from "./interfaces/ICamelotPair.sol";


contract Convert is Governable, Pausable{
    ICamelotPair public inputToken;
    ICamelotPair public outputToken;
    address public pairToken;

    event Converted(address indexed receiver, uint256 amountInt, uint256 amountOut);

    constructor(address _pairToken) {
        pairToken = _pairToken;
    }

    function setConfigs(address _inputToken, address _outputToken) external onlyGov {
        inputToken = ICamelotPair(_inputToken);
        outputToken = ICamelotPair(_outputToken);
    }

    function convert(uint256 _amount) external whenNotPaused {
        inputToken.transferFrom(msg.sender, address(this), _amount);
        uint256 amountOut = getAmountOut(_amount);
        require(outputToken.balanceOf(address(this)) >= amountOut, "not enough output token");

        outputToken.transfer(msg.sender ,amountOut);
        emit Converted(msg.sender, _amount, amountOut);
    }

    function getAmountOut(uint256 _amount) view public returns(uint256) {
        (uint256 reserves0, uint256 reserves1,,) = inputToken.getReserves();
        uint256 inputTotalSupply = inputToken.totalSupply();

        uint256 pairTokenAmount;
        if (pairToken == inputToken.token0()) {
            pairTokenAmount = reserves0 * _amount / inputTotalSupply;
        } else {
            pairTokenAmount = reserves1 * _amount / inputTotalSupply;
        }

        (uint256 reserves2, uint256 reserves3,,) = outputToken.getReserves();
        uint256 outputTotalSupply = outputToken.totalSupply();

        if (pairToken == outputToken.token0()) {
            return outputTotalSupply * pairTokenAmount / reserves2;
        } else {
            return outputTotalSupply * pairTokenAmount / reserves3;
        }
    }
    
    // to help users who accidentally send their tokens to this contract
    function withdrawToken(address _token, address _account, uint256 _amount) external onlyGov {
        IERC20(_token).transfer(_account, _amount);
    }

    function pause() external onlyGov {
        _pause();
    }

    function unpause() external onlyGov {
        _unpause();
    }
}