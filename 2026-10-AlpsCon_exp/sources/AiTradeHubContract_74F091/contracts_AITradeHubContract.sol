//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IERC20} from "./interfaces/IERC20.sol";
import {ISwapContract} from "./interfaces/ISwapContract.sol";
import {Math} from "./math/Math.sol";
import {SafeERC20} from "./math/SafeERC20.sol";
import {console} from "hardhat/console.sol";
import {IAITradeHubContractV4} from "./interfaces/IAITradeHubContractV4.sol";
import {IAITradeHubContractV5} from "./interfaces/IAITradeHubContractV5.sol";

/**
 * @title AI Trading Service Access Contract
 * @notice Manages TRAI utility tokens for AI trading service access
 * @dev IMPORTANT: This is NOT an investment contract.
 * - TRAI tokens are service credits for AI trading services
 * - Users pay for AI-powered trading services, not making investments
 * - AlpsCon trades with OWN capital, not user funds
 * - Distributions are service results from AI performance
 * - This is a technology service, not a financial product
 */
contract AiTradeHubContract {
    using SafeERC20 for IERC20;

    //Enum
    enum ContributionType{
        NORMAL, RECOMPOUND, MIGRATE
    }
    enum PayoutPreference{
        TRANSFER, COMPOUND
    }
    //========
    //EVENTS
    //============================
    event Contribute(address indexed contributor, uint256 amount, uint256 fee, uint256 lockedAmt, ContributionType contributionType);
    event NextTarget();
    event Indexed(address wallet, uint256 amountLocked, uint256 amountPending);
    event ClaimServiceResults(address indexed contributor, address paymentToken, uint256 lockedAmt, uint256 amount, uint256 withdrawalFee);
    event WithdrawFunds(address indexed contributor, address to, uint256 amount, uint256 fee, address token);
    event ServiceResultsDistributed(int256 amount);
    event MonthlyFeeCharged(address indexed contributor, uint256 lockedAmt, address token, uint256 fee, uint256 debtAdded);
    event Migrated(address indexed wallet, uint256 balance, uint256 lockedAmt, uint256 paidAmt);
    event MigrateWallet(address indexed oldWallet, address indexed newWallet, int256 earnings, uint256 lockedAmt, uint256 pendingAmt, uint256 paidAmt, uint256 fee);
    event TransferFunds(address indexed from, address indexed to, uint256 amount, uint256 fee);
    event ServiceResultLosses(address indexed wallet, int256 amount, uint256 lockedAmt);
    //============================

    struct Contributor {
        int256 earningAmount; // Service result
        uint256 lockedAmount; // Active service credits
        uint256 pendingAmount; // Queued service credits
        uint256 paidAmount; //Total service results received
        int256 entryProfitPerShare;
        uint256 lastFeeCharged;
        PayoutPreference payoutPreference; // distribution type
        uint256 lastWalletMigrate; //last wallet migrate time
        bool isCreditsMigrated;
    }

    struct ContractConfig {
        address owner;
        address fundAccount;
        address automationForwarder;
        ISwapContract swapContract;
        IAITradeHubContractV4 aiTradeHubContractV4;
        IAITradeHubContractV5 aiTradeHubContractV5;
        IERC20 payableERC20; // use for contributors contribute
        IERC20 paymentERC20; // use for payout to contributors
        uint256 withdrawalFee;
        uint256 contributionFee;
        uint256 monthlyFee;
        uint256 paymentTokenExchangeRate; //10 mean 10 TRAI = 1 USDT
        mapping(address => bool) feeExceptAddresses;

    }

    struct ContractStats {
        address[] contributorAddresses;
        mapping(address => uint256) addressIndexes;
        int256 profitPerShare;
        uint256 totalLockedAmount;
        uint256 totalPendingAmount;
        uint256 lastDistributeProfit;
        uint256 lastAutoPerformIndex;
    }


    uint256 private constant  INTEREST_DECIMAL_PRECISION = 1e10;
    uint256 private constant FEE_DENOMINATOR = 1000;
    //Error
    error AITradeHubPermissionDeniedError();
    error AITradeHubNotVerifyError();
    error AITradeHubTransferFundAccountNotActiveError();
    error AITradeHubTransferLockedError();
    error AITradeHubAmountInvalidError();
    error AITradeHubNoProfitToClaimError();
    error AITradeHubAlreadyMigratedError();
    error AITradeHubWalletMigrateNotEmptyError();
    error AITradeHubWalletMigrateExceedNumberOfTimesError(uint256 nextTime);
    error AITradeHubPoolNotReadyError();
    error AITradeHubAddressInvalidError();
    error AITradeHubTokenAddressInvalidError();
    error AITradeHubDataInvalidError();
    error AITradeHubApprovalInvalidAddressError();
    error AITradeHubInsufficientAllowanceError(address tokenAddress, address spender, uint256 allowance, uint256 needed);
    error AITradeHubInsufficientFundsError();
    modifier onlyOwner() {
        if (!_isOwner()) revert AITradeHubPermissionDeniedError();
        _;
    }
    modifier onlyVerified() {
        if (!_isVerified(msg.sender)) revert AITradeHubNotVerifyError();
        _;
    }

    ContractConfig private config;
    ContractStats private stats;
    mapping(address => Contributor) private contributors;
    // Structure: tokenAddress => owner => spender => amount
    mapping(address => mapping(address => mapping(address => uint256))) private allowances;
    uint private version = 6;

    struct InitConfig {
        address payableERC20;
        address paymentERC20;
        address fundAccount;
        address swapContract;
        address aiTradeHubContractV4;
        address aiTradeHubContractV5;
        uint256 withdrawal_fee;
        uint256 contribution_fee;
        uint256 monthly_fee;
        uint256 payment_token_exchange_rate;
    }
    constructor(InitConfig memory cfg) {
        config.owner = msg.sender;
        config.automationForwarder = msg.sender;
        config.payableERC20 = IERC20(cfg.payableERC20);
        config.paymentERC20 = IERC20(cfg.paymentERC20);
        config.fundAccount = cfg.fundAccount;
        config.swapContract = ISwapContract(cfg.swapContract);
        config.aiTradeHubContractV4 = IAITradeHubContractV4(cfg.aiTradeHubContractV4);
        config.aiTradeHubContractV5 = IAITradeHubContractV5(cfg.aiTradeHubContractV5);
        config.withdrawalFee = cfg.withdrawal_fee;
        config.contributionFee = cfg.contribution_fee;
        config.monthlyFee = cfg.monthly_fee;
        config.paymentTokenExchangeRate = cfg.payment_token_exchange_rate;
    }

    //OWNER function
    function distributeServiceResults(int256 amount) external onlyOwner {
        return _distributeServiceResults(amount);
    }

    function migrateCredits(address wallet) external onlyOwner {
        _migrateCredits(wallet);
    }

    function setSwapContract(address swapContract) external onlyOwner {
        config.swapContract = ISwapContract(swapContract);
    }

    function setAutomationForwarder(address forwarder) external onlyOwner {
        config.automationForwarder = forwarder;
    }

    function chargeMonthlyFee(address wallet) external onlyOwner {
        _chargeProRatedMonthlyFee(wallet);
    }

    function setAddressFeeExempt(address wallet, bool exempt) external onlyOwner {
        config.feeExceptAddresses[wallet] = exempt;
    }

    //====END=====
    //automation function
    function performAutomation(uint256 batchSize) external returns (uint256){
        if (msg.sender != config.automationForwarder) revert AITradeHubPermissionDeniedError();

        uint256 total = stats.contributorAddresses.length;
        uint256 startIndex = stats.lastAutoPerformIndex;
        if (startIndex >= total) {
            stats.lastAutoPerformIndex = 0;
            return 0;
        }
        uint256 endIndex = startIndex + batchSize;
        if (endIndex > total) endIndex = total;

        for (uint256 i = startIndex; i < endIndex; i++) {
            address wallet = stats.contributorAddresses[i];
            Contributor storage contributor = contributors[wallet];
            int256 currentProfit = _calculateUserProfit(wallet);
            int256 earnings = contributor.earningAmount + currentProfit;
            if (earnings > 0) {
                if (contributor.payoutPreference == PayoutPreference.COMPOUND) {
                    _recompound(wallet);
                } else if (contributor.payoutPreference == PayoutPreference.TRANSFER) {
                    _claimServiceResults(wallet);
                }
            } else if (earnings < 0) {
                _updateUserProfitCheckpoint(wallet);
                emit ServiceResultLosses(wallet, currentProfit, contributor.lockedAmount);
                //reset monthly fee
                contributor.lastFeeCharged = block.timestamp;
            }
            _convertPendingToLocked(wallet);
        }
        if (endIndex == total) {
            // finished full cycle
            stats.lastAutoPerformIndex = 0;
        } else {
            stats.lastAutoPerformIndex = endIndex;
        }
        return stats.lastAutoPerformIndex;
    }

    //======END=========

    //PUBLIC function
    function purchaseServiceCredits(uint256 amount) external onlyVerified {
        return _purchaseServiceCredits(msg.sender, amount, ContributionType.NORMAL);
    }

    function claimServiceResults() external onlyVerified {
        return _claimServiceResults(msg.sender);
    }

    function recompound() external onlyVerified {
        return _recompound(msg.sender);
    }

    function migrate() external onlyVerified {
        _migrate();
    }

    function migrateWallet(address newWallet) external onlyVerified {
        _migrateWallet(newWallet);
    }

    function transferFunds(address to, uint256 amount) external onlyVerified {
        _transferFunds(to, amount);
    }

    function withdrawFunds(uint256 amount) external onlyVerified {
        return _withdrawFunds(msg.sender, amount);
    }

    function transfer(address tokenAddress, address to, uint256 amount) external onlyVerified {
        _transfer(tokenAddress, msg.sender, to, amount);
    }

    function transferFrom(address tokenAddress, address from, address to, uint256 amount) external onlyVerified {
        address spender = msg.sender;
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


    function getStats(address wallet) external view returns (
        uint num_contributors,
        uint256 total_pending_amount,
        uint256 total_locked_amount,
        uint256 last_distribute_profit,
        uint256 user_locked_amount,
        uint256 user_pending_amount,
        uint256 user_paid_amount,
        int256 user_earnings,
        uint256 user_current_service_fee,
        PayoutPreference user_payout_type
    ){
        num_contributors = stats.contributorAddresses.length;
        total_locked_amount = stats.totalLockedAmount;
        total_pending_amount = stats.totalPendingAmount;
        last_distribute_profit = stats.lastDistributeProfit;
        Contributor memory contributor = contributors[wallet];
        user_locked_amount = contributor.lockedAmount;
        user_pending_amount = contributor.pendingAmount;
        user_paid_amount = contributor.paidAmount;
        user_earnings = _calculateUserProfit(wallet) + contributor.earningAmount;
        user_current_service_fee = _getProRatedMonthlyFee(wallet);
        user_payout_type = contributor.payoutPreference;
    }

    function getV4Stats(address wallet) public view returns (
        uint num_contributors,
        uint256 total_pending_amount,
        uint256 total_locked_amount,
        uint256 last_distribute_profit,
        uint256 user_locked_amount,
        uint256 user_pending_amount,
        uint256 user_paid_amount,
        uint256 user_balance,
        uint256 user_claimable_profit,
        uint256 user_current_service_fee,
        IAITradeHubContractV4.PayoutPreference user_payout_type
    ){
        return config.aiTradeHubContractV4.getStats(wallet);
    }

    function getV5Stats(address wallet) public view returns (
        uint num_contributors,
        uint256 total_pending_amount,
        uint256 total_locked_amount,
        uint256 last_distribute_profit,
        uint256 user_locked_amount,
        uint256 user_pending_amount,
        uint256 user_paid_amount,
        uint256 user_balance,
        uint256 user_claimable_profit,
        uint256 user_current_service_fee,
        IAITradeHubContractV5.PayoutPreference user_payout_type
    ){
        return config.aiTradeHubContractV5.getStats(wallet);
    }

    function getConfig() external view
    returns (
        address owner,
        address paymentERC20,
        address payableERC20,
        uint256 contribution_fee,
        uint256 withdrawal_fee,
        uint256 monthly_fee
    )
    {
        owner = config.owner;
        paymentERC20 = address(config.paymentERC20);
        payableERC20 = address(config.payableERC20);
        contribution_fee = config.contributionFee;
        withdrawal_fee = config.withdrawalFee;
        monthly_fee = config.monthlyFee;
    }

    function getVersion() external view returns (uint){
        return version;
    }
    //====END=====

    //INTERNAL function
    function _purchaseServiceCredits(address wallet, uint256 amount, ContributionType contributionType) internal {
        uint256 contributionFee = 0;
        uint256 contributionAmount = amount;
        if (contributionType == ContributionType.NORMAL) {
            if (amount == 0) revert AITradeHubAmountInvalidError();
            contributionFee = _get_fee_contribution(amount);
            unchecked{
                contributionAmount -= contributionFee;
            }
            //Transfer fee to fund wallet
            config.payableERC20.safeTransferFrom(wallet, config.fundAccount, contributionFee);
            //Transfer amount to contract
            config.payableERC20.safeTransferFrom(wallet, address(this), contributionAmount);
        } else if (contributionType == ContributionType.RECOMPOUND) {
            contributionFee = _get_fee_contribution(amount) / 2;
            unchecked{
                contributionAmount -= contributionFee;
            }
            //Transfer fee to fund wallet
            _sendToFundAccount(config.payableERC20, contributionFee);
        }
        _insert_address_if_not_existed(wallet);
        Contributor storage contributor = contributors[wallet];
        //Add pending amount
        _addPendingAmount(wallet, contributionAmount);
        emit Contribute(wallet, contributionAmount, contributionFee, contributor.lockedAmount, contributionType);
    }

    function _distributeServiceResults(int256 amount) internal {
        if (stats.totalLockedAmount == 0) revert AITradeHubPoolNotReadyError();
        int256 delta = (amount * int256(INTEREST_DECIMAL_PRECISION)) / int256(stats.totalLockedAmount);
        stats.profitPerShare += delta;
        stats.lastDistributeProfit = block.timestamp;
        if (amount > 0) {
            _sendFromFundAccount(config.paymentERC20, address(this), uint256(amount));
        }
        emit ServiceResultsDistributed(amount);
    }

    function _claimServiceResults(address wallet) internal {
        Contributor storage contributor = contributors[wallet];
        bool automation = (msg.sender == config.automationForwarder);

        _updateUserProfitCheckpoint(wallet);
        // Charge accurate monthly fee by time elapsed
        _chargeProRatedMonthlyFee(wallet);
        int256 claimAmount = contributor.earningAmount;
        if (claimAmount <= 0) {
            if (!automation) revert AITradeHubNoProfitToClaimError();
            else return;
        }

        uint256 uClaimAmount = uint256(claimAmount);
        uint256 withdrawalFee = _get_fee_withdrawal(uClaimAmount);
        uint256 netClaimAmount = uClaimAmount - withdrawalFee;

        if (netClaimAmount > 0) {
            config.paymentERC20.safeTransfer(wallet, netClaimAmount);
            contributor.paidAmount += netClaimAmount;
            //transfer fee to fund account
            _sendToFundAccount(config.paymentERC20, withdrawalFee);
        }

        //reset balance
        contributor.earningAmount = 0;
        emit ClaimServiceResults(wallet, address(config.paymentERC20), contributor.lockedAmount, netClaimAmount, withdrawalFee);
    }

    function _recompound(address wallet) internal {
        Contributor storage contributor = contributors[wallet];
        bool automation = (msg.sender == config.automationForwarder);

        _updateUserProfitCheckpoint(wallet);
        // Charge accurate monthly fee by time elapsed
        _chargeProRatedMonthlyFee(wallet);
        int256 claimAmount = contributor.earningAmount;
        if (claimAmount <= 0) {
            if (!automation) revert AITradeHubNoProfitToClaimError();
            else return;
        }
        uint256 uClaimAmount = uint256(claimAmount);
        uint256 netClaimAmountToTRAI = uClaimAmount * config.paymentTokenExchangeRate;
        //Swap USDC to TRAI via fund wallet
        _sendToFundAccount(config.paymentERC20, uClaimAmount);
        _sendFromFundAccount(config.payableERC20, address(this), netClaimAmountToTRAI);
        _purchaseServiceCredits(wallet, netClaimAmountToTRAI, ContributionType.RECOMPOUND);
        //reset balance
        contributor.earningAmount = 0;
        unchecked{
            contributor.paidAmount += uClaimAmount;
        }
    }

    function _withdrawFunds(address wallet, uint256 amount) internal {
        if (amount == 0) revert AITradeHubAmountInvalidError();
        Contributor storage contributor = contributors[wallet];
        _updateUserProfitCheckpoint(wallet);
        //Check debt amount
        if (contributor.earningAmount < 0) {
            uint256 available = contributor.lockedAmount + contributor.pendingAmount;
            uint256 debtAmount = uint256(- contributor.earningAmount) * config.paymentTokenExchangeRate;
            if (available < debtAmount) revert AITradeHubInsufficientFundsError();
            if (available - debtAmount < amount) revert AITradeHubInsufficientFundsError();
        }
        _transfer(address(config.payableERC20), wallet, wallet, amount);
    }

    function _migrate() internal {
        address contributorAddress = msg.sender;
        Contributor storage contributor = contributors[contributorAddress];
        uint256 user_paid_amount;
        uint256 user_balance;
        uint256 user_claimable_profit;

        //Migrate credits v4 + v5 -> v6
        _migrateCredits(contributorAddress);
        //V4 migrate to V6
        IAITradeHubContractV4.PayoutPreference user_payout_type;
        (,
        ,
        ,
        ,
        ,
        ,
            user_paid_amount,
            user_balance,
            user_claimable_profit,
        ,
            user_payout_type) = getV4Stats(contributorAddress);

        //Migrate USDC balance
        uint256 balance = user_balance + user_claimable_profit;
        if (balance > 0) {
            config.aiTradeHubContractV4.transferFrom(address(config.paymentERC20), contributorAddress, address(this), balance);
            unchecked{
                contributor.earningAmount += int256(balance);
            }
        }
        if (contributor.paidAmount < user_paid_amount)
            contributor.paidAmount += user_paid_amount;
        if (user_payout_type == IAITradeHubContractV4.PayoutPreference.COMPOUND)
            contributor.payoutPreference = PayoutPreference.COMPOUND;

        //V5 migrate to V6
        IAITradeHubContractV5.PayoutPreference user_payout_type_v5;
        (,
        ,
        ,
        ,
        ,
        ,
            user_paid_amount,
            user_balance,
            user_claimable_profit,
        ,
            user_payout_type_v5) = getV5Stats(contributorAddress);
        unchecked{
            balance = user_balance + user_claimable_profit;
        }
        if (balance > 0) {
            config.aiTradeHubContractV5.transferFrom(address(config.paymentERC20), contributorAddress, address(this), balance);
            unchecked{
                contributor.earningAmount += int256(balance);
            }
        }
        if (contributor.paidAmount < user_paid_amount) {
            unchecked{
                contributor.paidAmount += user_paid_amount;
            }
        }
        if (user_payout_type_v5 == IAITradeHubContractV5.PayoutPreference.COMPOUND)
            contributor.payoutPreference = PayoutPreference.COMPOUND;

        if (contributor.earningAmount > 0) {
            if (contributor.payoutPreference == PayoutPreference.COMPOUND) {
                _recompound(contributorAddress);
            } else {
                _claimServiceResults(contributorAddress);
            }
        }
        _convertPendingToLocked(contributorAddress);
        emit Migrated(contributorAddress, balance, contributor.lockedAmount, user_paid_amount);
    }

    function _migrateCredits(address wallet) internal {
        Contributor storage contributor = contributors[wallet];

        if (!contributor.isCreditsMigrated) {
            uint256 user_locked_amount;
            uint256 user_pending_amount;
            (,
            ,
            ,
            ,
                user_locked_amount,
                user_pending_amount,
            ,
            ,
            ,
            ,
            ) = getV4Stats(wallet);
            uint256 totalMigrateCredits = user_locked_amount + user_pending_amount;

            (,
            ,
            ,
            ,
                user_locked_amount,
                user_pending_amount,
            ,
            ,
            ,
            ,
            ) = getV5Stats(wallet);
            unchecked{
                totalMigrateCredits += (user_locked_amount + user_pending_amount);
            }
            if (totalMigrateCredits > 0) {
                _purchaseServiceCredits(wallet, totalMigrateCredits, ContributionType.MIGRATE);
                _sendFromFundAccount(config.payableERC20, address(this), totalMigrateCredits);
            }
            contributor.isCreditsMigrated = true;
            _convertPendingToLocked(wallet);
        }

    }

    function _migrateWallet(address newWallet) internal {
        address oldWallet = msg.sender;
        Contributor storage from = contributors[oldWallet];
        Contributor storage to = contributors[newWallet];

        if (newWallet == address(0) || newWallet == oldWallet) {
            revert AITradeHubAddressInvalidError();
        }

        if (to.lockedAmount > 0 || to.pendingAmount > 0 || to.earningAmount != 0 || to.entryProfitPerShare > 0) {
            revert AITradeHubWalletMigrateNotEmptyError(); // Target wallet must be empty
        }
        if (block.timestamp - from.lastWalletMigrate < 604800) { // only allow migration once a week
            revert AITradeHubWalletMigrateExceedNumberOfTimesError(from.lastWalletMigrate + 604800);
        }

        // Copy data
        to.pendingAmount = from.pendingAmount;
        to.lockedAmount = from.lockedAmount;
        to.earningAmount = from.earningAmount;
        to.paidAmount = from.paidAmount;
        to.lastFeeCharged = from.lastFeeCharged;
        to.entryProfitPerShare = from.entryProfitPerShare;
        to.payoutPreference = from.payoutPreference;
        to.isCreditsMigrated = from.isCreditsMigrated;
        to.lastWalletMigrate = block.timestamp;

        // Remove old wallet tracking
        from.pendingAmount = 0;
        from.lockedAmount = 0;
        from.earningAmount = 0;
        from.lastFeeCharged = 0;
        from.entryProfitPerShare = stats.profitPerShare;
        from.payoutPreference = PayoutPreference.TRANSFER;

        _insert_address_if_not_existed(newWallet);
        _remove_address(oldWallet);
        emit MigrateWallet(oldWallet, newWallet, to.earningAmount, to.lockedAmount, to.pendingAmount, to.paidAmount, 0);
    }

    function _transferFunds(address to, uint256 amount) internal {
        address from = msg.sender;
        if (to == address(0) || to == from) {
            revert AITradeHubAddressInvalidError();
        }
        if (!_isVerified(msg.sender) || !_isVerified(to)) {
            revert AITradeHubTransferFundAccountNotActiveError();
        }
        Contributor storage sender = contributors[from];
        _updateUserProfitCheckpoint(from);
        uint256 transferable = sender.lockedAmount + sender.pendingAmount;
        //Check debt amount
        if (sender.earningAmount < 0) {
            uint256 debtAmount = uint256(- sender.earningAmount) * config.paymentTokenExchangeRate;
            if (transferable < debtAmount) revert AITradeHubInsufficientFundsError();
            if (transferable - debtAmount < amount) revert AITradeHubInsufficientFundsError();
        }

        if (amount == 0 || amount > transferable) {
            revert AITradeHubAmountInvalidError();
        }

        // Prioritize transfer from pending → locked
        _insert_address_if_not_existed(to);
        uint256 remaining = _subPendingAmount(from, amount);
        _addPendingAmount(to, amount - remaining);
        if (remaining > 0) {
            _subLockedAmount(from, remaining);
            _addLockedAmount(to, remaining);
        }

        _cleanContributionIfNoFunds(from);
        emit TransferFunds(from, to, amount, 0);
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
    function _transfer(address tokenAddress, address from, address to, uint256 amount) internal {
        if (from == address(0) || to == address(0)) revert AITradeHubAddressInvalidError();
        if (tokenAddress != address(config.payableERC20) && tokenAddress != address(config.paymentERC20))
            revert AITradeHubTokenAddressInvalidError();

        Contributor storage contributor = contributors[from];
        //Check payable token transfer
        if (tokenAddress == address(config.payableERC20)) {
            uint256 maxTransferAmt = contributor.pendingAmount + contributor.lockedAmount;
            if (maxTransferAmt < amount) revert AITradeHubInsufficientFundsError();
            _subFromPendingLocked(from, amount);
        }
        //Check payment token transfer
        if (tokenAddress == address(config.paymentERC20)) {
            _updateUserProfitCheckpoint(from);
            if (contributor.earningAmount < int256(amount)) revert AITradeHubInsufficientFundsError();
            unchecked{
                contributor.earningAmount -= int256(amount);
            }
        }

        IERC20 transferToken = IERC20(tokenAddress);
        uint256 fee = 0;
        if (!config.feeExceptAddresses[to]) {
            //Send fee to fund account
            fee = _get_fee_withdrawal(amount);
            _sendToFundAccount(transferToken, fee);
        }
        transferToken.transfer(to, amount - fee);

        _cleanContributionIfNoFunds(from);
        emit WithdrawFunds(from, to, amount, fee, tokenAddress);
    }

    function _chargeProRatedMonthlyFee(address wallet) internal {
        Contributor storage contributor = contributors[wallet];
        uint256 proratedFee = _getProRatedMonthlyFee(wallet);
        if (contributor.lastFeeCharged == 0) contributor.lastFeeCharged = block.timestamp;
        if (proratedFee == 0) return;

        uint256 remaining = proratedFee;
        uint256 chargedAmt = 0;
        //Sub from pending amount
        if (contributor.pendingAmount > 0) {
            remaining = _subPendingAmount(wallet, proratedFee);
            chargedAmt = proratedFee - remaining;
            _sendToFundAccount(config.payableERC20, chargedAmt);
            emit MonthlyFeeCharged(wallet, contributor.lockedAmount, address(config.payableERC20), chargedAmt, remaining);
        }
        //Sub from balance
        if (remaining > 0 && contributor.earningAmount > 0) {
            uint256 balance = uint256(contributor.earningAmount);
            uint256 balanceToTRAI = balance * config.paymentTokenExchangeRate;
            if (balanceToTRAI > 0) {
                chargedAmt = Math.min(remaining, balanceToTRAI);
                remaining = remaining - chargedAmt;
                balanceToTRAI = balanceToTRAI - chargedAmt;
                contributor.earningAmount = int256(balanceToTRAI / config.paymentTokenExchangeRate);
                //convert fee back to USDC
                chargedAmt = balance - uint256(contributor.earningAmount);
                _sendToFundAccount(config.paymentERC20, chargedAmt);
                emit MonthlyFeeCharged(wallet, contributor.lockedAmount, address(config.paymentERC20), chargedAmt, remaining);
            }
        }
        // Update charged time
        contributor.lastFeeCharged = block.timestamp;
    }

    function _calculateUserProfit(address wallet) internal view returns (int256) {
        Contributor storage user = contributors[wallet];
        int256 gross = (int256(user.lockedAmount) * stats.profitPerShare) / int256(INTEREST_DECIMAL_PRECISION);
        int256 claimed = (int256(user.lockedAmount) * user.entryProfitPerShare) / int256(INTEREST_DECIMAL_PRECISION);
        return gross - claimed;
    }

    function _getProRatedMonthlyFee(address wallet) internal view returns (uint256){
        Contributor memory contributor = contributors[wallet];

        uint256 lastCharged = contributor.lastFeeCharged;
        uint256 nowTimestamp = block.timestamp;

        // First time: set lastFeeCharged but skip charging
        if (lastCharged == 0) {
            return 0;
        }

        uint256 elapsed = nowTimestamp - lastCharged;
        uint256 baseFee = _get_fee_monthly(contributor.lockedAmount);
        uint256 proratedFee = (baseFee * elapsed) / 2592000; //30 days in seconds
        return proratedFee;
    }

    function _updateUserProfitCheckpoint(address wallet) internal {
        Contributor storage contributor = contributors[wallet];
        int256 profit = _calculateUserProfit(wallet);
        unchecked{
            contributor.earningAmount += profit;
        }
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
        if (amount == 0) return;
        _updateUserProfitCheckpoint(wallet);
        Contributor storage contributor = contributors[wallet];
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
        _updateUserProfitCheckpoint(wallet);
        unchecked{
            contributor.lockedAmount += amount;
            stats.totalLockedAmount += amount;
            contributor.pendingAmount = 0;
            stats.totalPendingAmount -= amount;
        }
    }

    function _sendToFundAccount(IERC20 token, uint256 amount) internal {
        token.safeTransfer(config.fundAccount, amount);
    }

    function _sendFromFundAccount(IERC20 token, address to, uint256 amount) internal {
        token.safeTransferFrom(config.fundAccount, to, amount);
    }

    function _cleanContributionIfNoFunds(address wallet) internal {
        Contributor memory contributor = contributors[wallet];
        if (contributor.pendingAmount == 0 && contributor.lockedAmount == 0 && contributor.earningAmount == 0 && _calculateUserProfit(wallet) == 0) {
            _remove_address(wallet);
        }
    }

    function _isVerified(address wallet) internal view returns (bool){
        return config.swapContract.isInWhiteList(wallet);
    }

    function _isOwner() internal view returns (bool){
        return msg.sender == config.owner;
    }

    function _setPayoutPreference(address wallet, PayoutPreference payoutPreference) internal {
        if (contributors[wallet].payoutPreference == payoutPreference) return;
        contributors[wallet].payoutPreference = payoutPreference;
    }

    function _get_fee_contribution(uint256 currency_balance) internal view returns (uint256) {
        return (currency_balance * config.contributionFee) / FEE_DENOMINATOR;
    }

    function _get_fee_withdrawal(uint256 amount) internal view returns (uint256) {
        return (amount * config.withdrawalFee) / FEE_DENOMINATOR;
    }

    function _get_fee_monthly(uint256 amount) internal view returns (uint256) {
        return (amount * config.monthlyFee) / FEE_DENOMINATOR;
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