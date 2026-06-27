// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IToken {
    function whitelist(address user) external view returns (bool);

    function notifyRewardAmount(uint256 reward) external;

    function setWhitelist(address user, bool state) external;

    function transferOwnership(address newOwner) external;
}
