// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../swap/InternalSwap.sol";
import "./IOracle.sol";

interface IPancakePair {
    function getReserves() external view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast);
}

contract Oracle is IOracle, Ownable {
    uint256 private minTokenAmount = 0;
    uint256 private maxTokenAmount = 0;

    address public pairAddress;
    address public stableToken;
    address public tokenAddress;
    address public swapAddress;
    uint8 private typeConvert = 1; // 0:average 1: only swap 2: only pancake

    constructor(address _swapAddress, address _stableToken, address _tokenAddress) {
        swapAddress = _swapAddress;
        stableToken = _stableToken;
        tokenAddress = _tokenAddress;
    }

    function convertInternalSwap(uint256 _value, bool toToken) public view returns (uint256) {
        uint256 usdtAmount = InternalSwap(swapAddress).getUsdtAmount();
        uint256 tokenAmount = InternalSwap(swapAddress).getTokenAmount();
        if (tokenAmount > 0 && usdtAmount > 0) {
            uint256 amountTokenDecimal;
            if (toToken) {
                amountTokenDecimal = (_value * tokenAmount) / usdtAmount;
            } else {
                amountTokenDecimal = (_value * usdtAmount) / tokenAmount;
            }

            return amountTokenDecimal;
        }
        return 0;
    }

    function convertUsdBalanceDecimalToTokenDecimal(uint256 _balanceUsdDecimal) public view returns (uint256) {
        uint256 tokenInternalSwap = convertInternalSwap(_balanceUsdDecimal, true);
        uint256 tokenPairConvert;
        if (pairAddress != address(0)) {
            (uint256 _reserve0, uint256 _reserve1, ) = IPancakePair(pairAddress).getReserves();
            (uint256 _tokenBalance, uint256 _stableBalance) = address(tokenAddress) < address(stableToken) ? (_reserve0, _reserve1) : (_reserve1, _reserve0);

            uint256 _minTokenAmount = (_balanceUsdDecimal * minTokenAmount) / 1000000;
            uint256 _maxTokenAmount = (_balanceUsdDecimal * maxTokenAmount) / 1000000;
            uint256 _tokenAmount = (_balanceUsdDecimal * _tokenBalance) / _stableBalance;

            if (_tokenAmount < _minTokenAmount) {
                tokenPairConvert = _minTokenAmount;
            }

            if (_tokenAmount > _maxTokenAmount) {
                tokenPairConvert = _maxTokenAmount;
            }

            tokenPairConvert = _tokenAmount;
        }
        if (typeConvert == 1) {
            return tokenInternalSwap;
        } else if (typeConvert == 2) {
            return tokenPairConvert;
        } else {
            if (tokenPairConvert == 0 || tokenInternalSwap == 0) {
                return tokenPairConvert + tokenInternalSwap;
            } else {
                return (tokenPairConvert + tokenInternalSwap) / 2;
            }
        }
    }

    function setPairAddress(address _address) external onlyOwner {
        require(_address != address(0), "ORACLE: INVALID PAIR ADDRESS");
        pairAddress = _address;
    }

    function setSwapAddress(address _address) external onlyOwner {
        require(_address != address(0), "ORACLE: INVALID SWAP ADDRESS");
        swapAddress = _address;
    }

    function setTypeConvertPrice(uint8 _type) external onlyOwner {
        require(_type <= 2, "ORACLE: INVALID TYPE CONVERT");
        typeConvert = _type;
    }

    function getTypeConvert() external view returns (uint8) {
        return typeConvert;
    }

    function setMinTokenAmount(uint256 _tokenAmount) external onlyOwner {
        minTokenAmount = _tokenAmount;
    }

    function setMaxTokenAmount(uint256 _tokenAmount) external onlyOwner {
        maxTokenAmount = _tokenAmount;
    }

    /**
     * @dev Recover lost bnb and send it to the contract owner
     */
    function recoverLostBNB() public onlyOwner {
        address payable recipient = payable(msg.sender);
        recipient.transfer(address(this).balance);
    }

    /**
     * @dev withdraw some token balance from contract to owner account
     */
    function withdrawTokenEmergency(address _token, uint256 _amount) public onlyOwner {
        require(_amount > 0, "INVALID AMOUNT");
        require(IERC20(_token).transfer(msg.sender, _amount), "CANNOT WITHDRAW TOKEN");
    }
}
