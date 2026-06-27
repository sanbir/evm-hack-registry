pragma solidity 0.8.20;

/**
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SharwaFinance
 * Copyright (C) 2025 SharwaFinance
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 **/

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ILiquidityPool} from"./interfaces/ILiquidityPool.sol";
import {UD60x18, ud, convert, intoUint256, pow, div} from "@prb/math/src/UD60x18.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title LiquidityPool
 * @dev This contract manages a liquidity pool for ERC20 tokens, allowing users to provide liquidity, borrow, and repay loans.
 * @notice Users can deposit tokens to earn interest and borrow against their deposits.
 * @author 0nika0
 */
contract LiquidityPool is ERC20, ERC20Burnable, AccessControl, ILiquidityPool, ReentrancyGuard {
    using Math for uint;
    
    uint private constant ONE_YEAR_SECONDS = 31536000;
    uint private constant INTEREST_RATE_COEFFICIENT = 1e4;
    bytes32 public constant MARGIN_ACCOUNT_ROLE = keccak256("MARGIN_ACCOUNT_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    ERC20 public immutable baseToken;
    ERC20 public immutable poolToken;

    uint public totalBorrowsSnapshotTimestamp;
    uint public depositShare;
    uint public debtSharesSum;
    uint public netDebt;
    uint public totalInterestSnapshot;
    uint public maximumPoolCapacity;
    uint public blockNumberDelay = 1;

    mapping(uint => uint) public portfolioIdToDebt;

    mapping(uint => uint) public shareOfDebt;

    mapping(uint => uint) public borrowingBlockNumber;

    address public insurancePool;

    uint public interestRate = 0.05*1e4;
    uint public insuranceRateMultiplier = 0.2*1e4;
    uint public maximumBorrowMultiplier = 0.8*1e4;

    constructor(
        address _insurancePool,
        address _marginAccountStorage,
        ERC20 _baseToken,
        ERC20 _poolToken,
        string memory _tokenName,
        string memory _tokenSymbol,
        uint _poolCapacity
    ) ERC20(_tokenName, _tokenSymbol) {
        insurancePool = _insurancePool;
        baseToken = _baseToken;
        poolToken = _poolToken;
        totalBorrowsSnapshotTimestamp = block.timestamp;
        maximumPoolCapacity = _poolCapacity;
        _grantRole(MARGIN_ACCOUNT_ROLE, _marginAccountStorage);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ONLY MANAGER_ROLE FUNCTIONS //

    function setMaximumPoolCapacity(uint newMaximumPoolCapacity) external onlyRole(MANAGER_ROLE) {
        maximumPoolCapacity = newMaximumPoolCapacity;

        emit UpdateMaximumPoolCapacity(newMaximumPoolCapacity);
    }

    function setMaximumBorrowMultiplier(uint newMaximumBorrowMultiplier) external onlyRole(MANAGER_ROLE) {
        maximumBorrowMultiplier = newMaximumBorrowMultiplier;

        emit UpdateMaximumBorrowMultiplier(newMaximumBorrowMultiplier);
    }

    function setBlockNumberDelay(uint newBlockNumberDelay) external onlyRole(MANAGER_ROLE) {
        blockNumberDelay = newBlockNumberDelay;
    }

    function setInsurancePool(address newInsurancePool) external onlyRole(MANAGER_ROLE) {
        insurancePool = newInsurancePool;

        emit UpdateInsurancePool(newInsurancePool);
    }

    function setInsuranceRateMultiplier(uint newInsuranceRateMultiplier) external onlyRole(MANAGER_ROLE) {
        require(newInsuranceRateMultiplier <= 0.5*1e4, "The insurance rate multiplier cannot be more than 50%!");
        insuranceRateMultiplier = newInsuranceRateMultiplier;

        emit UpdateInsuranceRateMultiplier(newInsuranceRateMultiplier);
    }

    function setInterestRate(uint newInterestRate) external onlyRole(MANAGER_ROLE) {
        require(newInterestRate > 0, "The interest rate cannot be zero!");
        uint newTotalBorrows = _fixAccruedInterest();
        interestRate = newInterestRate;

        emit UpdateInterestRate(getTotalLiquidity(), newTotalBorrows, interestRate);
    }

    // EXTERNAL FUNCTIONS //

    function provide(uint amount) external nonReentrant {
        uint totalLiquidity = getTotalLiquidity();
        require(
            totalLiquidity + amount <= maximumPoolCapacity,
            "Maximum liquidity has been achieved!"
        );
        poolToken.transferFrom(msg.sender, address(this), amount);
        uint shareChange = totalLiquidity > 0
            ? (depositShare * amount) / totalLiquidity
            : (amount * 10 ** decimals()) / 10 ** poolToken.decimals();
        _mint(msg.sender, shareChange);
        depositShare += shareChange;

        emit Provide(msg.sender, shareChange, amount);
    }

    function withdraw(uint amount) external nonReentrant {
        uint totalLiquidity = getTotalLiquidity();
        require(totalLiquidity != 0, "Liquidity pool has no pool tokens");
        uint amountWithdraw = (amount * totalLiquidity) / depositShare;
        require(
            poolToken.balanceOf(address(this)) >= amountWithdraw,
            "Liquidity pool has not enough free tokens!"
        );
        _burn(msg.sender, amount);
        depositShare -= amount;
        poolToken.transfer(msg.sender, amountWithdraw);

        emit Withdraw(msg.sender, amount, amountWithdraw);
    }

    // ONLY MARGIN_ACCOUNT_ROLE FUNCTIONS //

    function borrow(uint marginAccountID, uint amount) external onlyRole(MARGIN_ACCOUNT_ROLE) {
        require(
            amount > 0,
            "Amount must be greater than 0!"
        );
        require(
            poolToken.balanceOf(address(this)) >= amount,
            "There are not enough tokens in the liquidity pool to provide a loan!"
        );
        uint borrows = _fixAccruedInterest();
        require(
            borrows + amount <=
                ((borrows + poolToken.balanceOf(address(this)))  * maximumBorrowMultiplier) /
                    INTEREST_RATE_COEFFICIENT,
            "Limit is exceed!"
        );
        uint newDebtShare = borrows > 0
            ? debtSharesSum.mulDiv(amount, borrows, Math.Rounding.Up)
            : (amount * 10 ** decimals()) / 10 ** poolToken.decimals();
        
        debtSharesSum += newDebtShare;
        shareOfDebt[marginAccountID] += newDebtShare;
        netDebt += amount;
        portfolioIdToDebt[marginAccountID] += amount;
        poolToken.transfer(msg.sender, amount);

        borrowingBlockNumber[marginAccountID] = block.number;

        emit Borrow(marginAccountID, amount);
    }

function repay(uint marginAccountID, uint amount) external onlyRole(MARGIN_ACCOUNT_ROLE) {
        require(
           borrowingBlockNumber[marginAccountID] + blockNumberDelay <= block.number,
            "The block number has not reached a value that allows to repay loan!"
        );
        uint newTotalBorrows = totalBorrows();
        uint debt = getDebtWithAccruedInterest(marginAccountID);
        uint accruedInterest = debt - portfolioIdToDebt[marginAccountID];
        uint shareChange = debtSharesSum.mulDiv(amount, newTotalBorrows, Math.Rounding.Up); 
        if (debt <= amount) {
            amount = debt;
            shareChange = shareOfDebt[marginAccountID];
        }
        
        uint profit = (accruedInterest * shareChange) / shareOfDebt[marginAccountID];
        uint profitInsurancePool = (profit * insuranceRateMultiplier) / INTEREST_RATE_COEFFICIENT; 
        if (totalInterestSnapshot > 0){
            uint nowInterestSnapshot = Math.mulDiv(newTotalBorrows - netDebt - totalInterestSnapshot, shareOfDebt[marginAccountID], debtSharesSum, Math.Rounding.Up);
            totalInterestSnapshot = (totalInterestSnapshot * shareOfDebt[marginAccountID] + nowInterestSnapshot * shareChange - profit * shareOfDebt[marginAccountID]) / shareOfDebt[marginAccountID];
        } 
        debtSharesSum -= shareChange; 
        shareOfDebt[marginAccountID] -= shareChange;
        if (debt > amount) {
            uint tempDebt = Math.mulDiv(portfolioIdToDebt[marginAccountID], debt - amount, debt, Math.Rounding.Up);
            netDebt = netDebt - (portfolioIdToDebt[marginAccountID] - tempDebt);
            portfolioIdToDebt[marginAccountID] = tempDebt;
        } else {
            netDebt -= portfolioIdToDebt[marginAccountID];
            portfolioIdToDebt[marginAccountID] = 0;
        }
        poolToken.transferFrom(msg.sender, address(this), amount);
        if (profitInsurancePool > 0) {
            poolToken.transfer(insurancePool, profitInsurancePool);
        }

        emit Repay(marginAccountID, amount, profit, profitInsurancePool);
    }


    // VIEW FUNCTIONS //

    function getDebtWithAccruedInterestOnTime(uint marginAccountID, uint checkTime) external view returns (uint debtByPool) {
        require(
            totalBorrowsSnapshotTimestamp < checkTime,
            "The function is designed to calculate future debt!"
        );
        if (debtSharesSum == 0) return 0;
        uint precision = 10 ** 18;
        UD60x18 temp = div(
            convert(
                ((INTEREST_RATE_COEFFICIENT + interestRate) *
                    precision) / INTEREST_RATE_COEFFICIENT
            ),
            convert(precision)
        );
        uint newTotalBorrow = ((netDebt + totalInterestSnapshot) *
                intoUint256(pow(temp, div(convert(checkTime - totalBorrowsSnapshotTimestamp), convert(ONE_YEAR_SECONDS))))) / 1e18;
        uint debtWithAccruedInterest = (newTotalBorrow * shareOfDebt[marginAccountID]) / debtSharesSum;
        if (debtWithAccruedInterest < portfolioIdToDebt[marginAccountID]) {
            debtWithAccruedInterest = portfolioIdToDebt[marginAccountID];
        }
        return debtWithAccruedInterest;
    }

    // PUBLIC FUNCTIONS //

    function getDebtWithAccruedInterest(uint marginAccountID) public view returns (uint debtByPool) {
        if (debtSharesSum == 0) return 0;
        uint debtWithAccruedInterest = (totalBorrows() * shareOfDebt[marginAccountID]) / debtSharesSum;
        if (debtWithAccruedInterest < portfolioIdToDebt[marginAccountID]) {
            debtWithAccruedInterest = portfolioIdToDebt[marginAccountID];
        }
        return debtWithAccruedInterest;
    }

    function totalBorrows() public view returns (uint) {
        uint ownershipTime = block.timestamp - totalBorrowsSnapshotTimestamp;
        uint precision = 10 ** 18;
        UD60x18 temp = div(
            convert(
                ((INTEREST_RATE_COEFFICIENT + interestRate) *
                    precision) / INTEREST_RATE_COEFFICIENT
            ),
            convert(precision)
        );
        return
            ((netDebt + totalInterestSnapshot) *
                intoUint256(pow(temp, div(convert(ownershipTime), convert(ONE_YEAR_SECONDS))))) / 1e18;
    }

    function getTotalLiquidity() public view returns (uint) {
        uint nowTotalBorrows = totalBorrows();
        uint insurancePoolLiquidity = ((nowTotalBorrows - netDebt) * insuranceRateMultiplier) / INTEREST_RATE_COEFFICIENT;
        return poolToken.balanceOf(address(this)) + nowTotalBorrows - insurancePoolLiquidity;
    }

    // PRIVATE FUNCTIONS //

    /**
     * @notice Charges interest rate to traders.
     * @return newTotalBorrows The new total borrows after interest accrual.
     */
    function _fixAccruedInterest() private returns (uint) {
        uint newTotalBorrows = totalBorrows();
        totalInterestSnapshot = newTotalBorrows - netDebt;
        totalBorrowsSnapshotTimestamp = block.timestamp;
        return newTotalBorrows;
    }
}
