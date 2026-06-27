// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

interface IMarketplace {
    event Buy(address seller, address buyer, uint256 nftId, address refAddress);
    event Sell(address seller, address buyer, uint256 nftId);
    event PayCommission(address buyer, address refAccount, uint256 commissionAmount);

    function systemWallet() external view returns (address);

    function buyByCurrency(uint256[] memory _nftIds, address _refAddress) external;
    function buyByToken(uint256[] memory _nftIds, address _refAddress) external;
    function buyByTokenAndCurrency(uint256[] memory _nftIds, address _refAddress) external;

    function getActiveMemberForAccount(address _wallet) external view returns (uint256);
    function getTotalCommission(address _wallet) external view returns (uint256);
    function getTotalEarnAndCommission(address _wallet) external view returns (uint256);
    function getReferredNftValueForAccount(address _wallet) external view returns (uint256);
    function getNftCommissionEarnedForAccount(address _wallet) external view returns (uint256);
    function getNftSaleValueForAccountInUsdDecimal(address _wallet) external view returns (uint256);
    function getStakeTokenValueUsdDecimal(address _wallet) external view returns (uint256);
    function getRestakeValueUsdDecimal(address _wallet) external view returns (uint256);
    function getTotalCommissionStakeByAddressInUsd(address _wallet) external view returns (uint256);
    function getMaxCommissionByAddressInUsd(address _wallet) external view returns (uint256);
    function getSaleValue(address _wallet) external view returns (uint256);

    function updateCommissionStakeValueData(address _user, uint256 _valueInUsdWithDecimal) external;
    function updateTotalEarnAndCommission(address _user, uint256 _valueInUsdWithDecimal) external;
    function updateReferralData(address _user, address _refAddress) external;

    function getReferralAccountForAccount(address _user) external view returns (address);
    function getReferralAccountForAccountExternal(address _user) external view returns (address);
    function getF1ListForAccount(address _wallet) external view returns (address[] memory);
    function getTeamNftSaleValueForAccountInUsdDecimal(address _wallet) external view returns (uint256);
    function getCommissionRef(address _refWallet, uint256 _totalValueUsdWithDecimal, uint256 _totalCommission, uint16 _commissionBuy) external view returns (uint256);
    function getCommissionCanEarn(address _wallet, uint256 _earnableWithDecimal) external view returns (uint256);

    function possibleChangeReferralData(address _wallet) external view returns (bool);

    function isBuyByToken(uint256 _nftId) external view returns (bool);

    function updateSaleValue(address _receiver, uint256 totalValueUsdWithDecimal) external;
    function updateStakeTokenValue(address _receiver, uint256 _valueUsdWithDecimal, bool _isAdd) external;
    function updateRestakeValue(address _receiver, uint256 _valueUsdWithDecimal, bool _isAdd) external;
    function updateNetworkMintData(address _refWallet, uint256 _totalValueUsdWithDecimal, uint16 _commissionBuy) external;

    function checkValidRefCodeAdvance(address _user, address _refAddress) external view returns (bool);
    function getCommissionPercent(uint8 _level) external view returns (uint16);
    function getTierUsdPercent(uint16 _tier) external view returns (uint256);
    function getConditionTotalCommission(uint8 _level) external returns (uint256);
}
