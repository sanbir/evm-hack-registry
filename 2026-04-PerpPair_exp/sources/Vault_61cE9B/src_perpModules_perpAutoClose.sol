// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "../storage/PerpStorage.sol";
import "./perpTrade.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";

abstract contract PerpAutoClose is PerpTrade {
    using Math for uint256;
    using SignedMath for int256;

    event EnabledAutoClose(
        address indexed user,
        uint256 profitTh,
        uint256 lossTh
    );

    ///@notice Function to enable third party users to close your position. Can also be used to change thresholds if the user has this already enabled.
    ///@param profitTh Profit threshold over which the user's position will be closable
    ///@param lossTh Loss threshold under which the user's position will be closable
    ///@param maxSlippage Maximum slippage tolerated by the user when autoclosing the position
    ///@param maxLiqFee Maximum liquidity fee tolerated by the user when autoclosing the position
    function enableAutoClose(uint256 profitTh, uint256 lossTh, uint256 maxSlippage, uint256 maxLiqFee) external {
        require(profitTh > 0 || lossTh > 0, "A");
        address user = _msgSender();
        autoCloseUsersData[user].authorized = true;
        autoCloseUsersData[user].profitTh = profitTh;
        autoCloseUsersData[user].lossTh = lossTh;
        autoCloseUsersData[user].maxSlippage = maxSlippage;
        autoCloseUsersData[user].maxLiqFee = maxLiqFee;
        emit EnabledAutoClose(user, profitTh, lossTh);
    }

    ///@notice Function to disable third party users to close your position.
    function disableAutoClose() external {
        _disableAutoClose(_msgSender());
    }

    ///@notice Function to disable third party users to close your position.
    function _disableAutoClose(address user) private {
        delete autoCloseUsersData[user];
    }

    ///@notice Function to close the position of another user. They must have enabled the autoTrade feature and established the thresholds.
    ///@param user user which position is to be closed.
    ///@param frontendAddress address that will receive the frontend part of the fees.
    ///@param unverifiedReport Chainlink price report.    
    function autoCloseUserPosition(address user, address frontendAddress, bytes memory unverifiedReport) external nonReentrant {
        IOracleMiddleware(oracle).verifyReportIfNecessary(unverifiedReport);
        require(autoCloseUsersData[user].authorized, "A1");
        (uint256 userPnL, bool userPnLSign) = calcPnL(user, getPrice());
        if (userPnLSign){
            require(autoCloseUsersData[user].profitTh != 0 && userPnL >= autoCloseUsersData[user].profitTh, "A1");
        }
        else{
            require(autoCloseUsersData[user].lossTh != 0 && userPnL >= autoCloseUsersData[user].lossTh && userPnL<=getCollateral(user), "A1");
        }
        userVirtualTraderPosition[user].debtStable += autoCloseFee;
        userVirtualTraderPosition[_msgSender()].balanceStable += autoCloseFee;
        _closeAndWithdraw(autoCloseUsersData[user].maxSlippage, autoCloseUsersData[user].maxLiqFee, frontendAddress, user);
        _disableAutoClose(user);
    }
}   