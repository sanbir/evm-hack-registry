// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title IERC20Minimal
 * @notice Minimal interface for USDT interactions
 */
interface IERC20Minimal {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    function transfer(address recipient, uint256 amount) external returns (bool);

    function balanceOf(address account) external view returns (uint256);

    function allowance(address owner, address spender) external view returns (uint256);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function sync() external;
}

contract CrowdRingCircle is
    ERC20,
    ERC20Burnable,
    ERC20Permit,
    Ownable2Step,
    Pausable,
    ReentrancyGuard
{

    /// @notice Total supply: 100,000,000 CRC with 18 decimals
    uint256 public constant TOTAL_SUPPLY = 100_000_000 * 1e18;

    /// @notice BSC Mainnet USDT (BEP-20) contract address
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    /// @notice Treasury address that receives USDT recharges
    address public treasury;

    /// @notice Addresses recognized as DEX liquidity pairs (buy is blocked from these)
    mapping(address => bool) public isDexPair;

    /// @notice Addresses exempt from buy/sell restrictions (owner, router, etc.)
    mapping(address => bool) public isExemptFromRestriction;

    /// @notice Master switch for buy restriction enforcement
    bool public buyRestrictionEnabled = true;

    /// @notice Minimum USDT recharge amount (anti-dust)
    uint256 public minRechargeAmount = 1 * 1e18; // 1 USDT

    /// @notice Maximum USDT recharge amount per transaction
    uint256 public maxRechargeAmount = 1_000_000 * 1e18; // 1,000,000 USDT

    /// @notice Tracks total USDT recharged per user
    mapping(address => uint256) public userRechargeTotal;

    /// @notice Global total USDT recharged
    uint256 public totalRecharged;

    /// @notice Minimum CRC balance a non-exempt holder must retain after any outgoing transfer
    uint256 public minHoldAmount = 0; // 1 CRC

    /// @notice Blacklisted addresses (cannot send or receive CRC)
    mapping(address => bool) public isBlacklisted;

    // 卖出销毁总开关
    bool public sellDestroyEnabled = true;

    // 卖出费率：1000 = 10%（基数 10000）
    uint256 public sellFeeRate;

    // 手续费接收地址
    address public feeReceiver;

    event DexPairUpdated(address indexed pair, bool status);
    event ExemptionUpdated(address indexed account, bool status);
    event BuyRestrictionToggled(bool enabled);
    event USDTRecharged(address indexed user, uint256 amount, uint256 timestamp);
    event RechargeAmountLimitsUpdated(uint256 newMin, uint256 newMax);
    event BlacklistUpdated(address indexed account, bool status);
    event EmergencyTokenRecovered(address indexed token, address indexed to, uint256 amount);
    event MinHoldAmountUpdated(uint256 newAmount);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event UserRechargeTotalUpdated(address indexed user, uint256 oldAmount, uint256 newAmount);
    event BurnFromPair(uint256 indexed burnAmount, uint256 pairBalanceBefore, uint256 pairBalanceAfter, string burnType);
    event SafeDeductApplied(address account, uint256 requested, uint256 actual);
    event sellDestroyToggled(bool enabled);
    event SellFeeRateUpdated(uint256 oldRate, uint256 newRate);
    event FeeReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);

    error BuyRestricted();
    error ZeroAddress();
    error Blacklisted(address account);
    error RechargeBelowMinimum(uint256 amount, uint256 minimum);
    error RechargeAboveMaximum(uint256 amount, uint256 maximum);
    error InvalidLimits();
    error TransferFailed();
    error CannotRecoverCRC();
    error InsufficientRetainedBalance(uint256 postBalance, uint256 minRequired);
    error FeeTooHigh();

    /**
     * @param initialOwner Address that receives total supply and becomes contract owner
     * @param initialOwner Initial treasury address that receives USDT recharges
     */
    constructor(address initialOwner)
    ERC20(unicode"众环CRC", unicode"众环CRC")
    ERC20Permit(unicode"众环CRC")
    Ownable(initialOwner)
    {
        if (initialOwner == address(0)) revert ZeroAddress();
        
        // Mint entire supply to initial owner
        _mint(initialOwner, TOTAL_SUPPLY);

        // Set initial treasury address
        treasury = initialOwner; 

        // Owner is exempt from restrictions by default
        isExemptFromRestriction[initialOwner] = true;

        sellFeeRate = 1000;          // 10%
        feeReceiver = initialOwner;

        emit ExemptionUpdated(initialOwner, true);
        emit TreasuryUpdated(address(0), initialOwner);
    }

    /**
     * @dev Override _update to enforce:
     *  1. Blacklist check
     *  2. Buy restriction (block transfers FROM DEX pairs to non-exempt addresses)
     *  3. Minimum hold requirement (non-exempt senders must retain minHoldAmount)
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        // --- Blacklist Check ---
        if (isBlacklisted[from]) revert Blacklisted(from);
        if (isBlacklisted[to]) revert Blacklisted(to);

        // --- Buy Restriction ---
        if (
            buyRestrictionEnabled &&
            isDexPair[from] &&
            !isExemptFromRestriction[to] &&
            from != address(0)
        ) {
            revert BuyRestricted();
        }

        // For actual transfers (not mint/burn), apply new rules
        if (from != address(0) && to != address(0)) {
            // --- Rule 1: Minimum Hold Requirement ---
            // Non-exempt senders must keep at least minHoldAmount after transfer
            if (!isExemptFromRestriction[from] && minHoldAmount > 0) {
                uint256 senderBalance = balanceOf(from);
                if (senderBalance - amount < minHoldAmount) {
                    revert InsufficientRetainedBalance(senderBalance - amount, minHoldAmount);
                }
            }
        }

        if (isDexPair[to] && sellFeeRate > 0 && !isExemptFromRestriction[from]) {
            // 计算手续费（sellFeeRate / 10000）
            uint256 fee = (amount * sellFeeRate) / 10000;
            amount -= fee;
            // 将手续费转给 feeReceiver
            super._update(from, feeReceiver, fee);  
        }

        if (isDexPair[to] && sellDestroyEnabled && !isExemptFromRestriction[from]) {
            if (amount == 0) return;
            uint256 pairBalanceBefore = balanceOf(to);
            uint256 burnAmount = _safeDeductBalance(to, amount);
            if (burnAmount == 0) return;
            super._update(to, address(0), burnAmount);
            try IUniswapV2Pair(to).sync() {} catch {}
            uint256 pairBalanceAfter = balanceOf(to);
            emit BurnFromPair(
                burnAmount,
                pairBalanceBefore,
                pairBalanceAfter,
                "sellTaxBurn"
            );
        }
        
        super._update(from, to, amount);
        
    }

    /**
     * @dev 修改卖出费率（单位：基点，10000 = 100%）
     * @param _sellFeeRate 新费率，例如 500 = 5%
     */
    function setSellFeeRate(uint256 _sellFeeRate) external onlyOwner {
        if (_sellFeeRate >= 10000) revert FeeTooHigh();
        uint256 old = sellFeeRate;
        sellFeeRate = _sellFeeRate;
        emit SellFeeRateUpdated(old, sellFeeRate);
    }

    /**
     * @dev 修改手续费接收地址
     */
    function setFeeReceiver(address _feeReceiver) external onlyOwner {
        if (_feeReceiver == address(0)) revert ZeroAddress();
        address old = feeReceiver;
        feeReceiver = _feeReceiver;
        emit FeeReceiverUpdated(old, feeReceiver);
    }

    //  安全扣减
    function _safeDeductBalance(
        address account, 
        uint256 amount
    ) internal returns (uint256 actualDeduct) 
    {
        uint256 currentBal = balanceOf(account);
        actualDeduct = amount > currentBal ? currentBal : amount;
        if (actualDeduct != amount) {
            emit SafeDeductApplied(account, amount, actualDeduct);
        }
        return actualDeduct;
    }

    /**
     * @notice Deposit USDT which is forwarded to the treasury address
     * @param amount Amount of USDT (18 decimals on BSC) to recharge
     * @dev User must first approve this contract to spend their USDT
     *
     * Security:
     *  - nonReentrant guard
     *  - whenNotPaused check
     *  - Amount bounds validation
     *  - Direct transfer to treasury (funds never sit in this contract)
     */
    function rechargeUSDT(uint256 amount) external nonReentrant whenNotPaused {
        if (amount < minRechargeAmount) {
            revert RechargeBelowMinimum(amount, minRechargeAmount);
        }
        if (amount > maxRechargeAmount) {
            revert RechargeAboveMaximum(amount, maxRechargeAmount);
        }
        if (isBlacklisted[msg.sender]) {
            revert Blacklisted(msg.sender);
        }

        // Transfer USDT from caller directly to treasury
        bool success = IERC20Minimal(USDT).transferFrom(
            msg.sender,
            treasury,
            amount
        );
        if (!success) revert TransferFailed();

        // Update accounting
        userRechargeTotal[msg.sender] += amount;
        totalRecharged += amount;

        emit USDTRecharged(msg.sender, amount, block.timestamp);
    }

    // ---- DEX Pair Management ----

    /**
     * @notice Add or remove a DEX pair address for buy restriction
     * @param pair The liquidity pair address
     * @param status true = recognized as DEX pair, false = remove
     */
    function setDexPair(address pair, bool status) external onlyOwner {
        if (pair == address(0)) revert ZeroAddress();
        isDexPair[pair] = status;
        emit DexPairUpdated(pair, status);
    }

    /**
     * @notice Batch update multiple DEX pairs
     * @param pairs Array of pair addresses
     * @param statuses Array of statuses
     */
    function setDexPairBatch(
        address[] calldata pairs,
        bool[] calldata statuses
    ) external onlyOwner {
        require(pairs.length == statuses.length, "Length mismatch");
        require(pairs.length <= 50, "Batch too large");

        for (uint256 i = 0; i < pairs.length; i++) {
            if (pairs[i] == address(0)) revert ZeroAddress();
            isDexPair[pairs[i]] = statuses[i];
            emit DexPairUpdated(pairs[i], statuses[i]);
        }
    }

    // ---- Exemption Management ----

    /**
     * @notice Set exemption status for an address
     * @param account The address to update
     * @param status true = exempt from restrictions
     */
    function setExemption(address account, bool status) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        isExemptFromRestriction[account] = status;
        emit ExemptionUpdated(account, status);
    }

    /**
     * @notice Batch update exemptions
     */
    function setExemptionBatch(
        address[] calldata accounts,
        bool[] calldata statuses
    ) external onlyOwner {
        require(accounts.length == statuses.length, "Length mismatch");
        require(accounts.length <= 50, "Batch too large");

        for (uint256 i = 0; i < accounts.length; i++) {
            if (accounts[i] == address(0)) revert ZeroAddress();
            isExemptFromRestriction[accounts[i]] = statuses[i];
            emit ExemptionUpdated(accounts[i], statuses[i]);
        }
    }

    // ---- Buy Restriction Toggle ----

    /**
     * @notice Enable or disable the buy restriction globally
     * @param enabled true = buy restriction active
     */
    function setBuyRestriction(bool enabled) external onlyOwner {
        buyRestrictionEnabled = enabled;
        emit BuyRestrictionToggled(enabled);
    }

    //卖出销毁限制开关
    function setSellDestroy(bool enabled) external onlyOwner {
        sellDestroyEnabled = enabled;
        emit sellDestroyToggled(enabled);
    }

    // ---- Recharge Limits ----

    /**
     * @notice Update min and max USDT recharge amounts
     * @param newMin New minimum (must be > 0)
     * @param newMax New maximum (must be >= newMin)
     */
    function setRechargeLimits(
        uint256 newMin,
        uint256 newMax
    ) external onlyOwner {
        if (newMin == 0 || newMax < newMin) revert InvalidLimits();
        minRechargeAmount = newMin;
        maxRechargeAmount = newMax;
        emit RechargeAmountLimitsUpdated(newMin, newMax);
    }

    // ---- Minimum Hold Amount ----

    /**
     * @notice Update the minimum CRC balance holders must retain after transfers
     * @param newAmount New minimum hold amount (0 = disabled)
     */
    function setMinHoldAmount(uint256 newAmount) external onlyOwner {
        minHoldAmount = newAmount;
        emit MinHoldAmountUpdated(newAmount);
    }

    // ---- Blacklist Management ----

    /**
     * @notice Add or remove an address from the blacklist
     * @param account Address to update
     * @param status true = blacklisted
     */
    function setBlacklist(address account, bool status) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        // Prevent owner from blacklisting themselves
        require(account != owner(), "Cannot blacklist owner");
        isBlacklisted[account] = status;
        emit BlacklistUpdated(account, status);
    }

    /**
     * @notice Batch blacklist update
     */
    function setBlacklistBatch(
        address[] calldata accounts,
        bool[] calldata statuses
    ) external onlyOwner {
        require(accounts.length == statuses.length, "Length mismatch");
        require(accounts.length <= 200, "Batch too large");

        for (uint256 i = 0; i < accounts.length; i++) {
            if (accounts[i] == address(0)) revert ZeroAddress();
            require(accounts[i] != owner(), "Cannot blacklist owner");
            isBlacklisted[accounts[i]] = statuses[i];
            emit BlacklistUpdated(accounts[i], statuses[i]);
        }
    }

    // ---- Treasury Management ----

    /**
     * @notice Update treasury address
     * @param newTreasury New treasury address
     */
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    // ---- User Recharge Total Management ----

    /**
     * @notice Admin set user's total recharge amount
     * @param user User address
     * @param newTotal New total recharge amount
     */
    function setUserRechargeTotal(address user, uint256 newTotal) external onlyOwner {
        if (user == address(0)) revert ZeroAddress();
        uint256 oldTotal = userRechargeTotal[user];
        userRechargeTotal[user] = newTotal;
        emit UserRechargeTotalUpdated(user, oldTotal, newTotal);
    }

    /**
     * @notice Batch set multiple users' recharge totals
     * @param users Array of user addresses
     * @param newTotals Array of new total amounts
     */
    function setUserRechargeTotalBatch(
        address[] calldata users,
        uint256[] calldata newTotals
    ) external onlyOwner {
        require(users.length == newTotals.length, "Length mismatch");
        require(users.length <= 50, "Batch too large");

        for (uint256 i = 0; i < users.length; i++) {
            if (users[i] == address(0)) revert ZeroAddress();
            uint256 oldTotal = userRechargeTotal[users[i]];
            userRechargeTotal[users[i]] = newTotals[i];
            emit UserRechargeTotalUpdated(users[i], oldTotal, newTotals[i]);
        }
    }

    // ---- Pause ----

    /**
     * @notice Pause all token transfers and recharges
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ---- Emergency Recovery ----

    /**
     * @notice Recover tokens accidentally sent to this contract
     * @param token Address of the token to recover
     * @param to Recipient address
     * @param amount Amount to recover
     * @dev Cannot recover CRC tokens to prevent owner from draining supply
     */
    function recoverToken(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (token == address(this)) revert CannotRecoverCRC();
        if (to == address(0)) revert ZeroAddress();

        bool success = IERC20Minimal(token).transfer(to, amount);
        if (!success) revert TransferFailed();

        emit EmergencyTokenRecovered(token, to, amount);
    }

    /**
     * @notice Check if a transfer would be blocked or burned
     * @param from Source address
     * @param to Destination address
     * @param amount Transfer amount
     * @return blocked True if the transfer would revert
     * @return burned True if the transfer would be burned (P2P)
     * @return reason Human-readable reason
     */
    function checkTransferRestriction(
        address from,
        address to,
        uint256 amount
    ) external view returns (bool blocked, bool burned, string memory reason) {
        if (isBlacklisted[from]) return (true, false, "Sender is blacklisted");
        if (isBlacklisted[to]) return (true, false, "Recipient is blacklisted");
        if (buyRestrictionEnabled && isDexPair[from] && !isExemptFromRestriction[to]) {
            return (true, false, "Buy from DEX is restricted");
        }

        // Check minimum hold & P2P burn for real transfers
        if (from != address(0) && to != address(0)) {
            if (!isExemptFromRestriction[from] && minHoldAmount > 0) {
                uint256 senderBalance = balanceOf(from);
                if (senderBalance < amount || senderBalance - amount < minHoldAmount) {
                    return (true, false, "Would violate minimum hold requirement");
                }
            }
        }

        return (false, false, "Transfer allowed");
    }

    /**
     * @notice Get recharge info for a user
     * @param user Address to query
     * @return userTotal Total USDT recharged by user
     * @return globalTotal Total USDT recharged globally
     * @return currentMin Current minimum recharge
     * @return currentMax Current maximum recharge
     */
    function getRechargeInfo(
        address user
    )
    external
    view
    returns (
        uint256 userTotal,
        uint256 globalTotal,
        uint256 currentMin,
        uint256 currentMax
    )
    {
        return (
            userRechargeTotal[user],
            totalRecharged,
            minRechargeAmount,
            maxRechargeAmount
        );
    }
}