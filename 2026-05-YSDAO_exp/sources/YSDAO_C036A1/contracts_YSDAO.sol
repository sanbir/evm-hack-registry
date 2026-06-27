// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {FirstLaunch} from "./abstract/FirstLaunch.sol";
import {ExcludedFromFeeList} from "./abstract/ExcludedFromFeeList.sol";
import {Helper} from "./lib/Helper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {LpDividendUSDT} from "./abstract/LpDividendUSDT.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {ERC20} from "./abstract/token/ERC20.sol";
import {USDT} from "./abstract/dex/BaseUSDTWA.sol";

contract YSDAO is ExcludedFromFeeList, FirstLaunch, LpDividendUSDT {
    uint256 public constant MAX_BURN = 1000000 ether;
    address public constant DEAD = address(0xdead);

    bool public presale;
    uint40 public coldTime = 1 minutes;

    address public marketingAddress;
    address public distributeAddress;

    uint256 public swapAtAmount = 20 ether;
    uint256 public numTokensSellRate = 20; // 100%

    mapping(address => uint256) public tOwnedU;
    mapping(address => uint40) public lastBuyTime;

    address public immutable STAKING;

    struct POOLUStatus {
        uint112 bal; // pool usdt reserve last time update
        uint40 t; // last update time
    }

    POOLUStatus public poolStatus;

    constructor(
        address staking_,
        address marketingAddress_,
        address distributeAddress_
    ) Owned(msg.sender) ERC20("YSDAO", "YSDAO", 18, 1310000 ether) {
        allowance[address(this)][address(uniswapV2Router)] = type(uint256).max;
        IERC20(USDT).approve(address(uniswapV2Router), type(uint256).max);

        STAKING = staking_;
        marketingAddress = marketingAddress_;
        distributeAddress = distributeAddress_;

        excludeFromFee(msg.sender);
        excludeFromFee(address(this));
        excludeFromFee(STAKING);
        excludeFromFee(marketingAddress);
        excludeFromFee(distributeAddress);
    }

    function setPresale() external onlyOwner {
        presale = true;
        launch();
        updatePoolReserve();
    }

    function setColdTime(uint40 _coldTime) external onlyOwner {
        coldTime = _coldTime;
    }

    function updatePoolReserve() public {
        require(block.timestamp >= poolStatus.t + 1 hours, "1hor");
        poolStatus.t = uint40(block.timestamp);
        (uint112 reserveU, , ) = IUniswapV2Pair(uniswapV2Pair).getReserves();
        poolStatus.bal = reserveU;
    }

    function updatePoolReserve(uint112 reserveU) private {
        if (block.timestamp >= poolStatus.t + 1 hours) {
            poolStatus.t = uint40(block.timestamp);
            poolStatus.bal = reserveU;
        }
    }

    function getReserveU() external view returns (uint112) {
        return poolStatus.bal;
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual override {
        if (inSwapAndLiquify) {
            super._transfer(sender, recipient, amount);
            return;
        }

        setToUsersLp(sender, recipient);

        if (_isExcludedFromFee[sender] || _isExcludedFromFee[recipient]) {
            super._transfer(sender, recipient, amount);
            return;
        }

        if (uniswapV2Pair == sender) {
            require(presale, "pre");
            if (_isRemoveLiquidity()) {
                //remove liquidity
                super._transfer(sender, recipient, amount);
            } else {
                // buy
                unchecked {
                    (uint112 reserveU, uint112 reserveThis, ) = IUniswapV2Pair(
                        uniswapV2Pair
                    ).getReserves();
                    require(amount <= reserveThis / 10, "max cap buy");
                    updatePoolReserve(reserveU);
                    uint256 amountUBuy = Helper.getAmountIn(
                        amount,
                        reserveU,
                        reserveThis
                    );
                    tOwnedU[recipient] = tOwnedU[recipient] + amountUBuy;
                    lastBuyTime[recipient] = uint40(block.timestamp);
                    uint256 tFee = (amount * 300) / 10000;
                    _takeFee(sender, tFee);
                    super._transfer(sender, recipient, amount - tFee);
                }
            }
        } else if (uniswapV2Pair == recipient) {
            require(presale, "pre");
            if (_isAddLiquidity()) {
                unchecked {
                    uint256 tFee = (amount * 300) / 10000;
                    _takeFee(sender, tFee);
                    super._transfer(sender, recipient, amount - tFee);
                }
            } else {
                require(
                    block.timestamp >= lastBuyTime[sender] + coldTime,
                    "cold"
                );
                //sell
                (uint112 reserveU, uint112 reserveThis, ) = IUniswapV2Pair(
                    uniswapV2Pair
                ).getReserves();
                require(amount <= reserveThis / 10, "max cap sell");
                uint256 tFee = (amount * 300) / 10000;
                _takeFee(sender, tFee);
                uint256 amountUOut = Helper.getAmountOut(
                    amount - tFee,
                    reserveThis,
                    reserveU
                );
                updatePoolReserve(reserveU);
                uint256 fee;
                if (tOwnedU[sender] >= amountUOut) {
                    unchecked {
                        tOwnedU[sender] = tOwnedU[sender] - amountUOut;
                    }
                } else if (
                    tOwnedU[sender] > 0 && tOwnedU[sender] < amountUOut
                ) {
                    uint256 profitU = amountUOut - tOwnedU[sender];
                    uint256 profitThis = Helper.getAmountOut(
                        profitU,
                        reserveU,
                        reserveThis
                    );
                    fee = profitThis / 4;
                    tOwnedU[sender] = 0;
                } else {
                    fee = amount / 4;
                    tOwnedU[sender] = 0;
                }
                if (fee > 0) {
                    _takeFee(sender, fee);
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
                super._transfer(sender, recipient, amount - fee - tFee);
                dividendToUsersLp(reserveU);
            }
        } else {
            // normal transfer
            super._transfer(sender, recipient, amount);
        }
    }

    function _swapTokenForFund(uint256 _swapAmount) private lockTheSwap {
        IERC20 usdt = IERC20(USDT);
        uint256 initialBalance = usdt.balanceOf(address(this));
        _swapTokenForUsdt(_swapAmount, address(distributor));
        usdt.transferFrom(
            address(distributor),
            address(this),
            usdt.balanceOf(address(distributor))
        );
        uint256 newBalance = usdt.balanceOf(address(this)) - initialBalance;

        uint256 cAmount = (newBalance * 863) / 1000;
        uint256 distributeAmount = (cAmount * 30) / 70;
        uint256 marketingAmount = newBalance - cAmount;

        if (distributeAmount > 0) {
            usdt.transfer(distributeAddress, distributeAmount);
        }
        if (marketingAmount > 0) {
            usdt.transfer(marketingAddress, marketingAmount);
        }
    }

    function _swapTokenForUsdt(uint256 tokenAmount, address to) private {
        unchecked {
            address[] memory path = new address[](2);
            path[0] = address(this);
            path[1] = address(USDT);
            // make the swap
            uniswapV2Router
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    tokenAmount,
                    0, // accept any amount of ETH
                    path,
                    to,
                    block.timestamp
                );
        }
    }

    function _takeFee(address sender, uint256 fee) private {
        uint256 bFee = _burnAmt(fee, 270);
        if (bFee > 0) {
            super._transfer(sender, DEAD, bFee);
        }
        super._transfer(sender, address(this), fee - bFee);
    }

    function _burnAmt(
        uint256 _amt,
        uint256 _rate
    ) private view returns (uint256 result) {
        uint256 burnAmount = balanceOf[DEAD];
        if (burnAmount < MAX_BURN) {
            result = (_amt * _rate) / 1000;
            result = MAX_BURN - burnAmount > result
                ? result
                : MAX_BURN - burnAmount;
        }
    }

    function recycle(uint256 amount) external {
        require(STAKING == msg.sender, "cycle");
        uint256 maxBurn = balanceOf[uniswapV2Pair] / 3;
        uint256 burn_maount = amount >= maxBurn ? maxBurn : amount;
        super._transfer(uniswapV2Pair, STAKING, burn_maount);
        IUniswapV2Pair(uniswapV2Pair).sync();
    }

    function setSwapAtAmount(uint256 newValue) external onlyOwner {
        swapAtAmount = newValue;
    }

    function setNumTokensSellRate(uint256 newValue) external onlyOwner {
        require(newValue != 0, "greater than 0");
        numTokensSellRate = newValue;
    }

    function setMarketingAddress(address addr) external onlyOwner {
        marketingAddress = addr;
        excludeFromFee(addr);
    }

    function setDistributeAddress(address addr) external onlyOwner {
        distributeAddress = addr;
        excludeFromFee(addr);
    }
}
