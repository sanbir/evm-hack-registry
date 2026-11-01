//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";

abstract contract AITradeHubContractCommon is ReentrancyGuard{
    //========
    //EVENTS
    //============================
    event Contribute(address indexed contributor, uint256 amount, uint256 fee, uint256 lockedAmt, int256 debtAmt, ContributionType contributionType);
    event NextTarget();
    event Indexed(address wallet, uint256 amountLocked, uint256 amountPending);
    event ClaimServiceResults(address indexed contributor, address paymentToken, uint256 lockedAmt, int256 debtAmt, uint256 amount, uint256 withdrawalFee);
    event WithdrawFunds(address indexed contributor, address to, uint256 amount, uint256 fee, address token);
    event ServiceResultsDistributed(int256 amount, uint256 monthlyFee);
    event MonthlyFeeCharged(address indexed contributor, uint256 lockedAmt, address token, uint256 fee, uint256 debtAdded);
    event Migrated(address indexed wallet, int256 balance, uint256 lockedAmt, uint256 paidAmt);
    event MigrateWallet(address indexed oldWallet, address indexed newWallet, int256 earnings, uint256 lockedAmt, uint256 pendingAmt, uint256 paidAmt, uint256 fee);
    event TransferFunds(address indexed from, address indexed to, uint256 amount, uint256 fee);
    event ServiceResultLosses(address indexed wallet, int256 amount, uint256 lockedAmt);
    //============================
    //Error
    error AITradeHubPermissionDeniedError();
    error AITradeHubNotVerifyError();
    error AITradeHubAccountNotActiveError();
    error AITradeHubTransferLockedError();
    error AITradeHubAmountInvalidError();
    error AITradeHubNoProfitToClaimError();
    error AITradeHubAlreadyMigratedError();
    error AITradeHubWalletMigrateNotEmptyError();
    error AITradeHubExceedNumberOfTimesError(uint256 nextTime);
    error AITradeHubNotReadyError();
    error AITradeHubAddressInvalidError();
    error AITradeHubDataInvalidError();
    error AITradeHubHubExecutedError();
    error AITradeHubCanceledError();
    error AITradeHubExpiredError();
    error AITradeHubTooEarlyError();
    error AITradeHubSignExpError();
    error AITradeHubSignInvalidError();
    error AITradeHubExceedRequest();
    error AITradeHubApprovalInvalidAddressError();
    error AITradeHubInsufficientAllowanceError(address token, address spender, uint256 allowance, uint256 needed);
    error AITradeHubInsufficientFundsError();

    //Enum
    enum ContributionType{
        NORMAL, RECOMPOUND, MIGRATE
    }

    enum PayoutPreference{
        TRANSFER, COMPOUND
    }


    modifier onlyOwner()  {
        if (!_isOwner()) revert AITradeHubPermissionDeniedError();
        _;
    }
    modifier onlyVerified() {
        if (!_isVerified(msg.sender)) revert AITradeHubNotVerifyError();
        _;
    }

    function _isVerified(address wallet) internal view virtual returns (bool);
    function _isOwner() internal view virtual returns (bool);
    function _isEnhancedSecurityMode(address user) internal view virtual returns (bool);

}