// SPDX-License-Identifier: MIT

pragma solidity 0.8.15;

interface INetGymStreet {
    function addGymMlm(address _user, uint256 _referrerId) external;

    function distributeRewards(
        uint256 _wantAmt,
        address _wantAddr,
        address _user
    ) external;

    function getUserCurrentLevel(address _user) external view returns (uint256);

    function updateAdditionalLevel(address _user, uint256 _level) external;
    function getInfoForAdditionalLevel(address _user) external view returns (uint256 _termsTimestamp, uint256 _level);

    function lastPurchaseDateERC(address _user) external view returns (uint256);
    function termsAndConditionsTimestamp(address _user) external view returns (uint256);
    function updatePendingGym(address _user, uint256 _amount) external;
    function internalGymClaim(address _user) external returns (uint256 gymReward, uint256 busdReward);
    function internalBusdCommissionClaim(address _user, uint256 _busdAmount) external;
    function updateUinf(address _newAddress, address _oldAddress) external;
    function updatePendingUSD(address _user, uint256 _busdAmount) external;
    function transferTokens(address _user, address _tokenAddress, uint256 _amount) external;
    function updateBuyBack(uint256 _amount) external;
    function mysteryUtilityRefund(address _address, uint256 _gymAmount) external;
    function updateBuyAndBurnCounter(uint256 _amount) external;
}
