// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

interface IThrusterYield {
    function claimYieldAll(address _recipient, uint256 _amountWETH, uint256 _amountUSDB)
        external
        returns (uint256 amountWETH, uint256 amountUSDB, uint256 amountGas);
    function claimGas(address _recipient, uint256 _minClaimRateBips) external returns (uint256 amount);

    function setManager(address _manager) external;
}
