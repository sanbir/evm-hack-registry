// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IMokeToken {
    function enableTrading() external;
    function isTradingEnabled() external view returns (bool);
    function setTaxRate(uint256 _lpRate, uint256 _nftRate, uint256 _marketingRate) external;
    function setMarketingWallet(address _wallet) external;
    function setWhitelist(address account, bool status) external;
    function setMarketPair(address _pair, bool status) external;
    function addReleasedBalance(address user, uint256 amount) external;
    function releaseFromPair(address to, uint256 amount) external;
    function releasedMokeBalance(address user) external view returns (uint256);
}
