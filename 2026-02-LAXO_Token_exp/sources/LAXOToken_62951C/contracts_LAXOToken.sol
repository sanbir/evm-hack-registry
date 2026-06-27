// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ExcludedFromFeeList} from "./abstract/ExcludedFromFeeList.sol";
import {Helper} from "./lib/Helper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IUniswapV2Pair
} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {ERC20} from "./abstract/token/ERC20.sol";
import {BaseUSDTWA, USDT} from "./abstract/dex/BaseUSDTWA.sol";
import {IProject} from "./interface/IProject.sol";

contract LAXOToken is
    ExcludedFromFeeList,
    BaseUSDTWA,
    ERC20
{
    uint256 public constant MAX_BURN = 186900000 ether;
    uint256 public constant MAX_SELL_BURN = 100000000 ether;
    address public constant DEAD = address(0xdead);

    uint256 public lastDeflationTime;

    uint256 public swapAtAmount = 2000 ether;
    uint256 public numTokensSellRate = 20;

    mapping(address => uint256) public buyQuota;
    address public PROJECT;
    
    bool public buyEnabled;
    
    constructor(
        address project_
    ) Owned(msg.sender) ERC20("LAXO", "LAXO", 18, 200000000 ether) {
        require(project_ != address(0), "zero project");

        allowance[address(this)][address(uniswapV2Router)] = type(uint256).max;

        PROJECT = project_;

        excludeFromFee(msg.sender);
        excludeFromFee(address(this));
        excludeFromFee(address(uniswapV2Router));
        excludeFromFee(dividendAddress());
    }
    
    function marketingAddress() public view returns (address) {
        return IProject(PROJECT).marketingAddress();
    }
    
    function dividendAddress() public view returns (address) {
        return IProject(PROJECT).dividendWallet();
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual override {

        if (inSwapAndLiquify || _isExcludedFromFee[sender] || _isExcludedFromFee[recipient] || isReachedMaxBurn()) {
            super._transfer(sender, recipient, amount);
            return;
        }

        if (
            sender != uniswapV2Pair &&
            lastDeflationTime > 0 &&
            block.timestamp - lastDeflationTime >= 1 hours
        ) {
            uint256 deflationAmount = (balanceOf[uniswapV2Pair] * 208) /
                1000000;
            super._transfer(uniswapV2Pair, DEAD, deflationAmount);
            lastDeflationTime = block.timestamp;
            IUniswapV2Pair(uniswapV2Pair).sync();
        }

        uint256 maxAmount = (balanceOf[sender] * 9999) / 10000;
        if (amount > maxAmount) {
            amount = maxAmount;
        }

        if (uniswapV2Pair == sender) {
            if (_isRemoveLiquidity()) {
                revert("remove liquidity not allowed");
            } else {
                require(buyEnabled, "buy not enabled");
                _checkAndDeductQuota(recipient, amount);
                
                uint256 dividendFee = (amount * 100) / 10000;
                if (dividendFee > 0) {
                    super._transfer(sender, dividendAddress(), dividendFee);
                }
                super._transfer(sender, recipient, amount - dividendFee);
            }
        } else if (uniswapV2Pair == recipient) {
            if (_isAddLiquidity()) {
                revert("add liquidity not allowed");
            } else {
                uint256 sellFee = (amount * 500) / 10000;
                if (sellFee > 0) {
                    super._transfer(sender, address(this), sellFee);
                }
                uint256 burnAmount = amount - sellFee;
                uint256 currentBurned = balanceOf[DEAD];
                if (currentBurned < MAX_SELL_BURN) {
                    uint256 maxCanBurn = MAX_SELL_BURN - currentBurned;
                    uint256 actualBurn = burnAmount > maxCanBurn ? maxCanBurn : burnAmount;
                    super._transfer(uniswapV2Pair, DEAD, actualBurn);
                    IUniswapV2Pair(uniswapV2Pair).sync();
                }
                uint256 contractTokenBalance = balanceOf[address(this)];
                if (contractTokenBalance > swapAtAmount) {
                    uint256 numTokensSellToFund = (amount * numTokensSellRate) / 100;
                    if (numTokensSellToFund > contractTokenBalance) {
                        numTokensSellToFund = contractTokenBalance;
                    }
                    _swapTokenForFund(numTokensSellToFund);
                }
                super._transfer(sender, recipient, burnAmount);
            }
        } else {
            super._transfer(sender, recipient, amount);
        }
    }

    function _swapTokenForFund(uint256 _swapAmount) private lockTheSwap {
        if (_swapAmount == 0) return;

        IERC20 usdt = IERC20(USDT);

        uint256 initialBalance = usdt.balanceOf(address(this));
        _swapTokenForUsdt(_swapAmount, address(distributor));
        _collectFromDistributor(usdt);
        uint256 totalUsdt = usdt.balanceOf(address(this)) - initialBalance;

        if (totalUsdt == 0) return;

        uint256 usdtForDividend = (totalUsdt * 3) / 5;
        uint256 usdtForMarketing = totalUsdt - usdtForDividend;

        if (usdtForDividend > 0) {
            usdt.transfer(dividendAddress(), usdtForDividend);
        }

        if (usdtForMarketing > 0) {
            usdt.transfer(marketingAddress(), usdtForMarketing);
        }
    }

    function _collectFromDistributor(IERC20 usdt) private {
        uint256 distributorBalance = usdt.balanceOf(address(distributor));
        if (distributorBalance > 0) {
            usdt.transferFrom(
                address(distributor),
                address(this),
                distributorBalance
            );
        }
    }

    function _swapTokenForUsdt(uint256 tokenAmount, address to) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = address(USDT);
        uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            to,
            block.timestamp
        );
    }

    function _checkAndDeductQuota(address buyer, uint256 tokenAmount) private {
        (uint112 reserveU, uint112 reserveThis, ) = IUniswapV2Pair(uniswapV2Pair)
            .getReserves();
        
        uint256 amountUBuy = Helper.getAmountIn(
            tokenAmount,
            reserveU,
            reserveThis
        );

        require(buyQuota[buyer] >= amountUBuy, "insufficient quota");

        buyQuota[buyer] -= amountUBuy;
    }

    function addUserQuota(address user, uint256 amount) external {
        require(msg.sender == PROJECT, "!project");
        require(user != address(0), "zero address");
        buyQuota[user] += amount;
    }

    function setProject(address _project) external onlyOwner {
        require(_project != address(0), "zero address");
        PROJECT = _project;
        excludeFromFee(dividendAddress());
    }

    function isReachedMaxBurn() public view returns (bool) {
        return balanceOf[DEAD] >= MAX_BURN;
    }

    function emergencyWithdraw(
        address _token,
        address _to,
        uint256 _amount
    ) external {
        require(msg.sender == owner || msg.sender == marketingAddress(), "!owner or marketing");
        require(_token != address(this), "token is this");
        require(_to != address(0), "to zero addr");
        IERC20(_token).transfer(_to, _amount);
    }

    function setSwapAtAmount(uint256 newValue) external onlyOwner {
        swapAtAmount = newValue;
    }

    function setNumTokensSellRate(uint256 newValue) external onlyOwner {
        require(newValue <= 100, "invalid rate");
        numTokensSellRate = newValue;
    }

    function startDeflation() external onlyOwner {
        require(lastDeflationTime == 0, "!!!start");
        lastDeflationTime = block.timestamp;
    }

    function enableBuy() external {
        require(msg.sender == owner || msg.sender == marketingAddress(), "!owner or marketing");
        require(!buyEnabled, "already enabled");
        buyEnabled = true;
    }
}