// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IConfig {
    enum Tools { MultiSender, Locker, Token, Presale, Utility }

    struct Fees {
        uint256 multisender;
        uint256 locker;
        uint256 token;
        uint256 utility; /// @dev always free
    }

    struct PresaleFees {
        uint256 base;
        uint256 quote;
    }

    function treasury() external view returns (address payable);
    function token() external view returns (address);
    function babyTokenDividendTrackerFactory() external view returns (address);
    function dividendDistributorFactory() external view returns (address);
    function hodl() external view returns (uint256);
    function fees() external view returns (uint256, uint256, uint256, uint256);
    function presaleFees() external view returns (uint256, uint256);
    function whitelist(address) external view returns (bool);
}
