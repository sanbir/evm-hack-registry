// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {FirstLaunch} from "./abstract/FirstLaunch.sol";
import {ExcludedFromFeeList} from "./abstract/ExcludedFromFeeList.sol";
import {Helper} from "./lib/Helper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IUniswapV2Pair
} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {ERC20} from "./abstract/token/ERC20.sol";
import {BaseUSDTWA, USDT} from "./abstract/dex/BaseUSDTWA.sol";

contract ATMToken is ExcludedFromFeeList, FirstLaunch, BaseUSDTWA, ERC20 {
    uint256 public constant MAX_BURN = 159000000 ether;
    uint256 public constant MAX_HOLDER = 100000 ether;
    address public constant DEAD = address(0xdead);

    bool public presale;
    uint40 public coldTime = 1 minutes;

    address public marketingAddress;
    address public dividendAddress;

    uint256 public swapAtAmount = 200 ether;
    uint256 public numTokensSellRate = 20; // 100%

    mapping(address => uint256) public tOwnedU;
    mapping(address => uint40) public lastBuyTime;

    address public immutable STAKING;

    mapping(uint256 => uint112) private _dailyCloseReserveU;

    constructor(
        address staking_,
        address marketingAddress_,
        address dividendAddress_
    ) Owned(msg.sender) ERC20("ATM", "ATM", 18, 210000000 ether) {
        require(staking_ != address(0), "zero staking");
        require(marketingAddress_ != address(0), "zero marketing");
        require(dividendAddress_ != address(0), "zero dividend");

        allowance[address(this)][address(uniswapV2Router)] = type(uint256).max;
        IERC20(USDT).approve(address(uniswapV2Router), type(uint256).max);

        STAKING = staking_;
        marketingAddress = marketingAddress_;
        dividendAddress = dividendAddress_;

        excludeFromFee(msg.sender);
        excludeFromFee(address(this));
        excludeFromFee(STAKING);
    }

    function setPresale() external onlyOwner {
        presale = true;
        launch();
        deliveryReserveU();
    }

    function setColdTime(uint40 _coldTime) external onlyOwner {
        coldTime = _coldTime;
    }

    function getReserveU() external view returns (uint112) {
        uint256 yesterday = (block.timestamp / 1 days) * 1 days - 1 days;
        return _dailyCloseReserveU[yesterday];
    }

    function deliveryReserveU() public {
         (uint112 reserveU, , ) = IUniswapV2Pair(uniswapV2Pair).getReserves();
        _deliveryReserveU(reserveU);
    }

    function _deliveryReserveU(uint112 reserveU) private {
        uint256 zero = (block.timestamp / 1 days) * 1 days;
        _dailyCloseReserveU[zero] = reserveU;
        if (_dailyCloseReserveU[zero - 1 days] == 0) {
            _dailyCloseReserveU[zero - 1 days] = reserveU;
        }
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual override {
        if (
            inSwapAndLiquify ||
            _isExcludedFromFee[sender] ||
            _isExcludedFromFee[recipient]
        ) {
            super._transfer(sender, recipient, amount);
            return;
        }

        uint256 maxAmount = (balanceOf[sender] * 9999) / 10000;
        if (amount > maxAmount) {
            amount = maxAmount;
        }

        if (uniswapV2Pair == sender) {
            require(presale, "pre");
            if (_isRemoveLiquidity()) {
                //remove liquidity
                uint256 tFee = (amount * 500) / 10000;
                uint256 bFee = burnAmt(tFee);
                if (bFee > 0) {
                    super._transfer(sender, DEAD, bFee);
                }
                if (tFee > bFee) {
                    uint256 mFee = tFee - bFee;
                    super._transfer(sender, address(this), mFee);
                }
                super._transfer(sender, recipient, amount - tFee);
            } else {
                // buy
                (uint112 reserveU, uint112 reserveThis, ) = IUniswapV2Pair(
                    uniswapV2Pair
                ).getReserves();
                _deliveryReserveU(reserveU);
                uint256 amountUBuy = Helper.getAmountIn(
                    amount,
                    reserveU,
                    reserveThis
                );
                tOwnedU[recipient] = tOwnedU[recipient] + amountUBuy;
                lastBuyTime[recipient] = uint40(block.timestamp);
                uint256 tFee = (amount * 500) / 10000;
                uint256 bFee = burnAmt(tFee);
                if (bFee > 0) {
                    super._transfer(sender, DEAD, bFee);
                }
                if (tFee > bFee) {
                    super._transfer(sender, address(this), tFee - bFee);
                }
                super._transfer(sender, recipient, amount - tFee);
            }
        } else if (uniswapV2Pair == recipient) {
            if (_isAddLiquidity()) {
                uint256 tFee = (amount * 3000) / 10000;
                if (tFee > 0) {
                    super._transfer(sender, address(this), tFee);
                }
                super._transfer(sender, recipient, amount - tFee);
            } else {
                require(
                    block.timestamp >= lastBuyTime[sender] + coldTime,
                    "cold"
                );
                //sell
                (uint112 reserveU, uint112 reserveThis, ) = IUniswapV2Pair(
                    uniswapV2Pair
                ).getReserves();
                uint256 tFee = (amount * 500) / 10000;
                uint256 amountUOut = Helper.getAmountOut(
                    amount - tFee,
                    reserveThis,
                    reserveU
                );
                _deliveryReserveU(reserveU);
                uint256 fee;
                if (tOwnedU[sender] >= amountUOut) {
                    unchecked {
                        tOwnedU[sender] = tOwnedU[sender] - amountUOut;
                    }
                } else if (tOwnedU[sender] > 0) {
                    uint256 profitU = amountUOut - tOwnedU[sender];
                    uint256 profitThis = Helper.getAmountOut(
                        profitU,
                        reserveU,
                        reserveThis
                    );
                    fee = profitThis / 4;
                    tOwnedU[sender] = 0;
                } else {
                    uint256 profitThis = Helper.getAmountOut(
                        amountUOut,
                        reserveU,
                        reserveThis
                    );
                    fee = profitThis / 4;
                }
                uint256 totalFee = tFee + fee;
                if (totalFee > 0) {
                    super._transfer(sender, address(this), totalFee);
                }
                uint256 contractTokenBalance = balanceOf[address(this)];
                if (contractTokenBalance > swapAtAmount) {
                    uint256 numTokensSellToFund = (amount * numTokensSellRate) /
                        100;
                    if (numTokensSellToFund > contractTokenBalance) {
                        numTokensSellToFund = contractTokenBalance;
                    }
                    _swapTokenForFund(numTokensSellToFund);
                }
                super._transfer(sender, recipient, amount - totalFee);
            }
        } else {
            // normal transfer
            super._transfer(sender, recipient, amount);
        }
        require(
            uniswapV2Pair == recipient || 
            balanceOf[recipient] <= MAX_HOLDER,
            "max holder"
        );
    }

    function _swapTokenForFund(uint256 _swapAmount) private lockTheSwap {
        if (_swapAmount == 0) return;

        IERC20 usdt = IERC20(USDT);
        uint256 initialBalance = usdt.balanceOf(address(this));
        _swapTokenForUsdt(_swapAmount, address(distributor));

        uint256 distributorBalance = usdt.balanceOf(address(distributor));
        if (distributorBalance > 0) {
            usdt.transferFrom(
                address(distributor),
                address(this),
                distributorBalance
            );
        }

        uint256 newBalance = usdt.balanceOf(address(this)) - initialBalance;

        if (newBalance > 0) {
            uint256 dividendAmount = (newBalance * 2) / 5;
            uint256 marketingAmount = newBalance - dividendAmount;

            if (dividendAmount > 0)
                usdt.transfer(dividendAddress, dividendAmount);
            if (marketingAmount > 0)
                usdt.transfer(marketingAddress, marketingAmount);
        }
    }

    function _swapTokenForUsdt(uint256 tokenAmount, address to) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = address(USDT);
        // make the swap
        uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            to,
            block.timestamp
        );
    }

    function burnAmt(
        uint256 _burnAmount
    ) public view returns (uint256 result) {
        uint256 burnAmount = balanceOf[DEAD];
        if (burnAmount < MAX_BURN) {
            return MAX_BURN - burnAmount > _burnAmount
                ? _burnAmount
                : MAX_BURN - burnAmount;
        }
    }

    function recycle(uint256 amount) external {
        require(STAKING == msg.sender, "cycle");
        uint256 maxBurn = balanceOf[uniswapV2Pair] / 3;
        uint256 burn_amount = amount >= maxBurn ? maxBurn : amount;
        super._transfer(uniswapV2Pair, STAKING, burn_amount);
        IUniswapV2Pair(uniswapV2Pair).sync();
    }

    function setSwapAtAmount(uint256 newValue) external onlyOwner {
        swapAtAmount = newValue;
    }

    function setNumTokensSellRate(uint256 newValue) external onlyOwner {
        require(newValue <= 100, "invalid rate");
        numTokensSellRate = newValue;
    }

    function setMarketingAddress(address addr) external onlyOwner {
        require(addr != address(0), "zero address");
        marketingAddress = addr;
    }

    function setDividendAddress(address addr) external onlyOwner {
        require(addr != address(0), "zero address");
        dividendAddress = addr;
    }
}