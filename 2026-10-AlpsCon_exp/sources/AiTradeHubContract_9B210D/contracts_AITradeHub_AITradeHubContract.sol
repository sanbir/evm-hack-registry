//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IERC20} from "../interfaces/IERC20.sol";
import {ISwapContract} from "../interfaces/ISwapContract.sol";
import {SafeERC20} from "../math/SafeERC20.sol";
import {AITradeHubContractCommon} from "./AITradeHubContractCommon.sol";
import {AiTradeHubContractEnhancedSecurity} from "./AITradeHubContractEnhancedSecurity.sol";
import {AiTradeHubContractMigrateWallet} from "./AITradeHubContractMigrateWallet.sol";
import {AiTradeHubContractTransferFund} from "./AITradeHubContractTransferFund.sol";
import {AiTradeHubContractWithdrawFund} from "./AITradeHubContractWithdrawFund.sol";
import {AITradeHubDistributionMultisigV2} from "./AITradeHubDistributionMultisigV2.sol";
import {IAITradeHubContractV8} from "./interfaces/IAITradeHubContractV8.sol";
import {IAITradeHubFundModuleContractV2} from "./interfaces/IAITradeHubFundModuleContractV2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title AI Trading Service Access Contract
 * @notice Manages ALPS utility tokens for AI trading service access
 * @dev IMPORTANT: This is NOT an investment contract.
 * - ALPS tokens are service credits for AI trading services
 * - Users pay for AI-powered trading services, not making investments
 * - AlpsCon trades with OWN capital, not user funds
 * - Distributions are service results from AI performance
 * - This is a technology service, not a financial product
 */
