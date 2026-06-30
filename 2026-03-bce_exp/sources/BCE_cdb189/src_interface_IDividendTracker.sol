// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IDividendTracker {
    function distributeDividends(uint256 amount) external;

    function withdrawDividend(address account) external returns (uint256 _withdrawableDividend);

    function tokenHoldersLength() external view returns (uint256);

    function totalDividendsDistributed() external view returns (uint256);

    function excludeFromDividends(address account) external;

    function setBalance(address account, uint256 newBalance) external;

    function incBalance(address account, uint256 amount) external;

    function decBalance(address account, uint256 amount) external;

    function accountAt(uint256 i) external view returns (address account);

    function balanceOf(address account) external view returns (uint256);

    function withdrawableDividendOf(address account) external view returns (uint256);
}
