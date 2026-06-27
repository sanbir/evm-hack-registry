// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

interface IApePool {

    function _setApeStaking(address newApeStaking) external returns (uint256);

    function _setInterestRateModel(address newInterestRateModel)
        external
        returns (uint256);

    function _setReinvestmentFee(uint256 newReinvestmentFee)
        external
        returns (uint256);

    function _setReserveFactor(uint256 newReserveFactorMantissa)
        external
        returns (uint256);

    function accrualBlockNumber() external view returns (uint256);

    function accrueInterest() external returns (uint256);

    function allowance(address owner, address spender)
        external
        view
        returns (uint256);

    function apeCoinStaking() external view returns (address);

    function apeStaking() external view returns (address);

    function approve(address spender, uint256 amount) external returns (bool);

    function balanceOf(address account) external view returns (uint256);

    function balanceOfUnderlying(address owner) external returns (uint256);

    function borrowBalanceCurrent(address account) external returns (uint256);

    function borrowBalanceStored(address account)
        external
        view
        returns (uint256);

    function borrowBehalf(address borrower, uint256 borrowAmount)
        external
        returns (uint256);

    function borrowIndex() external view returns (uint256);

    function borrowRatePerBlock() external view returns (uint256);

    function decimals() external view returns (uint8);

    function exchangeRateCurrent() external returns (uint256);

    function exchangeRateStored() external view returns (uint256);

    function getAccountSnapshot(address account)
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        );

    function getCash() external view returns (uint256);

    function getPendingRewards() external view returns (uint256, uint256);

    function getRewardRatePerBlock() external view returns (uint256);

    function harvest() external returns (uint256);

    function interestRateModel() external view returns (address);

    function mint(uint256 mintAmount) external returns (uint256);

    function mintBehalf(address minter, uint256 mintAmount)
        external
        returns (uint256);

    function owner() external view returns (address);

    function redeem(uint256 redeemTokens) external returns (uint256);

    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);

    function reinvestmentFee() external view returns (uint256);

    function renounceOwnership() external;

    function repayBorrow(uint256 repayAmount) external returns (uint256);

    function repayBorrowBehalf(address borrower, uint256 repayAmount)
        external
        returns (uint256);

    function reserveFactorMantissa() external view returns (uint256);

    function supplyRatePerBlock() external view returns (uint256);

    function sweepToken(address token) external;

    function totalBorrows() external view returns (uint256);

    function totalBorrowsCurrent() external returns (uint256);

    function transferOwnership(address newOwner) external;

    function underlying() external view returns (address);
}