contract AiTradeHubContract is AITradeHubContractCommon, AiTradeHubContractWithdrawFund, AiTradeHubContractTransferFund, AiTradeHubContractMigrateWallet, AiTradeHubContractEnhancedSecurity, AITradeHubDistributionMultisigV2 {
    using SafeERC20 for IERC20;


    struct Contributor {
        int256 earningAmount; // Service result
        uint256 lockedAmount; // Active service credits
        uint256 pendingAmount; // Queued service credits
        uint256 paidAmount; //Total service results received
        int256 entryProfitPerShare;
        uint256 lastFeeCharged;
        PayoutPreference payoutPreference; // distribution type
        uint256 lastWalletMigrate; //last wallet migrate time
        bool migrated;
        bool enhancedSecurity;
    }

    struct ContractConfig {
        address owner;
        IAITradeHubFundModuleContractV2 fundContract;
        ISwapContract swapContract;
        IAITradeHubContractV8 aiTradeHubContractV8;
        IERC20 payableERC20; // use for contributors contribute
        IERC20 paymentERC20; // use for payout to contributors
        uint256 withdrawalFee;
        uint256 contributionFee;
        uint256 monthlyFee;
        uint256 paymentTokenExchangeRate; //10 mean 10 ALPS = 1 USDC
        mapping(address => bool) whiteListAddress;

    }

    struct ContractStats {
        address[] contributorAddresses;
        mapping(address => uint256) addressIndexes;
        int256 profitPerShare;
        uint256 totalLockedAmount;
        uint256 totalPendingAmount;
        uint256 lastDistributeProfit;
        uint256 lastAutoPerformIndex;
        uint256 currentMonthlyFee;
    }


    uint256 private constant  INTEREST_DECIMAL_PRECISION = 1e10;
    uint256 private constant FEE_DENOMINATOR = 1000;


    ContractConfig private config;
    ContractStats private stats;
    mapping(address => Contributor) private contributors;
    // Structure: tokenAddress => owner => spender => amount
    mapping(address => mapping(address => mapping(address => uint256))) private allowances;
    uint public constant CONTRACT_VERSION = 9;

    struct InitConfig {
        address payableERC20;
        address paymentERC20;
        address fundContract;
        address swapContract;
        address aiTradeHubContractV8;
        uint256 withdrawal_fee;
        uint256 contribution_fee;
        uint256 monthly_fee;
        uint256 payment_token_exchange_rate;

        //multisign
        address[] signers;
        uint256 requireConfirmations;
        uint64 delay;
        uint64 ttl;
    }
    constructor(InitConfig memory cfg) AiTradeHubContractWithdrawFund(cfg.payableERC20){
        config.owner = msg.sender;
        config.payableERC20 = IERC20(cfg.payableERC20);
        config.paymentERC20 = IERC20(cfg.paymentERC20);
        config.fundContract = IAITradeHubFundModuleContractV2(cfg.fundContract);
        config.swapContract = ISwapContract(cfg.swapContract);
        config.aiTradeHubContractV8 = IAITradeHubContractV8(cfg.aiTradeHubContractV8);
        config.withdrawalFee = cfg.withdrawal_fee;
        config.contributionFee = cfg.contribution_fee;
        config.monthlyFee = cfg.monthly_fee;
        config.paymentTokenExchangeRate = cfg.payment_token_exchange_rate;
        _initMultisig(cfg.signers, cfg.requireConfirmations, cfg.delay, cfg.ttl);
    }

    //OWNER function
    function setSwapContract(address swapContract) external onlyOwner {
        config.swapContract = ISwapContract(swapContract);
    }

    function chargeMonthlyFee(address user) external onlyOwner {
        _chargeProRatedMonthlyFee(user);
    }

    function setWhiteListAddress(address _address, bool whiteList) external onlyOwner {
        config.whiteListAddress[_address] = whiteList;
    }

    function resetMigrate(address user) external onlyOwner {
        Contributor storage contributor = contributors[user];
        contributor.migrated = false;
    }

    //====END=====
    //automation function
    function performAutomation(uint256 batchSize) external nonReentrant onlyOwner {

        uint256 total = stats.contributorAddresses.length;
        uint256 startIndex = stats.lastAutoPerformIndex;
        if (startIndex >= total) {
            stats.lastAutoPerformIndex = 0;
            return;
        }
        uint256 endIndex = startIndex + batchSize;
        if (endIndex > total) endIndex = total;

        for (uint256 i = startIndex; i < endIndex; i++) {
            address user = stats.contributorAddresses[i];
            _performAutomation(user);
        }
        if (endIndex == total) {
            // finished full cycle
            stats.lastAutoPerformIndex = 0;
        } else {
            stats.lastAutoPerformIndex = endIndex;
        }
    }

    function performAutomationByUser(address[] calldata users) external nonReentrant onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            _performAutomation(users[i]);
        }
    }

    function _performAutomation(address user) internal {
        _insert_address_if_not_existed(user);
        Contributor storage contributor = contributors[user];
        int256 earnings = _getUserEarningsAmount(user);
        if (earnings > 0) {
            PayoutPreference payoutPreference = _getUserPayoutPreference(user);
            if (payoutPreference == PayoutPreference.COMPOUND) {
                _recompound(user);
            } else {
                _claimServiceResults(user);
            }
        } else {
            int256 currentLoss = _calculateUserEarningByShares(user);
            if (currentLoss != 0) {
                _updateUserProfitCheckpoint(user);
                emit ServiceResultLosses(user, currentLoss, _getUserLockedAmount(user));
                //reset monthly fee
                contributor.lastFeeCharged = block.timestamp;
            }

        }
        _convertPendingToLocked(user);
    }

    //======END=========

    //PUBLIC function
    function purchaseServiceCredits(uint256 amount) external onlyVerified nonReentrant {
        address user = msg.sender;
        _purchaseServiceCredits(user, amount, ContributionType.NORMAL, 0);
    }

    function claimServiceResults() external onlyVerified nonReentrant {
        _claimServiceResults(msg.sender);
    }

    function recompound() external onlyVerified nonReentrant {
        return _recompound(msg.sender);
    }

    function migrate() external onlyVerified nonReentrant {
        _migrate();
    }

    function transferFrom(address tokenAddress, address from, address to, uint256 amount) external onlyVerified nonReentrant {
        address spender = msg.sender;
        if (!config.whiteListAddress[to]) revert AITradeHubPermissionDeniedError();
        _spendAllowance(tokenAddress, from, spender, amount);
        _transfer(tokenAddress, from, to, amount);
    }

    function approve(address[] calldata tokenAddresses, address spender, uint256 amount) external onlyVerified {
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            _approve(tokenAddresses[i], msg.sender, spender, amount);
        }
    }

    function allowance(address tokenAddress, address owner, address spender) external view onlyVerified returns (uint256) {
        return allowances[tokenAddress][owner][spender];
    }

    function setPayoutPreference(PayoutPreference payoutPreference) external {
        _setPayoutPreference(msg.sender, payoutPreference);
    }

    function getStats(address user) external view returns (
        uint num_contributors,
        uint256 total_pending_amount,
        uint256 total_locked_amount,
        uint256 last_distribute_profit,
        uint256 user_locked_amount,
        uint256 user_pending_amount,
        uint256 user_paid_amount,
        int256 user_earnings,
        uint256 user_current_service_fee,
        PayoutPreference user_payout_type,
        bool enhancedSecurity
    ){
        (
        ,
            total_pending_amount,
            total_locked_amount,
        ,
            user_locked_amount,
            user_pending_amount,
        ,
        ,
        ,
        ) = getV8Stats(user);
        num_contributors = stats.contributorAddresses.length;
        total_locked_amount = stats.totalLockedAmount + total_locked_amount;
        total_pending_amount = stats.totalPendingAmount + total_pending_amount;
        last_distribute_profit = stats.lastDistributeProfit;
        Contributor memory contributor = contributors[user];
        user_locked_amount = contributor.lockedAmount + user_locked_amount;
        user_pending_amount = contributor.pendingAmount + user_pending_amount;
        user_paid_amount = contributor.paidAmount;
        user_earnings = _getUserEarningsAmount(user);
        user_current_service_fee = _getProRatedMonthlyFee(user);
        user_payout_type = _getUserPayoutPreference(user);
        enhancedSecurity = contributor.enhancedSecurity;
    }

    function getV8Stats(address wallet) public view returns (
        uint num_contributors,
        uint256 total_pending_amount,
        uint256 total_locked_amount,
        uint256 last_distribute_profit,
        uint256 user_locked_amount,
        uint256 user_pending_amount,
        uint256 user_paid_amount,
        int256 user_earnings,
        uint256 user_current_service_fee,
        IAITradeHubContractV8.PayoutPreference user_payout_type
    ){
        return config.aiTradeHubContractV8.getStats(wallet);
    }

    function getConfig() external view
    returns (
        address owner,
        address paymentERC20,
        address payableERC20,
        uint256 contribution_fee,
        uint256 withdrawal_fee,
        uint256 monthly_fee,
        uint256 compound_fee
    )
    {
        owner = config.owner;
        paymentERC20 = address(config.paymentERC20);
        payableERC20 = address(config.payableERC20);
        contribution_fee = config.contributionFee;
        withdrawal_fee = config.withdrawalFee;
        monthly_fee = config.monthlyFee;
        compound_fee = config.contributionFee / 2;
    }

    function getLastAutoPerformIndex() external view returns (uint256){
        return stats.lastAutoPerformIndex;
    }

    //====END=====

    //INTERNAL function
    function _purchaseServiceCredits(address wallet, uint256 amount, ContributionType contributionType, int256 debitAmt) internal {
        uint256 contributionFee = 0;
        uint256 contributionAmount = amount;
        if (contributionType == ContributionType.NORMAL) {
            if (amount == 0) revert AITradeHubAmountInvalidError();
            contributionFee = _get_fee(amount, config.contributionFee);
            unchecked{
                contributionAmount -= contributionFee;
            }
            //Transfer amount to contract
            config.payableERC20.safeTransferFrom(wallet, address(this), amount);
            //Transfer fee to fund contract
            _sendToFundContract(config.payableERC20, contributionFee, contributionFee);
        } else if (contributionType == ContributionType.RECOMPOUND) {
            contributionFee = _get_fee(amount, config.contributionFee) / 2;
            unchecked{
                contributionAmount -= contributionFee;
            }
            //Transfer fee to fund contract
            _sendToFundContract(config.payableERC20, contributionFee, contributionFee);
        }
        _insert_address_if_not_existed(wallet);
        //Add pending amount
        _addPendingAmount(wallet, contributionAmount);
        emit Contribute(wallet, contributionAmount, contributionFee, _getUserLockedAmount(wallet), debitAmt, contributionType);
    }


    function _distributeServiceResults(int256 amount) internal override {
        uint256 totalLockedAmount = _getTotalLockedAmount();
        if (totalLockedAmount == 0) revert AITradeHubNotReadyError();
        int256 delta = (amount * int256(INTEREST_DECIMAL_PRECISION)) / int256(totalLockedAmount);
        stats.profitPerShare += delta;
        stats.lastDistributeProfit = block.timestamp;
        stats.currentMonthlyFee = _getMonthlyFeeByDistribution(amount, totalLockedAmount);
        if (amount > 0) {
            _withdrawFromFundContract(uint256(amount));

        }
        emit ServiceResultsDistributed(amount, stats.currentMonthlyFee);
    }

    function _claimServiceResults(address user) internal {
        Contributor storage contributor = contributors[user];
        bool automation = (msg.sender == config.owner);
        int256 lastClaimableAmt = _getUserEarningsAmountWithoutShare(user);
        _updateUserProfitCheckpoint(user);
        // Charge accurate monthly fee by time elapsed
        _chargeProRatedMonthlyFee(user);
        int256 claimAmount = _getUserEarningsAmount(user);
        if (claimAmount > contributor.earningAmount) claimAmount = contributor.earningAmount;
        if (claimAmount <= 0) {
            if (!automation) revert AITradeHubNoProfitToClaimError();
            else return;
        }
        unchecked{
        //reset earning
            contributor.earningAmount -= claimAmount;
        }
        uint256 uClaimAmount = uint256(claimAmount);
        uint256 withdrawalFee = _get_fee(uClaimAmount, config.withdrawalFee);
        uint256 netClaimAmount = uClaimAmount - withdrawalFee;

        if (netClaimAmount > 0) {
            config.paymentERC20.safeTransfer(user, netClaimAmount);
            contributor.paidAmount += netClaimAmount;
            _sendToFundContract(config.paymentERC20, withdrawalFee, withdrawalFee);
        }
        emit ClaimServiceResults(user, address(config.paymentERC20), _getUserLockedAmount(user), lastClaimableAmt, netClaimAmount, withdrawalFee);
    }

    function _recompound(address user) internal {
        Contributor storage contributor = contributors[user];
        bool automation = (msg.sender == config.owner);
        int256 debitAmt = _getUserEarningsAmountWithoutShare(user);
        if (debitAmt > 0) debitAmt = 0;

        _updateUserProfitCheckpoint(user);
        // Charge accurate monthly fee by time elapsed
        _chargeProRatedMonthlyFee(user);
        int256 claimAmount = _getUserEarningsAmount(user);
        if (claimAmount <= 0) {
            if (!automation) revert AITradeHubNoProfitToClaimError();
            else return;
        }

        uint256 uClaimAmount = uint256(claimAmount);
        uint256 netClaimAmountToALPS = uClaimAmount * config.paymentTokenExchangeRate;
        //Convert USDC to ALPS via fund contract
        _exchangeProfitToPayableTokenViaFundContract(uClaimAmount);
        _purchaseServiceCredits(user, netClaimAmountToALPS, ContributionType.RECOMPOUND, debitAmt);
        unchecked{
            contributor.paidAmount += uClaimAmount;
        //reset earning
            contributor.earningAmount -= claimAmount;
        }
    }

    function _migrate() internal {
        address contributorAddress = msg.sender;
        Contributor storage contributor = contributors[contributorAddress];
        if (contributor.migrated) revert AITradeHubAlreadyMigratedError();
        uint256 user_locked_amount;
        uint256 user_pending_amount;
        uint256 user_paid_amount;
        int256 user_earnings;

        _updateUserProfitCheckpoint(contributorAddress);
        //V8 migrate to V9
        IAITradeHubContractV8.PayoutPreference user_payout_type_v8;
        (,
        ,
        ,
        ,
            user_locked_amount,
            user_pending_amount,
            user_paid_amount,
            user_earnings,
        , user_payout_type_v8) = getV8Stats(contributorAddress);
        uint256 migrateAmount = user_locked_amount + user_pending_amount;
        if (migrateAmount > 0) {
            config.aiTradeHubContractV8.transferFrom(address(config.payableERC20), contributorAddress, address(this), migrateAmount);
            _addLockedAmount(contributorAddress, user_locked_amount);
            _addPendingAmount(contributorAddress, user_pending_amount);
        }
        if (user_earnings != 0) {
            unchecked{
                contributor.earningAmount += user_earnings;
            }
            if (user_earnings > 0)
                config.aiTradeHubContractV8.transferFrom(address(config.paymentERC20), contributorAddress, address(this), uint256(user_earnings));
        }
        if (contributor.paidAmount < user_paid_amount) {
            unchecked{
                contributor.paidAmount += user_paid_amount;
            }
        }
        if (user_payout_type_v8 == IAITradeHubContractV8.PayoutPreference.COMPOUND)
            contributor.payoutPreference = PayoutPreference.COMPOUND;
        contributor.migrated = true;
        _insert_address_if_not_existed(contributorAddress);
        emit Migrated(contributorAddress, user_earnings, user_locked_amount, user_paid_amount);
    }

    function _migrateWallet(address owner, address newWallet) internal override {
        _requireMigrateWalletPossible(owner, newWallet);
        Contributor storage from = contributors[owner];
        Contributor storage to = contributors[newWallet];

        // Copy data
        to.pendingAmount = from.pendingAmount;
        to.lockedAmount = from.lockedAmount;
        to.earningAmount = from.earningAmount;
        to.paidAmount = from.paidAmount;
        to.lastFeeCharged = from.lastFeeCharged;
        to.entryProfitPerShare = from.entryProfitPerShare;
        to.payoutPreference = from.payoutPreference;
        to.migrated = from.migrated;
        to.lastWalletMigrate = block.timestamp;

        // Remove old wallet tracking
        from.lastWalletMigrate = block.timestamp;
        from.pendingAmount = 0;
        from.lockedAmount = 0;
        from.earningAmount = 0;
        from.lastFeeCharged = 0;
        from.entryProfitPerShare = stats.profitPerShare;
        from.payoutPreference = PayoutPreference.TRANSFER;

        _insert_address_if_not_existed(newWallet);
        _remove_address(owner);
        emit MigrateWallet(owner, newWallet, to.earningAmount, to.lockedAmount, to.pendingAmount, to.paidAmount, 0);
    }

    function _transferFunds(address owner, address to, uint256 amount) internal override {
        if (to == address(0) || to == owner) {
            revert AITradeHubAddressInvalidError();
        }
        if (!_isVerified(owner) || !_isVerified(to)) {
            revert AITradeHubAccountNotActiveError();
        }
        _updateUserProfitCheckpoint(owner);
        _requireTransferFundsPossible(owner, amount);

        // Prioritize transfer from pending → locked
        _insert_address_if_not_existed(to);
        uint256 remaining = _subPendingAmount(owner, amount);
        _addPendingAmount(to, amount - remaining);
        if (remaining > 0) {
            _subLockedAmount(owner, remaining);
            _addLockedAmount(to, remaining);
        }

        _cleanContributionIfNoFunds(owner);
        emit TransferFunds(owner, to, amount, 0);
    }

    //Transfer feature
    function _approve(address tokenAddress, address owner, address spender, uint256 amount) internal {
        if (owner == address(0) || spender == address(0))
            revert AITradeHubApprovalInvalidAddressError();
        allowances[tokenAddress][owner][spender] = amount;
    }

    function _spendAllowance(address tokenAddress, address owner, address spender, uint256 value) internal {
        uint256 currentAllowance = allowances[tokenAddress][owner][spender];
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < value) {
                revert AITradeHubInsufficientAllowanceError(tokenAddress, spender, currentAllowance, value);
            }
            unchecked{
                _approve(tokenAddress, owner, spender, currentAllowance - value);
            }
        }
    }

    //Transfer funds to external address
    function _transfer(address tokenAddress, address from, address to, uint256 amount) internal override {
        if (from == address(0) || to == address(0)) revert AITradeHubAddressInvalidError();
        if (tokenAddress != address(config.payableERC20) && tokenAddress != address(config.paymentERC20))
            revert AITradeHubAddressInvalidError();

        Contributor storage contributor = contributors[from];
        //Check payable token transfer
        if (tokenAddress == address(config.payableERC20)) {
            _requireWithdrawFundsPossible(from, amount);
            _subFromPendingLocked(from, amount);
        }
        //Check payment token transfer
        if (tokenAddress == address(config.paymentERC20)) {
            _updateUserProfitCheckpoint(from);
            int256 earnings = _getUserEarningsAmount(from);
            if (earnings < int256(amount)) revert AITradeHubInsufficientFundsError();
            unchecked{
                contributor.earningAmount -= int256(amount);
            }
        }

        IERC20 transferToken = IERC20(tokenAddress);
        uint256 fee = 0;
        if (!config.whiteListAddress[to]) {
            //Send fee to fund account
            fee = _get_fee(amount, config.withdrawalFee);
            _sendToFundContract(transferToken, fee, fee);
        }
        transferToken.safeTransfer(to, amount - fee);

        _cleanContributionIfNoFunds(from);
        emit WithdrawFunds(from, to, amount, fee, tokenAddress);
    }

    function _chargeProRatedMonthlyFee(address wallet) internal {
        Contributor storage contributor = contributors[wallet];
        if (contributor.lastFeeCharged == 0) {
            contributor.lastFeeCharged = block.timestamp - 7 days;
        }
        uint256 proratedFee = _getProRatedMonthlyFee(wallet);
        //convert fee to USDC
        proratedFee = proratedFee / config.paymentTokenExchangeRate;
        if (proratedFee == 0) return;

        int256 earning = _getUserEarningsAmount(wallet);
        //Sub from earning
        if (proratedFee > 0 && earning > 0) {
            uint256 chargedAmt = Math.min(proratedFee, uint256(earning));
            contributor.earningAmount -= int256(chargedAmt);
            _sendToFundContract(config.paymentERC20, chargedAmt, chargedAmt);
            emit MonthlyFeeCharged(wallet, _getUserLockedAmount(wallet), address(config.paymentERC20), chargedAmt, proratedFee - chargedAmt);
        }
        // Update charged time
        contributor.lastFeeCharged = block.timestamp;
    }

    function _getMonthlyFeeByDistribution(int256 amount, uint256 totalLockedAmount) internal view returns (uint256) {
        if (amount <= 0 || totalLockedAmount == 0) {
            return 0;
        }
        uint256 defaultMonthlyFee = config.monthlyFee;
        // 1% = 100 bps
        uint256 yieldBps = (uint256(amount) * 100_000) / totalLockedAmount;

        // < 0.50%
        if (yieldBps < 50) return 0;

        // 0.50% - <0.75%
        if (yieldBps < 75) return defaultMonthlyFee / 3;

        // 0.75% - <1.00%
        if (yieldBps < 100) return defaultMonthlyFee / 2;

        // 1.00% - <1.25%
        if (yieldBps < 125) return (defaultMonthlyFee * 2) / 3; // fee / 1.5

        // >= 1.25%
        return config.monthlyFee;
    }


    function _calculateUserEarningByShares(address wallet) internal view returns (int256) {
        Contributor storage user = contributors[wallet];
        uint256 userLockedAmount = _getUserLockedAmount(wallet);
        int256 gross = (int256(userLockedAmount) * stats.profitPerShare) / int256(INTEREST_DECIMAL_PRECISION);
        int256 claimed = (int256(userLockedAmount) * user.entryProfitPerShare) / int256(INTEREST_DECIMAL_PRECISION);
        return gross - claimed;
    }

    function _requireWithdrawFundsPossible(address owner, uint256 amount) internal view override {
        if (amount == 0) revert AITradeHubAmountInvalidError();
        Contributor storage c = contributors[owner];

        uint256 available = c.pendingAmount + c.lockedAmount;
        if (available < amount) revert AITradeHubInsufficientFundsError();
    }

    function _requireTransferFundsPossible(address owner, uint256 amount) internal view override {
        if (amount == 0) revert AITradeHubAmountInvalidError();
        Contributor storage c = contributors[owner];
        uint256 transferable = c.lockedAmount + c.pendingAmount;
        //Check debt amount
        int256 earnings = _getUserEarningsAmount(owner);
        if (earnings < 0) {
            uint256 debtAmount = uint256(- earnings) * config.paymentTokenExchangeRate;
            if (transferable < debtAmount) revert AITradeHubInsufficientFundsError();
            if (transferable - debtAmount < amount) revert AITradeHubInsufficientFundsError();
        }
        if (amount > transferable) revert AITradeHubAmountInvalidError();
    }

    function _requireMigrateWalletPossible(address owner, address newWalletAddress) internal view override {
        Contributor storage from = contributors[owner];
        Contributor storage to = contributors[newWalletAddress];

        if (newWalletAddress == address(0) || newWalletAddress == owner) {
            revert AITradeHubAddressInvalidError();
        }

        if (to.lockedAmount > 0 || to.pendingAmount > 0 || to.earningAmount != 0 || to.entryProfitPerShare > 0) {
            revert AITradeHubWalletMigrateNotEmptyError(); // Target wallet must be empty
        }
        if (msg.sender != config.owner && block.timestamp - from.lastWalletMigrate < 7 days) { // only allow migration once a week
            revert AITradeHubExceedNumberOfTimesError(from.lastWalletMigrate + 7 days);
        }
    }

    function _getProRatedMonthlyFee(address wallet) internal view returns (uint256){
        Contributor memory contributor = contributors[wallet];

        uint256 lastCharged = contributor.lastFeeCharged;
        uint256 nowTimestamp = block.timestamp;

        // First time: skip charging
        if (lastCharged == 0) return 0;

        uint256 elapsed = nowTimestamp - lastCharged;
        uint256 baseFee = _get_fee(_getUserLockedAmount(wallet), stats.currentMonthlyFee);
        uint256 proratedFee = (baseFee * elapsed) / 30 days;
        return proratedFee;
    }

    function _updateUserProfitCheckpoint(address user) internal override {
        Contributor storage contributor = contributors[user];
        int256 currentEarningByShares = _calculateUserEarningByShares(user);
        if (currentEarningByShares == 0) {
            contributor.entryProfitPerShare = stats.profitPerShare;
            return;
        }
        int256 newEarnings = _getUserEarningsAmount(user);
        int256 oldEarnings = newEarnings - currentEarningByShares;

        // User is recovering from debt
        if (currentEarningByShares > 0 && oldEarnings < 0) {
            // only repay up to clearing the deb
            int256 repay = currentEarningByShares;
            if (newEarnings > 0) repay = - oldEarnings;
            if (repay > 0) {
                _sendToFundContract(config.paymentERC20, uint256(repay), 0);
            }
        }

        contributor.earningAmount += currentEarningByShares;
        contributor.entryProfitPerShare = stats.profitPerShare;
    }

    function _addPendingAmount(address wallet, uint256 amount) internal {
        Contributor storage contributor = contributors[wallet];
        unchecked{
            stats.totalPendingAmount += amount;
            contributor.pendingAmount += amount;
        }
    }

    function _subPendingAmount(address wallet, uint256 amount) internal returns (uint256){
        if (amount == 0) return 0;
        Contributor storage contributor = contributors[wallet];
        uint256 amountSubbing = Math.min(amount, contributor.pendingAmount);
        if (amountSubbing == 0) return amount;
        unchecked{
            stats.totalPendingAmount -= amountSubbing;
            contributor.pendingAmount -= amountSubbing;
        }
        return amount - amountSubbing;
    }


    function _subFromPendingLocked(address wallet, uint256 amount) internal returns (uint256){
        if (amount == 0) return 0;
        uint256 remaining = 0;
        // Deduct from pending amount
        remaining = _subPendingAmount(wallet, amount);
        // Deduct from locked amount
        if (remaining > 0)
            remaining = _subLockedAmount(wallet, remaining);

        return remaining;
    }

    function _addLockedAmount(address wallet, uint256 amount) internal {
        Contributor storage contributor = contributors[wallet];
        _updateUserProfitCheckpoint(wallet);
        if (amount == 0) return;
        unchecked{
            contributor.lockedAmount += amount;
            stats.totalLockedAmount += amount;
        }
    }

    function _subLockedAmount(address wallet, uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        Contributor storage contributor = contributors[wallet];

        uint256 amountSubbing = Math.min(amount, contributor.lockedAmount);
        if (amountSubbing == 0)
            return amount;
        _updateUserProfitCheckpoint(wallet);
        unchecked{
            contributor.lockedAmount -= amountSubbing;
            stats.totalLockedAmount -= amountSubbing;
        }
        return amount - amountSubbing;
    }

    function _convertPendingToLocked(address wallet) internal {
        Contributor storage contributor = contributors[wallet];
        uint256 amount = contributor.pendingAmount;
        if (amount == 0) return;
        _addLockedAmount(wallet, amount);
        unchecked{
            contributor.pendingAmount = 0;
            stats.totalPendingAmount -= amount;
        }
    }

    function _getTotalLockedAmount() internal view returns (uint256){
        (
            ,
            ,
            uint256 total_locked_amount,
            ,
            ,
            ,
            ,
            ,
            ,
        ) = getV8Stats(address(this));
        return stats.totalLockedAmount + total_locked_amount;
    }

    function _getUserLockedAmount(address user) internal view returns (uint256){
        Contributor memory contributor = contributors[user];
        uint256 user_locked_amount;
        if (!contributor.migrated)
            (
            ,
            ,
            ,
            ,
                user_locked_amount,
            ,
            ,
            ,
            ,
            ) = getV8Stats(user);

        return contributor.lockedAmount + user_locked_amount;
    }

    function _getUserEarningsAmount(address user) internal view returns (int256){
        int256 user_earnings_without_shares = _getUserEarningsAmountWithoutShare(user);
        return _calculateUserEarningByShares(user) + user_earnings_without_shares;
    }

    function _getUserEarningsAmountWithoutShare(address user) internal view returns (int256){
        Contributor memory contributor = contributors[user];
        int256 user_earnings;
        if (!contributor.migrated)
            (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
                user_earnings,
            ,
            ) = getV8Stats(user);

        return contributor.earningAmount + user_earnings;
    }

    function _getUserPayoutPreference(address user) internal view returns (PayoutPreference){
        Contributor memory contributor = contributors[user];
        if (contributor.migrated) return contributor.payoutPreference;
        IAITradeHubContractV8.PayoutPreference payoutPreferenceV8;
        (
        ,
        ,
        ,
        ,
        ,
        ,
        ,
        ,
        , payoutPreferenceV8
        ) = getV8Stats(user);
        if (payoutPreferenceV8 == IAITradeHubContractV8.PayoutPreference.COMPOUND) return PayoutPreference.COMPOUND;
        return contributor.payoutPreference;
    }

    function _isEnhancedSecurityMode(address user) internal view override returns (bool){
        Contributor memory contributor = contributors[user];
        return contributor.enhancedSecurity;
    }

    function _setEnhancedSecurityMode(address user, bool enable) internal override {
        Contributor storage contributor = contributors[user];
        contributor.enhancedSecurity = enable;
    }

    function _exchangeProfitToPayableTokenViaFundContract(uint256 amount) internal {
        config.paymentERC20.safeTransfer(address(config.fundContract), amount);
        config.fundContract.convert(amount);
    }

    function _sendToFundContract(IERC20 token, uint256 amount, uint256 includedFee) internal {
        if (amount == 0) return;
        token.safeTransfer(address(config.fundContract), amount);
        config.fundContract.onFeeReceived(address(token), amount, includedFee);
    }

    function _withdrawFromFundContract(uint256 amount) internal {
        config.fundContract.withdrawalToken(amount);
    }

    function _cleanContributionIfNoFunds(address wallet) internal {
        Contributor memory contributor = contributors[wallet];
        if (contributor.pendingAmount == 0 && contributor.lockedAmount == 0 && contributor.earningAmount == 0 && _calculateUserEarningByShares(wallet) == 0) {
            _remove_address(wallet);
        }
    }

    function _isVerified(address wallet) internal view override returns (bool){
        return config.swapContract.isInWhiteList(wallet);
    }

    function _isOwner() internal view override returns (bool){
        return msg.sender == config.owner;
    }

    function _setPayoutPreference(address wallet, PayoutPreference payoutPreference) internal {
        if (contributors[wallet].payoutPreference == payoutPreference) return;
        contributors[wallet].payoutPreference = payoutPreference;
    }

    function _get_fee(uint256 amount, uint256 rate) internal pure returns (uint256) {
        return (amount * rate) / FEE_DENOMINATOR;
    }

    function _insert_address_if_not_existed(address new_address) internal {
        // if addr is not already list
        if (stats.addressIndexes[new_address] == 0) {
            stats.addressIndexes[new_address] = stats.contributorAddresses.length + 1;
            stats.contributorAddresses.push(new_address);
        }
    }

    function _remove_address(address wallet) internal {
        uint256 indexPlusOne = stats.addressIndexes[wallet];
        if (indexPlusOne == 0) return; // Address not found

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = stats.contributorAddresses.length - 1;

        if (index != lastIndex) {
            // Swap with last element
            address lastAddress = stats.contributorAddresses[lastIndex];
            stats.contributorAddresses[index] = lastAddress;
            stats.addressIndexes[lastAddress] = index + 1;
        }
        // Remove last element and clear index
        stats.contributorAddresses.pop();
        delete stats.addressIndexes[wallet];
    }

    //====END=====
}