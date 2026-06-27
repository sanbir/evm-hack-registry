// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Owned} from "solmate/src/auth/Owned.sol";
import {ERC20} from "./token/ERC20.sol";
import {BaseUSDTWA, USDT} from "./dex/BaseUSDTWA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract LpDividendUSDT is Owned, BaseUSDTWA, ERC20 {
    mapping(address => bool) public isDividendExempt;
    mapping(address => bool) public isInShareholders;
    uint256 public minPeriod = 3 minutes;
    uint256 public lastLPFeefenhongTime;
    address private fromAddress;
    address private toAddress;
    uint256 distributorGasForLp = 500_000;
    address[] public shareholders;
    uint256 currentIndex;
    mapping(address => uint256) public shareholderIndexes;
    uint256 public minDistribution = 0.01 ether;

    constructor() {
        isDividendExempt[address(0)] = true;
        isDividendExempt[address(0xdead)] = true;
    }

    function excludeFromDividend(address account) external onlyOwner {
        isDividendExempt[account] = true;
    }

    function setMinPeriod(uint256 _minPeriod) external onlyOwner {
        minPeriod = _minPeriod;
    }

    function setMinDistribution(uint256 _minDistribution) external onlyOwner {
        minDistribution = _minDistribution;
    }

    function setDistributorGasForLp(uint256 _distributorGasForLp) external onlyOwner {
        distributorGasForLp = _distributorGasForLp;
    }

    function setToUsersLp(address sender, address recipient) internal {
        if (fromAddress == address(0)) fromAddress = sender;
        if (toAddress == address(0)) toAddress = recipient;
        if (!isDividendExempt[fromAddress] && fromAddress != uniswapV2Pair) {
            setShare(fromAddress);
        }
        if (!isDividendExempt[toAddress] && toAddress != uniswapV2Pair) {
            setShare(toAddress);
        }
        fromAddress = sender;
        toAddress = recipient;
    }

    function dividendToUsersLp(uint112 reserveU) internal {
        if (
            IERC20(USDT).balanceOf(address(this)) >= minDistribution && shareholders.length > 0
                && lastLPFeefenhongTime + minPeriod <= block.timestamp
        ) {
            processLp(distributorGasForLp, reserveU);
            lastLPFeefenhongTime = block.timestamp;
        }
    }

    function setShare(address shareholder) private {
        if (isInShareholders[shareholder]) {
            if (IERC20(uniswapV2Pair).balanceOf(shareholder) == 0) {
                quitShare(shareholder);
            }
        } else {
            if (IERC20(uniswapV2Pair).balanceOf(shareholder) == 0) return;
            addShareholder(shareholder);
            isInShareholders[shareholder] = true;
        }
    }

    function addShareholder(address shareholder) private {
        shareholderIndexes[shareholder] = shareholders.length;
        shareholders.push(shareholder);
    }

    function removeShareholder(address shareholder) internal {
        address lastLPHolder = shareholders[shareholders.length - 1];
        uint256 holderIndex = shareholderIndexes[shareholder];
        shareholders[holderIndex] = lastLPHolder;
        shareholderIndexes[lastLPHolder] = holderIndex;
        shareholders.pop();
    }

    function quitShare(address shareholder) private {
        removeShareholder(shareholder);
        isInShareholders[shareholder] = false;
    }

    function processLp(uint256 gas, uint112 reserveU) private {
        uint256 shareholderCount = shareholders.length;
        uint256 nowbanance = IERC20(USDT).balanceOf(address(this));

        uint256 gasUsed = 0;
        uint256 gasLeft = gasleft();

        uint256 iterations = 0;
        uint256 theLpTotalSupply = IERC20(uniswapV2Pair).totalSupply();
        uint256 lockAmount = IERC20(uniswapV2Pair).balanceOf(address(0));
        theLpTotalSupply -= lockAmount;

        while (gasUsed < gas && iterations < shareholderCount) {
            if (currentIndex >= shareholderCount) {
                currentIndex = 0;
            }
            address theHolder = shareholders[currentIndex];
            uint256 holderLpAmount = IERC20(uniswapV2Pair).balanceOf(theHolder);
            uint256 usdtShare;
            unchecked {
                usdtShare = (nowbanance * holderLpAmount) / theLpTotalSupply;
            }
            if (usdtShare > 0 && (holderLpAmount * reserveU) >= (50e18 * theLpTotalSupply)) {
                IERC20(USDT).transfer(theHolder, usdtShare);
            }
            unchecked {
                ++currentIndex;
                ++iterations;
                gasUsed += gasLeft - gasleft();
                gasLeft = gasleft();
            }
        }
    }
}