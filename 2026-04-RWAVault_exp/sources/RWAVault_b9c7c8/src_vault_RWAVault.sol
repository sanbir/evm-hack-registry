// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IRWAVault} from "../interfaces/IRWAVault.sol";
import {RWAConstants} from "../libraries/RWAConstants.sol";
import {RWAErrors} from "../libraries/RWAErrors.sol";
import {RWAEvents} from "../libraries/RWAEvents.sol";

/// @notice Error for already initialized vault
error AlreadyInitialized();

/// @title RWAVault
/// @notice ERC4626 Fixed-term vault with monthly interest payments
/// @dev Users deposit during collection phase, earn monthly interest during active phase,
///      and withdraw principal + final interest at maturity. Integrates with PoolManager.
contract RWAVault is
    ERC4626,
    AccessControl,
    Pausable,
    ReentrancyGuard,
    IRWAVault
{
    using SafeERC20 for IERC20;

    // ============ Structs ============

    /// @notice User deposit information for interest tracking
    struct DepositInfo {
        uint256 shares;             // User's shares
        uint256 principal;          // Original deposit amount (USDC)
        uint256 lastClaimMonth;     // Last month interest was claimed
        uint256 depositTime;        // Timestamp of deposit
    }

    /// @notice Capital deployment record
    struct DeploymentRecord {
        uint256 deployedUSD;        // Deployed amount in USD
        uint256 deploymentTime;     // Deployment timestamp
        uint256 returnedUSD;        // Returned amount in USD
        uint256 returnTime;         // Return timestamp
        bool settled;               // Whether this deployment is settled
    }

    /// @notice Pending deployment for timelock mechanism
    struct PendingDeployment {
        uint256 amount;             // Amount to deploy
        address recipient;          // Recipient address
        uint256 executeTime;        // Earliest execution time
        bool active;                // Whether this deployment is pending
    }

    // ============ Storage (DO NOT change order!) ============

    /// @notice Current phase (uses IRWAVault.Phase enum)
    Phase public currentPhase;

    /// @notice Collection phase start time (when deposits become allowed)
    uint256 public collectionStartTime;

    /// @notice Collection phase end time
    uint256 public collectionEndTime;

    /// @notice Interest start time (when interest begins accruing)
    uint256 public interestStartTime;

    /// @notice Term duration in seconds (informational, for VaultRegistry categorization)
    uint256 public termDuration;

    /// @notice Fixed APY in basis points
    uint256 public fixedAPY;

    /// @notice Minimum deposit amount
    uint256 public minDeposit;

    /// @notice Maximum vault capacity
    uint256 public maxCapacity;

    /// @notice Total capital deployed externally
    uint256 public totalDeployed;

    /// @notice Total interest paid out
    uint256 public totalInterestPaid;

    /// @notice Pool manager address
    address public poolManager;

    /// @notice Whether the vault is active
    bool public active;

    /// @notice User deposit info (for interest tracking)
    mapping(address => DepositInfo) private _depositInfos;

    // ============ Extended Storage ============

    /// @notice Total principal deposited (for accurate interest calculation)
    uint256 public totalPrincipal;

    /// @notice Deployment history for FX tracking
    DeploymentRecord[] public deploymentHistory;

    /// @notice Current deployment index (for tracking active deployment)
    uint256 public currentDeploymentIndex;

    /// @notice Interest period end dates (actual end date of each month's interest period)
    uint256[] public interestPeriodEndDates;

    /// @notice Interest payment dates (timestamps when each month's interest becomes claimable)
    uint256[] public interestPaymentDates;

    /// @notice Withdrawal start time (when principal can actually be withdrawn)
    /// @dev Can be different from maturityTime due to bank processing delays
    uint256 public withdrawalStartTime;

    /// @notice Default time (when vault was defaulted, 0 if not defaulted)
    uint256 public defaultTime;

    // ============ Access Control Storage ============

    /// @notice Whether whitelist is enabled for deposits
    bool public whitelistEnabled;

    /// @notice Whitelist mapping (address => isWhitelisted)
    mapping(address => bool) private _whitelist;

    /// @notice Minimum deposit per user (0 = no minimum)
    uint256 public minDepositPerUser;

    /// @notice Maximum deposit per user (0 = no maximum)
    uint256 public maxDepositPerUser;

    // ============ Cap Allocation Storage ============

    /// @notice Allocated cap per address (bypasses whitelist and min/max checks)
    mapping(address => uint256) private _allocatedCap;

    /// @notice Total allocated capacity (sum of all individual allocations)
    uint256 public totalAllocated;

    /// @notice Total deposits from allocated users (for public pool capacity calculation)
    uint256 public totalAllocatedDeposits;

    // ============ Hybrid Interest System Storage ============

    /// @notice Total claimed interest across all users (for totalAssets calculation)
    uint256 public totalClaimedInterest;

    /// @notice Per-user claimed interest (acts as debt, reduces redemption value)
    mapping(address => uint256) private _userClaimedInterest;

    // ============ Deployment Timelock Storage ============

    /// @notice Deployment delay in seconds (default: 24 hours)
    uint256 public deploymentDelay;

    /// @notice Current pending deployment
    PendingDeployment public pendingDeployment;

    /// @notice Deployment ID counter for events
    uint256 public deploymentIdCounter;

    /// @notice Initialization flag for clone pattern
    bool private _initialized;

    /// @notice Vault name (for clone pattern)
    string private _vaultName;

    /// @notice Vault symbol (for clone pattern)
    string private _vaultSymbol;

    // ============ Constructor ============

    /// @notice Creates the implementation contract
    /// @param asset_ The underlying asset address (used for implementation)
    constructor(address asset_) ERC4626(IERC20(asset_)) ERC20("", "") {
        // Implementation contract - mark as initialized to prevent direct use
        _initialized = true;
    }

    // ============ Initializer ============

    /// @notice Initializes a clone vault
    /// @param name_ The vault name
    /// @param symbol_ The vault symbol
    /// @param collectionEndTime_ Collection phase end time
    /// @param collectionStartTime_ Collection start time (when deposits allowed)
    /// @param interestStartTime_ Interest start time
    /// @param termDuration_ Term duration in seconds
    /// @param fixedAPY_ Fixed APY in basis points
    /// @param minDeposit_ Minimum deposit amount
    /// @param maxCapacity_ Maximum vault capacity
    /// @param poolManager_ Pool manager address
    /// @param admin_ Admin address
    function initialize(
        string memory name_,
        string memory symbol_,
        uint256 collectionStartTime_,
        uint256 collectionEndTime_,
        uint256 interestStartTime_,
        uint256 termDuration_,
        uint256 fixedAPY_,
        uint256 minDeposit_,
        uint256 maxCapacity_,
        address poolManager_,
        address admin_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        if (admin_ == address(0)) revert RWAErrors.ZeroAddress();
        if (poolManager_ == address(0)) revert RWAErrors.ZeroAddress();
        if (collectionStartTime_ > collectionEndTime_) revert RWAErrors.InvalidAmount();
        if (collectionEndTime_ <= block.timestamp) revert RWAErrors.InvalidAmount();
        if (interestStartTime_ < collectionEndTime_) revert RWAErrors.InvalidAmount();
        if (fixedAPY_ > RWAConstants.MAX_TARGET_APY) revert RWAErrors.InvalidAPY();

        // Set name and symbol
        _vaultName = name_;
        _vaultSymbol = symbol_;

        collectionStartTime = collectionStartTime_;
        collectionEndTime = collectionEndTime_;
        interestStartTime = interestStartTime_;
        termDuration = termDuration_;
        fixedAPY = fixedAPY_;
        minDeposit = minDeposit_;
        maxCapacity = maxCapacity_;
        poolManager = poolManager_;
        currentPhase = Phase.Collecting;
        active = true;

        // Default deployment delay: 1 hour
        deploymentDelay = 1 hours;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(RWAConstants.PAUSER_ROLE, admin_);
        _grantRole(RWAConstants.OPERATOR_ROLE, poolManager_);
    }

    /// @notice Returns the name of the token
    /// @dev Overrides ERC20 to support clone pattern
    function name() public view override(ERC20, IERC20Metadata) returns (string memory) {
        return bytes(_vaultName).length > 0 ? _vaultName : super.name();
    }

    /// @notice Returns the symbol of the token
    /// @dev Overrides ERC20 to support clone pattern
    function symbol() public view override(ERC20, IERC20Metadata) returns (string memory) {
        return bytes(_vaultSymbol).length > 0 ? _vaultSymbol : super.symbol();
    }

    /// @notice Returns the maturity time (derived from interestPeriodEndDates)
    /// @dev Returns last element of interestPeriodEndDates, or fallback calculation if not set
    function maturityTime() public view returns (uint256) {
        return _getMaturityTime();
    }

    /// @notice Internal helper to get maturity time with fallback
    function _getMaturityTime() internal view returns (uint256) {
        if (interestPeriodEndDates.length > 0) {
            return interestPeriodEndDates[interestPeriodEndDates.length - 1];
        }
        return interestStartTime + termDuration;
    }

    // ============ Modifiers ============

    modifier onlyPhase(Phase phase) {
        if (currentPhase != phase) revert RWAErrors.InvalidPhase();
        _;
    }

    modifier onlyPoolManager() {
        if (msg.sender != poolManager) revert RWAErrors.Unauthorized();
        _;
    }

    modifier onlyActive() {
        if (!active) revert RWAErrors.VaultNotActive();
        _;
    }

    // ============ ERC4626 Overrides ============

    /// @notice Returns total assets including accrued interest
    /// @dev Share value = totalAssets() / totalSupply() = (principal + accruedInterest) / totalShares
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        if (totalSupply() == 0) {
            return IERC20(asset()).balanceOf(address(this));
        }

        // During collection phase, just return principal
        if (currentPhase == Phase.Collecting || block.timestamp < interestStartTime) {
            return totalPrincipal;
        }

        // Calculate accrued interest based on days elapsed
        uint256 accruedInterest = _calculateTotalAccruedInterest();

        // Hybrid system: Don't subtract claimed interest from totalAssets
        // Claimed interest is tracked as per-user debt, subtracted at redemption
        return totalPrincipal + accruedInterest;
    }

    /// @notice Calculate total accrued interest for all principal (per-second accrual)
    /// @dev Uses seconds for precise share value calculation in secondary market
    /// @notice Calculate total accrued interest based on period end dates
    /// @dev Uses actual period lengths for accurate calculation
    function _calculateTotalAccruedInterest() internal view returns (uint256) {
        if (block.timestamp < interestStartTime) {
            return 0;
        }

        // If no period end dates set, fall back to simple calculation
        if (interestPeriodEndDates.length == 0) {
            return _calculateSimpleAccruedInterest();
        }

        // Determine end time based on phase
        uint256 endTime = block.timestamp;
        uint256 _maturityTime = _getMaturityTime();
        if (currentPhase == Phase.Defaulted && defaultTime > 0) {
            endTime = defaultTime;
        } else if (endTime > _maturityTime) {
            endTime = _maturityTime;
        }

        // Monthly interest = totalPrincipal * APY / 12 / 10000
        uint256 monthlyInterest = (totalPrincipal * fixedAPY) / (RWAConstants.MONTHS_PER_YEAR * RWAConstants.BASIS_POINTS);

        uint256 totalInterest = 0;
        uint256 periodStart = interestStartTime;
        uint256 len = interestPeriodEndDates.length;

        for (uint256 i = 0; i < len;) {
            uint256 periodEnd = interestPeriodEndDates[i];

            if (endTime >= periodEnd) {
                // Completed period: add full monthly interest
                totalInterest += monthlyInterest;
            } else if (endTime > periodStart) {
                // Current partial period: pro-rata calculation
                uint256 periodLength = periodEnd - periodStart;
                uint256 elapsed = endTime - periodStart;
                totalInterest += (monthlyInterest * elapsed) / periodLength;
                break;
            } else {
                // Future period: stop
                break;
            }

            periodStart = periodEnd;
            unchecked { ++i; }
        }

        return totalInterest;
    }

    /// @notice Fallback simple interest calculation (when period end dates not set)
    function _calculateSimpleAccruedInterest() internal view returns (uint256) {
        uint256 endTime = block.timestamp;
        uint256 _maturityTime = _getMaturityTime();
        if (currentPhase == Phase.Defaulted && defaultTime > 0) {
            endTime = defaultTime;
        } else if (endTime > _maturityTime) {
            endTime = _maturityTime;
        }

        uint256 elapsed = endTime - interestStartTime;
        return (totalPrincipal * fixedAPY * elapsed) / (RWAConstants.SECONDS_PER_YEAR * RWAConstants.BASIS_POINTS);
    }

    // ============ ERC4626 Max Functions ============

    /// @notice Returns maximum assets that can be deposited by receiver
    /// @dev Returns 0 if not in Collecting phase, paused, inactive, or receiver not authorized
    ///      Allocated users: returns remaining allocation
    ///      Non-allocated users: returns remaining public capacity (constrained by per-user caps)
    function maxDeposit(address receiver) public view override(ERC4626, IERC4626) returns (uint256) {
        // Check basic conditions
        if (currentPhase != Phase.Collecting) return 0;
        if (!active) return 0;
        if (paused()) return 0;
        if (block.timestamp >= collectionEndTime) return 0;

        uint256 userDeposited = _depositInfos[receiver].principal;
        uint256 userAllocation = _allocatedCap[receiver];

        if (userAllocation > 0) {
            // Allocated user: return remaining allocation
            if (userDeposited >= userAllocation) return 0;
            return userAllocation - userDeposited;
        }

        // Non-allocated user: whitelist check
        if (whitelistEnabled && !_whitelist[receiver]) return 0;

        // Calculate public pool remaining capacity
        uint256 publicCapacity = maxCapacity > totalAllocated ? maxCapacity - totalAllocated : 0;
        uint256 publicPoolUsed = totalPrincipal > totalAllocatedDeposits ? totalPrincipal - totalAllocatedDeposits : 0;
        if (publicPoolUsed >= publicCapacity) return 0;
        uint256 remaining = publicCapacity - publicPoolUsed;

        // Per-user cap check
        if (maxDepositPerUser > 0) {
            if (userDeposited >= maxDepositPerUser) return 0;
            uint256 userRemaining = maxDepositPerUser - userDeposited;
            if (userRemaining < remaining) {
                remaining = userRemaining;
            }
        }

        return remaining;
    }

    /// @notice Returns maximum shares that can be minted by receiver
    /// @dev Returns 0 if not in Collecting phase or other restrictions apply
    function maxMint(address receiver) public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (maxAssets == 0) return 0;
        return convertToShares(maxAssets);
    }

    /// @notice Returns maximum assets that can be withdrawn by owner
    /// @dev Returns 0 if not in Matured phase or before withdrawalStartTime
    function maxWithdraw(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        // Check basic conditions - allow both Matured and Defaulted phases
        if (currentPhase != Phase.Matured && currentPhase != Phase.Defaulted) return 0;
        if (paused()) return 0;
        if (withdrawalStartTime == 0 || block.timestamp < withdrawalStartTime) return 0;

        DepositInfo storage info = _depositInfos[owner];
        if (info.shares == 0) return 0;

        // Hybrid system: gross value minus claimed interest (debt)
        uint256 grossValue = convertToAssets(info.shares);
        uint256 userDebt = _userClaimedInterest[owner];

        // Net withdrawable = gross value - already claimed interest
        return grossValue > userDebt ? grossValue - userDebt : 0;
    }

    /// @notice Returns maximum shares that can be redeemed by owner
    /// @dev Returns 0 if not in Matured/Defaulted phase or before withdrawalStartTime
    ///      Returns actual remaining shares (after interest claims, only principal-backed shares remain)
    function maxRedeem(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        // Check basic conditions - allow both Matured and Defaulted phases
        if (currentPhase != Phase.Matured && currentPhase != Phase.Defaulted) return 0;
        if (paused()) return 0;
        if (withdrawalStartTime == 0 || block.timestamp < withdrawalStartTime) return 0;

        // Return the depositor's tracked shares (includes interest claim history)
        return _depositInfos[owner].shares;
    }

    // ============ Hybrid System View Functions ============

    /// @notice Get user's net redemption value for secondary market display
    /// @dev This is the actual value a user would receive if they redeemed all shares
    ///      Net value = gross value (convertToAssets) - claimed interest (debt)
    /// @param owner Address to check
    /// @return Net redemption value in asset units
    function getNetRedemptionValue(address owner) public view returns (uint256) {
        DepositInfo storage info = _depositInfos[owner];
        if (info.shares == 0) return 0;

        uint256 grossValue = convertToAssets(info.shares);
        uint256 userDebt = _userClaimedInterest[owner];

        return grossValue > userDebt ? grossValue - userDebt : 0;
    }

    /// @notice Get user's claimed interest (debt)
    /// @dev This amount will be subtracted from gross value at redemption
    /// @param owner Address to check
    /// @return Amount of interest already claimed by user
    function getUserClaimedInterest(address owner) public view returns (uint256) {
        return _userClaimedInterest[owner];
    }

    /// @notice Get comprehensive share info for secondary market
    /// @dev Returns all relevant data for pricing shares in secondary market
    /// @param owner Address to check
    /// @return shares Number of shares owned
    /// @return grossValue Total value before debt deduction (convertToAssets)
    /// @return claimedInterest Interest already claimed (debt)
    /// @return netValue Actual redemption value (gross - debt)
    /// @return lastClaimMonth Last month interest was claimed
    function getShareInfo(address owner) external view returns (
        uint256 shares,
        uint256 grossValue,
        uint256 claimedInterest,
        uint256 netValue,
        uint256 lastClaimMonth
    ) {
        DepositInfo storage info = _depositInfos[owner];
        shares = info.shares;
        grossValue = shares > 0 ? convertToAssets(shares) : 0;
        claimedInterest = _userClaimedInterest[owner];
        netValue = grossValue > claimedInterest ? grossValue - claimedInterest : 0;
        lastClaimMonth = info.lastClaimMonth;
    }

    // ============ Deposit/Mint Functions ============

    /// @notice Deposits assets during collection phase only
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        whenNotPaused
        onlyActive
        onlyPhase(Phase.Collecting)
        returns (uint256 shares)
    {
        // Pre-checks (early revert for obvious failures)
        if (assets < minDeposit) revert RWAErrors.MinDepositNotMet();
        if (collectionStartTime > 0 && block.timestamp < collectionStartTime) revert RWAErrors.CollectionNotStarted();
        if (block.timestamp >= collectionEndTime) revert RWAErrors.CollectionEnded();

        // Cache storage variables for gas optimization
        uint256 _maxCapacity = maxCapacity;
        uint256 _totalAllocated = totalAllocated;
        uint256 _totalPrincipal = totalPrincipal;

        uint256 userAllocation = _allocatedCap[receiver];
        uint256 newUserTotal = _depositInfos[receiver].principal + assets;
        bool isAllocatedUser = userAllocation > 0;

        if (isAllocatedUser) {
            // Allocated user: bypass whitelist and min/max checks, use allocation cap
            if (newUserTotal > userAllocation) revert RWAErrors.ExceedsUserDepositCap();
        } else {
            // Non-allocated user: normal checks apply
            // Whitelist check
            if (whitelistEnabled && !_whitelist[receiver]) revert RWAErrors.NotWhitelisted();

            // Check against public capacity (maxCapacity - totalAllocated)
            uint256 publicCapacity = _maxCapacity > _totalAllocated ? _maxCapacity - _totalAllocated : 0;
            uint256 publicPoolUsed = _totalPrincipal > totalAllocatedDeposits ? _totalPrincipal - totalAllocatedDeposits : 0;
            if (publicPoolUsed + assets > publicCapacity) revert RWAErrors.VaultCapacityExceeded();

            // Per-user cap check (min and max)
            if (minDepositPerUser > 0 && newUserTotal < minDepositPerUser) {
                revert RWAErrors.BelowUserMinDeposit();
            }
            if (maxDepositPerUser > 0 && newUserTotal > maxDepositPerUser) {
                revert RWAErrors.ExceedsUserDepositCap();
            }
        }

        // Final capacity check (absolute limit)
        // In Collecting phase, totalAssets() == totalPrincipal, so use cached value
        if (_totalPrincipal + assets > _maxCapacity) revert RWAErrors.VaultCapacityExceeded();

        shares = super.deposit(assets, receiver);

        // Track user's deposit info
        DepositInfo storage info = _depositInfos[receiver];
        info.shares += shares;
        info.principal += assets;           // Store principal
        info.depositTime = block.timestamp; // Store deposit time

        // Track total principal
        totalPrincipal = _totalPrincipal + assets;

        // Track allocated deposits separately
        if (isAllocatedUser) {
            totalAllocatedDeposits += assets;
        }
    }

    /// @notice Mints shares during collection phase only
    function mint(uint256 shares, address receiver)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        whenNotPaused
        onlyActive
        onlyPhase(Phase.Collecting)
        returns (uint256 assets)
    {
        // Pre-checks using estimated assets (for early revert on obvious failures)
        uint256 estimatedAssets = previewMint(shares);
        if (estimatedAssets < minDeposit) revert RWAErrors.MinDepositNotMet();
        if (block.timestamp >= collectionEndTime) revert RWAErrors.CollectionEnded();

        uint256 userAllocation = _allocatedCap[receiver];
        bool isAllocatedUser = userAllocation > 0;

        if (!isAllocatedUser) {
            // Non-allocated user: whitelist check
            if (whitelistEnabled && !_whitelist[receiver]) revert RWAErrors.NotWhitelisted();
        }

        // Execute mint
        assets = super.mint(shares, receiver);

        // Post-mint validation: verify actual state (prevents previewMint bypass)
        if (totalAssets() > maxCapacity) revert RWAErrors.VaultCapacityExceeded();

        // Per-user cap check with actual assets
        uint256 newUserTotal = _depositInfos[receiver].principal + assets;

        if (isAllocatedUser) {
            // Allocated user: check against their allocation
            if (newUserTotal > userAllocation) revert RWAErrors.ExceedsUserDepositCap();
        } else {
            // Non-allocated user: check public capacity and per-user caps
            uint256 publicCapacity = maxCapacity > totalAllocated ? maxCapacity - totalAllocated : 0;
            uint256 publicPoolUsed = totalPrincipal > totalAllocatedDeposits ? totalPrincipal - totalAllocatedDeposits : 0;
            if (publicPoolUsed + assets > publicCapacity) revert RWAErrors.VaultCapacityExceeded();

            if (minDepositPerUser > 0 && newUserTotal < minDepositPerUser) {
                revert RWAErrors.BelowUserMinDeposit();
            }
            if (maxDepositPerUser > 0 && newUserTotal > maxDepositPerUser) {
                revert RWAErrors.ExceedsUserDepositCap();
            }
        }

        // Track user's deposit info
        DepositInfo storage info = _depositInfos[receiver];
        info.shares += shares;
        info.principal += assets;           // Store principal
        info.depositTime = block.timestamp; // Store deposit time

        // Track total principal
        totalPrincipal += assets;

        // Track allocated deposits separately
        if (isAllocatedUser) {
            totalAllocatedDeposits += assets;
        }
    }

    /// @notice Withdraws assets - only allowed after withdrawalStartTime in Matured or Defaulted phase
    /// @dev Claims any remaining interest first (burning shares), then withdraws assets from remaining principal
    /// @dev Claims any remaining interest first (burning shares), then withdraws principal
    ///      Uses direct principal calculation to avoid ERC4626 conversion rounding errors
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        // Check phase: must be Matured or Defaulted
        if (currentPhase != Phase.Matured && currentPhase != Phase.Defaulted) {
            revert RWAErrors.InvalidPhase();
        }

        // Check if withdrawal is available (actual withdrawal time check)
        // withdrawalStartTime must be explicitly set (>0) before withdrawals are allowed
        if (withdrawalStartTime == 0 || block.timestamp < withdrawalStartTime) {
            revert RWAErrors.WithdrawalNotAvailable();
        }

        // Claim any remaining interest first (records as debt in hybrid system)
        _claimRemainingInterest(owner);

        DepositInfo storage info = _depositInfos[owner];
        if (info.shares == 0) revert RWAErrors.ZeroAmount();

        // Hybrid system: Calculate user's net value
        uint256 grossValue = convertToAssets(info.shares);
        uint256 userDebt = _userClaimedInterest[owner];

        // Explicit underflow check for clearer error message
        if (grossValue < userDebt) revert RWAErrors.InsufficientBalance();
        uint256 netValue = grossValue - userDebt;

        // Cap assets to available net value
        if (assets > netValue) {
            assets = netValue;
        }

        if (assets == 0) revert RWAErrors.ZeroAmount();

        // Calculate shares to burn proportionally
        // [H-01 FIX] Round up shares to favor protocol (user burns more)
        shares = Math.mulDiv(assets, info.shares, netValue, Math.Rounding.Ceil);

        if (shares == 0) revert RWAErrors.ZeroAmount();

        // Calculate proportional debt to deduct
        // [H-01 FIX] Round down debt to favor user (less debt deducted)
        uint256 debtToDeduct = Math.mulDiv(userDebt, shares, info.shares, Math.Rounding.Floor);

        // Calculate proportional principal reduction
        // [H-01 FIX] Round down to favor protocol
        uint256 principalReduction = Math.mulDiv(info.principal, shares, info.shares, Math.Rounding.Floor);

        // Update tracking
        info.principal -= principalReduction;
        info.shares -= shares;
        totalPrincipal -= principalReduction;

        // Clear proportional debt
        _userClaimedInterest[owner] -= debtToDeduct;
        totalClaimedInterest -= debtToDeduct;

        // Burn shares and transfer assets
        _burn(owner, shares);
        IERC20(asset()).safeTransfer(receiver, assets);
    }

    /// @notice Redeems shares - only allowed after withdrawalStartTime in Matured or Defaulted phase
    /// @dev Claims any remaining interest first (burning shares), then redeems remaining principal
    ///      Uses direct principal calculation to avoid ERC4626 conversion rounding errors
    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        // Check phase: must be Matured or Defaulted
        if (currentPhase != Phase.Matured && currentPhase != Phase.Defaulted) {
            revert RWAErrors.InvalidPhase();
        }

        // Check if withdrawal is available (actual withdrawal time check)
        // withdrawalStartTime must be explicitly set (>0) before withdrawals are allowed
        if (withdrawalStartTime == 0 || block.timestamp < withdrawalStartTime) {
            revert RWAErrors.WithdrawalNotAvailable();
        }

        // Claim any remaining interest first (records as debt in hybrid system)
        _claimRemainingInterest(owner);

        DepositInfo storage info = _depositInfos[owner];

        // Cap shares to actual balance
        if (shares > info.shares) {
            shares = info.shares;
        }

        if (shares == 0) revert RWAErrors.ZeroAmount();

        // Hybrid system: Calculate gross value using ERC4626 standard
        uint256 grossValue = convertToAssets(shares);

        // Calculate proportional debt to deduct
        // [H-01 FIX] Round down debt to favor user (less debt deducted)
        uint256 userDebt = _userClaimedInterest[owner];
        uint256 debtToDeduct = Math.mulDiv(userDebt, shares, info.shares, Math.Rounding.Floor);

        // Net assets = gross value - debt already claimed
        assets = grossValue - debtToDeduct;

        // Calculate proportional principal reduction
        // [H-01 FIX] Round down to favor protocol
        uint256 principalReduction = Math.mulDiv(info.principal, shares, info.shares, Math.Rounding.Floor);

        // Update tracking
        info.principal -= principalReduction;
        info.shares -= shares;
        totalPrincipal -= principalReduction;

        // Clear proportional debt
        _userClaimedInterest[owner] -= debtToDeduct;
        totalClaimedInterest -= debtToDeduct;

        // Burn shares and transfer assets
        _burn(owner, shares);
        IERC20(asset()).safeTransfer(receiver, assets);
    }

    // ============ Interest Functions ============

    /// @notice Claim monthly interest (hybrid system - records debt instead of burning shares)
    /// @dev Transfers interest to user and records as debt. Debt is deducted at redemption.
    ///      Shares remain unchanged, ensuring consistent share price for secondary market.
    function claimInterest() external nonReentrant whenNotPaused {
        if (currentPhase == Phase.Collecting) revert RWAErrors.InvalidPhase();

        DepositInfo storage info = _depositInfos[msg.sender];
        if (info.shares == 0) revert RWAErrors.ZeroAmount();

        uint256 claimableMonths = _getClaimableMonths(msg.sender);
        if (claimableMonths == 0) revert RWAErrors.ZeroAmount();

        // Calculate interest based on original principal
        uint256 monthlyInterest = _calculateMonthlyInterest(info.principal);
        uint256 interestAmount = monthlyInterest * claimableMonths;

        // Check vault has sufficient liquidity
        uint256 availableBalance = IERC20(asset()).balanceOf(address(this));
        if (interestAmount > availableBalance) revert RWAErrors.InsufficientLiquidity();

        // Update user's last claim month (shares stay the same in hybrid system)
        info.lastClaimMonth += claimableMonths;

        // Hybrid system: Record claimed interest as user debt (reduces redemption value)
        _userClaimedInterest[msg.sender] += interestAmount;
        totalClaimedInterest += interestAmount;

        // Also update totalInterestPaid for accounting purposes
        totalInterestPaid += interestAmount;

        // Transfer USDC (no share burn in hybrid system)
        IERC20(asset()).safeTransfer(msg.sender, interestAmount);

        emit InterestClaimed(msg.sender, interestAmount, info.lastClaimMonth);
    }

    /// @notice Claim interest for a single month only
    /// @dev Claims exactly one month of interest, even if multiple months are claimable
    ///      Use this for more granular control over interest claims
    function claimSingleMonth() external nonReentrant whenNotPaused {
        if (currentPhase == Phase.Collecting) revert RWAErrors.InvalidPhase();

        DepositInfo storage info = _depositInfos[msg.sender];
        if (info.shares == 0) revert RWAErrors.ZeroAmount();

        uint256 claimableMonths = _getClaimableMonths(msg.sender);
        if (claimableMonths == 0) revert RWAErrors.ZeroAmount();

        // Calculate interest for exactly ONE month
        uint256 monthlyInterest = _calculateMonthlyInterest(info.principal);
        uint256 interestAmount = monthlyInterest; // Just 1 month

        // Check vault has sufficient liquidity
        uint256 availableBalance = IERC20(asset()).balanceOf(address(this));
        if (interestAmount > availableBalance) revert RWAErrors.InsufficientLiquidity();

        // Update user's last claim month (only 1 month, shares stay the same)
        info.lastClaimMonth += 1;

        // Hybrid system: Record claimed interest as user debt (reduces redemption value)
        _userClaimedInterest[msg.sender] += interestAmount;
        totalClaimedInterest += interestAmount;

        // Also update totalInterestPaid for accounting purposes
        totalInterestPaid += interestAmount;

        // Transfer USDC (no share burn in hybrid system)
        IERC20(asset()).safeTransfer(msg.sender, interestAmount);

        emit InterestClaimed(msg.sender, interestAmount, info.lastClaimMonth);
    }

    /// @notice Get claimable months for a user
    function getClaimableMonths(address user) external view returns (uint256) {
        return _getClaimableMonths(user);
    }

    /// @notice Get pending interest for a user
    function getPendingInterest(address user) public view returns (uint256) {
        DepositInfo storage info = _depositInfos[user];
        if (info.shares == 0) return 0;

        uint256 claimableMonths = _getClaimableMonths(user);
        if (claimableMonths == 0) return 0;

        // Calculate interest based on principal
        return _calculateMonthlyInterest(info.principal) * claimableMonths;
    }

    /// @notice Get user deposit info (extended version)
    function getDepositInfo(address user) external view returns (
        uint256 shares,
        uint256 principal,
        uint256 lastClaimMonth,
        uint256 depositTime
    ) {
        DepositInfo storage info = _depositInfos[user];
        return (info.shares, info.principal, info.lastClaimMonth, info.depositTime);
    }

    // ============ Internal Interest Functions ============

    function _getClaimableMonths(address user) internal view returns (uint256) {
        DepositInfo storage info = _depositInfos[user];
        if (info.shares == 0) return 0;

        uint256 totalMonths = interestPaymentDates.length;
        if (totalMonths == 0) return 0;

        // Determine the reference time for calculating elapsed months
        // In Defaulted phase, cap at defaultTime to match accrued interest calculation
        uint256 checkTime = block.timestamp;
        if (currentPhase == Phase.Defaulted && defaultTime > 0) {
            checkTime = defaultTime;
        }

        // Calculate number of months payable up to check time
        uint256 elapsedMonths = 0;
        for (uint256 i = 0; i < totalMonths;) {
            if (checkTime >= interestPaymentDates[i]) {
                elapsedMonths = i + 1;
            } else {
                break;
            }
            unchecked { ++i; }
        }

        if (elapsedMonths <= info.lastClaimMonth) return 0;

        return elapsedMonths - info.lastClaimMonth;
    }

    /// @notice Calculate monthly interest based on principal and fixed APY
    function _calculateMonthlyInterest(uint256 principal) internal view returns (uint256) {
        return (principal * fixedAPY) / (RWAConstants.MONTHS_PER_YEAR * RWAConstants.BASIS_POINTS);
    }

    /// @notice Claim remaining interest for a user (called internally before withdrawal)
    /// @dev Uses fair share calculation same as claimInterest()
    function _claimRemainingInterest(address user) internal {
        uint256 claimableMonths = _getClaimableMonths(user);
        if (claimableMonths == 0) return;

        DepositInfo storage info = _depositInfos[user];
        uint256 monthlyInterest = _calculateMonthlyInterest(info.principal);
        uint256 interestAmount = monthlyInterest * claimableMonths;

        // Check vault has sufficient liquidity
        uint256 availableBalance = IERC20(asset()).balanceOf(address(this));
        if (interestAmount > availableBalance) revert RWAErrors.InsufficientLiquidity();

        // Update last claim month (shares stay the same in hybrid system)
        info.lastClaimMonth += claimableMonths;

        // Hybrid system: Record claimed interest as user debt
        _userClaimedInterest[user] += interestAmount;
        totalClaimedInterest += interestAmount;
        totalInterestPaid += interestAmount;

        // Transfer interest (no share burn in hybrid system)
        IERC20(asset()).safeTransfer(user, interestAmount);

        emit InterestClaimed(user, interestAmount, info.lastClaimMonth);
    }

    // ============ Transfer Hook ============

    /// @notice Override _update to transfer principal info with shares (for secondary market)
    /// @dev Called on all token transfers including mint, burn, and transfer
    /// @dev Enforces minimum transfer amount to prevent dust/rounding issues
    function _update(address from, address to, uint256 amount) internal override {
        // For user-to-user transfers, enforce minimum amount to prevent rounding errors
        if (from != address(0) && to != address(0)) {
            if (amount < RWAConstants.MIN_SHARE_TRANSFER) revert RWAErrors.TransferTooSmall();

            // [H-02 FIX] Prevent dust remaining after transfer
            uint256 senderBalance = balanceOf(from);
            uint256 remainingBalance = senderBalance - amount;
            if (remainingBalance > 0 && remainingBalance < RWAConstants.MIN_SHARE_TRANSFER) {
                revert RWAErrors.TransferLeavesTooDust();
            }
        }

        // Store original shares before super._update changes balances
        uint256 fromOriginalShares = from != address(0) ? balanceOf(from) : 0;

        super._update(from, to, amount);

        // Skip if mint (from == address(0)) or burn (to == address(0))
        // Principal info is handled separately for those cases
        if (from == address(0) || to == address(0)) {
            return;
        }

        // This is a user-to-user transfer
        // Transfer proportional principal info and debt from sender to receiver
        DepositInfo storage fromInfo = _depositInfos[from];
        DepositInfo storage toInfo = _depositInfos[to];

        if (fromOriginalShares == 0 || fromInfo.principal == 0) {
            return;
        }

        // Calculate the ratio of shares being transferred
        // Use fromOriginalShares (before transfer) for accurate ratio
        uint256 ratio = (amount * RWAConstants.PRECISION) / fromOriginalShares;

        // Calculate principal to transfer
        uint256 principalToTransfer = (fromInfo.principal * ratio) / RWAConstants.PRECISION;

        // Hybrid system: Calculate debt to transfer
        uint256 debtToTransfer = (_userClaimedInterest[from] * ratio) / RWAConstants.PRECISION;

        // Update principal tracking
        fromInfo.principal -= principalToTransfer;
        fromInfo.shares = balanceOf(from); // Sync with actual balance
        toInfo.principal += principalToTransfer;
        toInfo.shares = balanceOf(to); // Sync with actual balance

        // Transfer debt (claimed interest obligation)
        if (debtToTransfer > 0) {
            _userClaimedInterest[from] -= debtToTransfer;
            _userClaimedInterest[to] += debtToTransfer;
        }

        // Transfer lastClaimMonth info (receiver inherits sender's claim status)
        // This ensures receiver can't double-claim already-claimed months
        if (toInfo.lastClaimMonth < fromInfo.lastClaimMonth) {
            toInfo.lastClaimMonth = fromInfo.lastClaimMonth;
        }

        emit PrincipalTransferred(from, to, principalToTransfer, amount);
    }

    // ============ Phase Management ============

    /// @notice Transition to Active phase
    function activateVault() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (currentPhase != Phase.Collecting) revert RWAErrors.InvalidPhase();
        if (block.timestamp < collectionEndTime) revert RWAErrors.CollectionNotEnded();
        if (interestPeriodEndDates.length == 0) revert RWAErrors.PeriodEndDatesNotSet();
        if (interestPaymentDates.length == 0) revert RWAErrors.PaymentDatesNotSet();
        if (interestPeriodEndDates.length != interestPaymentDates.length) {
            revert RWAErrors.ArrayLengthMismatch();
        }

        Phase oldPhase = currentPhase;
        currentPhase = Phase.Active;

        emit PhaseChanged(oldPhase, Phase.Active);
    }

    /// @notice Transition to Matured phase
    function matureVault() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (currentPhase != Phase.Active) revert RWAErrors.InvalidPhase();
        if (block.timestamp < _getMaturityTime()) revert RWAErrors.NotMatured();

        Phase oldPhase = currentPhase;
        currentPhase = Phase.Matured;

        emit PhaseChanged(oldPhase, Phase.Matured);
    }

    /// @notice Trigger vault default (early termination due to FX loss or other reasons)
    /// @dev Admin manually triggers when conditions warrant early termination
    function triggerDefault() external onlyPoolManager {
        if (currentPhase != Phase.Active) revert RWAErrors.InvalidPhase();

        Phase oldPhase = currentPhase;
        currentPhase = Phase.Defaulted;
        defaultTime = block.timestamp;

        emit PhaseChanged(oldPhase, Phase.Defaulted);
        emit VaultDefaulted(defaultTime);
    }

    /// @notice Update interest start time (only before Active phase)
    /// @dev After changing this, you must call setInterestPeriodEndDates() with updated dates
    function setInterestStartTime(uint256 newTime) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (currentPhase != Phase.Collecting) revert RWAErrors.InvalidPhase();
        if (newTime < collectionEndTime) revert RWAErrors.InvalidAmount();

        interestStartTime = newTime;
    }

    // ============ Pool Manager Functions ============

    // ============ Deployment Timelock Functions ============

    /// @notice Announces a capital deployment (starts timelock)
    /// @dev Must wait deploymentDelay before executing
    /// @dev Can be called anytime (including during collection phase)
    /// @param amount Amount to deploy
    /// @param recipient Recipient address
    function announceDeployCapital(uint256 amount, address recipient)
        external
        nonReentrant
        whenNotPaused
        onlyPoolManager
    {
        if (amount == 0) revert RWAErrors.ZeroAmount();
        if (recipient == address(0)) revert RWAErrors.ZeroAddress();
        if (pendingDeployment.active) revert RWAErrors.DeploymentAlreadyPending();

        uint256 currentBalance = IERC20(asset()).balanceOf(address(this));
        if (amount > currentBalance) revert RWAErrors.InsufficientLiquidity();

        uint256 executeTime = block.timestamp + deploymentDelay;
        uint256 deploymentId = deploymentIdCounter++;

        pendingDeployment = PendingDeployment({
            amount: amount,
            recipient: recipient,
            executeTime: executeTime,
            active: true
        });

        emit RWAEvents.DeploymentAnnounced(deploymentId, amount, recipient, executeTime);
    }

    /// @notice Executes a pending deployment after timelock expires
    /// @dev Can only be called after deploymentDelay has passed
    function executeDeployCapital() external nonReentrant whenNotPaused onlyPoolManager {
        if (!pendingDeployment.active) revert RWAErrors.NoPendingDeployment();
        if (block.timestamp < pendingDeployment.executeTime) revert RWAErrors.DeploymentNotReady();

        uint256 amount = pendingDeployment.amount;
        address recipient = pendingDeployment.recipient;

        // Re-check balance (could have changed since announcement)
        uint256 currentBalance = IERC20(asset()).balanceOf(address(this));
        if (amount > currentBalance) revert RWAErrors.InsufficientLiquidity();

        // Clear pending deployment
        uint256 deploymentId = deploymentIdCounter - 1;
        delete pendingDeployment;

        // Execute deployment
        totalDeployed += amount;

        // Record deployment in history
        deploymentHistory.push(DeploymentRecord({
            deployedUSD: amount,
            deploymentTime: block.timestamp,
            returnedUSD: 0,
            returnTime: 0,
            settled: false
        }));
        currentDeploymentIndex = deploymentHistory.length - 1;

        IERC20(asset()).safeTransfer(recipient, amount);

        emit RWAEvents.DeploymentExecuted(deploymentId, amount, recipient);
        emit CapitalDeployed(amount, recipient);
        emit DeploymentRecorded(currentDeploymentIndex, amount);
    }

    /// @notice Cancels a pending deployment
    /// @dev Can be called anytime before execution
    function cancelDeployCapital() external nonReentrant onlyPoolManager {
        if (!pendingDeployment.active) revert RWAErrors.NoPendingDeployment();

        uint256 deploymentId = deploymentIdCounter - 1;
        delete pendingDeployment;

        emit RWAEvents.DeploymentCancelled(deploymentId);
    }

    /// @notice Sets the deployment delay (admin only)
    /// @param newDelay New delay in seconds (minimum 1 hour, maximum 7 days)
    function setDeploymentDelay(uint256 newDelay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newDelay >= 1 hours, "Delay too short");
        require(newDelay <= 7 days, "Delay too long");
        uint256 oldDelay = deploymentDelay;
        deploymentDelay = newDelay;
        emit DeploymentDelayUpdated(oldDelay, newDelay);
    }

    /// @notice Gets the pending deployment details
    /// @return amount Amount to deploy
    /// @return recipient Recipient address
    /// @return executeTime Earliest execution time
    /// @return isPending Whether deployment is pending
    function getPendingDeployment() external view returns (
        uint256 amount,
        address recipient,
        uint256 executeTime,
        bool isPending
    ) {
        return (
            pendingDeployment.amount,
            pendingDeployment.recipient,
            pendingDeployment.executeTime,
            pendingDeployment.active
        );
    }

    /// @notice Returns capital from external deployment (called by PoolManager)
    /// @dev Supports partial returns - multiple calls allowed until fully returned
    /// @param amount Amount to return in USD
    function returnCapital(uint256 amount) external nonReentrant whenNotPaused onlyPoolManager {
        if (amount == 0) revert RWAErrors.ZeroAmount();
        if (amount > totalDeployed) revert RWAErrors.InvalidAmount();

        totalDeployed -= amount;

        // Update current deployment record if exists
        if (deploymentHistory.length > 0) {
            DeploymentRecord storage record = deploymentHistory[currentDeploymentIndex];
            if (!record.settled) {
                record.returnedUSD += amount;  // Accumulate partial returns
                record.returnTime = block.timestamp;
                // Only mark as settled when fully returned
                if (record.returnedUSD >= record.deployedUSD) {
                    record.settled = true;
                }
                emit ReturnRecorded(currentDeploymentIndex, amount);
            }
        }

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);

        emit CapitalReturned(amount, msg.sender);
    }

    /// @notice Deposit interest earnings into vault
    function depositInterest(uint256 amount) external nonReentrant whenNotPaused onlyPoolManager {
        if (amount == 0) revert RWAErrors.ZeroAmount();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);

        emit InterestDeposited(amount);
    }

    // ============ Admin Functions ============

    /// @notice Set interest period end dates (actual end date of each interest period)
    /// @param periodEndDates Array of timestamps for each month's interest period end
    function setInterestPeriodEndDates(uint256[] calldata periodEndDates) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (currentPhase != Phase.Collecting) revert RWAErrors.InvalidPhase();
        if (periodEndDates.length == 0) revert RWAErrors.ZeroAmount();
        if (periodEndDates.length > RWAConstants.MAX_PAYMENT_PERIODS) revert RWAErrors.ArrayTooLong();

        // Verify period end dates are in order and after interestStartTime
        uint256 len = periodEndDates.length;
        if (periodEndDates[0] <= interestStartTime) revert RWAErrors.InvalidAmount();
        for (uint256 i = 1; i < len;) {
            if (periodEndDates[i] <= periodEndDates[i - 1]) revert RWAErrors.InvalidAmount();
            unchecked { ++i; }
        }

        delete interestPeriodEndDates;
        for (uint256 i = 0; i < len;) {
            interestPeriodEndDates.push(periodEndDates[i]);
            unchecked { ++i; }
        }

        emit InterestPeriodEndDatesSet(periodEndDates.length);
    }

    /// @notice Set interest payment dates (when each month's interest becomes claimable)
    /// @param paymentDates Array of timestamps for each month's interest payment
    function setInterestPaymentDates(uint256[] calldata paymentDates) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (currentPhase != Phase.Collecting) revert RWAErrors.InvalidPhase();
        if (paymentDates.length == 0) revert RWAErrors.ZeroAmount();
        if (paymentDates.length > RWAConstants.MAX_PAYMENT_PERIODS) revert RWAErrors.ArrayTooLong();

        // Verify payment dates are in order
        uint256 len = paymentDates.length;
        for (uint256 i = 1; i < len;) {
            if (paymentDates[i] <= paymentDates[i - 1]) revert RWAErrors.InvalidAmount();
            unchecked { ++i; }
        }

        // Verify first payment date is after interestStartTime
        if (paymentDates[0] < interestStartTime) revert RWAErrors.InvalidAmount();

        delete interestPaymentDates;
        for (uint256 i = 0; i < len;) {
            interestPaymentDates.push(paymentDates[i]);
            unchecked { ++i; }
        }

        emit InterestPaymentDatesSet(paymentDates.length);
    }

    /// @notice Set a specific month's interest payment date
    /// @param month Month number (1-indexed)
    /// @param newDate New timestamp for the payment date
    function setInterestPaymentDateForMonth(uint256 month, uint256 newDate)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        // Month is 1-indexed, validate range
        if (month == 0 || month > interestPaymentDates.length) revert RWAErrors.InvalidAmount();

        // Month 1 must be >= interestStartTime
        if (month == 1 && newDate < interestStartTime) revert RWAErrors.InvalidAmount();

        // Must be greater than previous month's date
        if (month > 1 && newDate <= interestPaymentDates[month - 2]) revert RWAErrors.InvalidAmount();

        // Must be less than next month's date
        if (month < interestPaymentDates.length && newDate >= interestPaymentDates[month]) revert RWAErrors.InvalidAmount();

        interestPaymentDates[month - 1] = newDate;

        emit InterestPaymentDateUpdated(month, newDate);
    }

    /// @notice Set withdrawal start time (actual principal withdrawal start time)
    /// @dev Can be different from maturityTime due to bank processing delays
    /// @param startTime Timestamp when withdrawal becomes available
    function setWithdrawalStartTime(uint256 startTime) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Must be after maturityTime
        if (startTime < _getMaturityTime()) revert RWAErrors.InvalidAmount();

        withdrawalStartTime = startTime;

        emit WithdrawalStartTimeSet(startTime);
    }

    // ============ Whitelist Functions ============

    /// @notice Enable or disable whitelist
    /// @param enabled True to enable whitelist, false to disable
    function setWhitelistEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        whitelistEnabled = enabled;
        emit WhitelistEnabledSet(enabled);
    }

    /// @notice Add addresses to whitelist
    /// @param users Array of addresses to whitelist
    function addToWhitelist(address[] calldata users) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 len = users.length;
        if (len > RWAConstants.MAX_WHITELIST_BATCH) revert RWAErrors.ArrayTooLong();
        for (uint256 i = 0; i < len;) {
            _whitelist[users[i]] = true;
            unchecked { ++i; }
        }
        emit WhitelistUpdated(users, true);
    }

    /// @notice Remove addresses from whitelist
    /// @param users Array of addresses to remove
    function removeFromWhitelist(address[] calldata users) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 len = users.length;
        if (len > RWAConstants.MAX_WHITELIST_BATCH) revert RWAErrors.ArrayTooLong();
        for (uint256 i = 0; i < len;) {
            _whitelist[users[i]] = false;
            unchecked { ++i; }
        }
        emit WhitelistUpdated(users, false);
    }

    /// @notice Check if an address is whitelisted
    /// @param user Address to check
    function isWhitelisted(address user) external view returns (bool) {
        return _whitelist[user];
    }

    // ============ Cap Allocation Functions ============

    /// @notice Allocate cap to a specific address (bypasses whitelist and min/max checks)
    /// @param user Address to allocate cap to
    /// @param amount Amount to allocate (0 to remove allocation)
    function allocateCap(address user, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (user == address(0)) revert RWAErrors.ZeroAddress();

        uint256 currentAllocation = _allocatedCap[user];

        // Update total allocated
        totalAllocated = totalAllocated - currentAllocation + amount;

        // Check total allocated doesn't exceed maxCapacity
        if (totalAllocated > maxCapacity) revert RWAErrors.VaultCapacityExceeded();

        _allocatedCap[user] = amount;

        emit CapAllocated(user, amount);
    }

    /// @notice Batch allocate caps to multiple addresses
    /// @param users Array of addresses to allocate to
    /// @param amounts Array of amounts to allocate
    function batchAllocateCap(address[] calldata users, uint256[] calldata amounts) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 len = users.length;
        if (len != amounts.length) revert RWAErrors.InvalidAmount();
        if (len > RWAConstants.MAX_WHITELIST_BATCH) revert RWAErrors.ArrayTooLong();

        for (uint256 i = 0; i < len;) {
            if (users[i] == address(0)) revert RWAErrors.ZeroAddress();

            uint256 currentAllocation = _allocatedCap[users[i]];
            totalAllocated = totalAllocated - currentAllocation + amounts[i];

            _allocatedCap[users[i]] = amounts[i];

            emit CapAllocated(users[i], amounts[i]);
            unchecked { ++i; }
        }

        // Check total allocated doesn't exceed maxCapacity
        if (totalAllocated > maxCapacity) revert RWAErrors.VaultCapacityExceeded();
    }

    /// @notice Get allocated cap for an address
    /// @param user Address to check
    /// @return Allocated cap amount (0 if none)
    function getAllocatedCap(address user) external view returns (uint256) {
        return _allocatedCap[user];
    }

    /// @notice Get available public capacity (maxCapacity - totalAllocated)
    /// @return Available capacity for non-allocated users
    function getPublicCapacity() external view returns (uint256) {
        if (totalAllocated >= maxCapacity) return 0;
        return maxCapacity - totalAllocated;
    }

    /// @notice Get remaining allocation for a user (allocated - already deposited)
    /// @param user Address to check
    /// @return Remaining allocation amount
    function getRemainingAllocation(address user) external view returns (uint256) {
        uint256 allocated = _allocatedCap[user];
        if (allocated == 0) return 0;

        uint256 deposited = _depositInfos[user].principal;
        if (deposited >= allocated) return 0;

        return allocated - deposited;
    }

    // ============ Per-User Deposit Cap Functions ============

    /// @notice Set per-user deposit caps
    /// @param minPerUser Minimum deposit per user (0 = no minimum)
    /// @param maxPerUser Maximum deposit per user (0 = no maximum)
    function setUserDepositCaps(uint256 minPerUser, uint256 maxPerUser) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Validate: if both are set, max must be >= min
        if (minPerUser > 0 && maxPerUser > 0 && maxPerUser < minPerUser) {
            revert RWAErrors.InvalidAmount();
        }

        minDepositPerUser = minPerUser;
        maxDepositPerUser = maxPerUser;

        emit UserDepositCapsSet(minPerUser, maxPerUser);
    }

    // ============ Other Admin Functions ============

    /// @notice Sets the vault active status
    function setActive(bool active_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        active = active_;
    }

    /// @notice Pauses the vault
    function pause() external onlyRole(RWAConstants.PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpauses the vault
    function unpause() external onlyRole(RWAConstants.PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Recovers accidentally sent ERC20 tokens (not the vault asset)
    /// @dev Only admin can call. Cannot recover the vault's underlying asset (USDC)
    /// @param token The token address to recover
    /// @param amount The amount to recover
    function recoverERC20(address token, uint256 amount, address recipient) external onlyPoolManager {
        if (token == asset()) revert RWAErrors.InvalidAmount();
        if (amount == 0) revert RWAErrors.ZeroAmount();
        if (recipient == address(0)) revert RWAErrors.ZeroAddress();

        IERC20(token).safeTransfer(recipient, amount);

        emit RWAEvents.TokenRecovered(token, recipient, amount);
    }

    /// @notice Recovers remaining asset (USDC) dust after all shares are burned
    /// @dev Only callable when totalSupply() == 0 (vault is fully emptied)
    /// @param recipient The address to receive the dust
    function recoverAssetDust(address recipient) external onlyPoolManager {
        if (totalSupply() > 0) revert RWAErrors.InvalidPhase();
        if (recipient == address(0)) revert RWAErrors.ZeroAddress();

        uint256 dust = IERC20(asset()).balanceOf(address(this));
        if (dust == 0) revert RWAErrors.ZeroAmount();

        IERC20(asset()).safeTransfer(recipient, dust);

        emit RWAEvents.TokenRecovered(asset(), recipient, dust);
    }

    /// @notice Recovers unclaimed funds after grace period (30 days from withdrawal start)
    /// @dev Only callable after withdrawalStartTime + 30 days
    /// @param recipient The address to receive the unclaimed funds
    function recoverUnclaimedFunds(address recipient) external onlyPoolManager {
        if (recipient == address(0)) revert RWAErrors.ZeroAddress();
        if (withdrawalStartTime == 0) revert RWAErrors.WithdrawalNotAvailable();
        if (block.timestamp < withdrawalStartTime + 30 days) revert RWAErrors.TooEarly();

        uint256 balance = IERC20(asset()).balanceOf(address(this));
        if (balance == 0) revert RWAErrors.ZeroAmount();

        IERC20(asset()).safeTransfer(recipient, balance);

        emit UnclaimedFundsRecovered(recipient, balance);
    }

    /// @notice Recovers ETH accidentally sent to the vault
    /// @dev Vault should never hold ETH, so this can be called anytime
    /// @param recipient The address to receive the ETH
    function recoverETH(address payable recipient) external onlyPoolManager {
        if (recipient == address(0)) revert RWAErrors.ZeroAddress();

        uint256 balance = address(this).balance;
        if (balance == 0) revert RWAErrors.ZeroAmount();

        (bool success, ) = recipient.call{value: balance}("");
        require(success, "ETH transfer failed");

        emit ETHRecovered(recipient, balance);
    }

    // ============ View Functions ============

    /// @notice Returns available liquidity
    function availableLiquidity() external view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice Checks if vault is active
    function isActive() external view returns (bool) {
        return active;
    }

    /// @notice Get vault status
    function getVaultStatus() external view returns (
        Phase phase,
        uint256 totalAssets_,
        uint256 totalDeployed_,
        uint256 availableBalance,
        uint256 totalInterestPaid_
    ) {
        return (
            currentPhase,
            totalAssets(),
            totalDeployed,
            IERC20(asset()).balanceOf(address(this)),
            totalInterestPaid
        );
    }

    /// @notice Get vault configuration
    function getVaultConfig() external view returns (
        uint256 collectionEndTime_,
        uint256 interestStartTime_,
        uint256 maturityTime_,
        uint256 termDuration_,
        uint256 fixedAPY_,
        uint256 minDeposit_,
        uint256 maxCapacity_
    ) {
        return (
            collectionEndTime,
            interestStartTime,
            maturityTime(),
            termDuration,
            fixedAPY,
            minDeposit,
            maxCapacity
        );
    }

    /// @notice Get extended vault info
    function getExtendedInfo() external view returns (
        uint256 totalPrincipal_,
        uint256 deploymentCount
    ) {
        return (
            totalPrincipal,
            deploymentHistory.length
        );
    }

    /// @notice Get deployment record by index
    function getDeploymentRecord(uint256 index) external view returns (DeploymentRecord memory) {
        if (index >= deploymentHistory.length) revert RWAErrors.InvalidAmount();
        return deploymentHistory[index];
    }

    /// @notice Get all interest payment dates
    /// @notice Get all interest period end dates
    function getInterestPeriodEndDates() external view returns (uint256[] memory) {
        return interestPeriodEndDates;
    }

    /// @notice Get all interest payment dates
    function getInterestPaymentDates() external view returns (uint256[] memory) {
        return interestPaymentDates;
    }

    /// @notice Get total number of interest payment months
    function getTotalInterestMonths() external view returns (uint256) {
        return interestPaymentDates.length;
    }

    // ============ Events ============

    event LossRecorded(uint256 amount);
    event DeploymentRecorded(uint256 indexed index, uint256 amount);
    event ReturnRecorded(uint256 indexed index, uint256 amount);
    event InterestPeriodEndDatesSet(uint256 monthCount);
    event InterestPaymentDatesSet(uint256 monthCount);
    event InterestPaymentDateUpdated(uint256 indexed month, uint256 newDate);
    event WithdrawalStartTimeSet(uint256 startTime);
    event PrincipalTransferred(address indexed from, address indexed to, uint256 principal, uint256 shares);
    event WhitelistEnabledSet(bool enabled);
    event WhitelistUpdated(address[] users, bool added);
    event UserDepositCapsSet(uint256 minPerUser, uint256 maxPerUser);
    event CapAllocated(address indexed user, uint256 amount);
    event ETHRecovered(address indexed recipient, uint256 amount);
    event DeploymentDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event UnclaimedFundsRecovered(address indexed recipient, uint256 amount);
}
