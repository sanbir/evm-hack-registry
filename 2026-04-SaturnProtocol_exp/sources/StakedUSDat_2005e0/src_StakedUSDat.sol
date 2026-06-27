// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {IWithdrawalQueueERC721} from "./interfaces/IWithdrawalQueueERC721.sol";
import {IStrcPriceOracle} from "./interfaces/IStrcPriceOracle.sol";
import {IStakedUSDat} from "./interfaces/IStakedUSDat.sol";
import {IERC20PermitExtended} from "./interfaces/IERC20PermitExtended.sol";

/**
 * @title StakedUSDat
 * @author Saturn
 * @notice Implementation of the IStakedUSDat interface.
 * @dev See {IStakedUSDat} for full documentation.
 */
contract StakedUSDat is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuard,
    ERC20PermitUpgradeable,
    ERC4626Upgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    IStakedUSDat
{
    using SafeERC20 for IERC20;

    /// @notice Role identifier for the processor
    bytes32 public constant PROCESSOR_ROLE = keccak256("PROCESSOR_ROLE");

    /// @notice Role identifier for compliance operations
    bytes32 private constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    /// @dev The STRC price oracle contract (immutable, stored in implementation bytecode)
    IStrcPriceOracle private immutable STRC_ORACLE;

    /// @dev The WithdrawalQueue contract (immutable, stored in implementation bytecode)
    IWithdrawalQueueERC721 private immutable WITHDRAWAL_QUEUE;

    /// @dev Mapping of blacklisted addresses
    mapping(address account => bool isBlacklisted) private _blacklisted;

    /// @notice Amount of tSTRC currently vesting
    uint256 public vestingAmount;

    /// @notice Timestamp of last reward distribution
    uint256 public lastDistributionTimestamp;

    /// @notice Vesting period duration in seconds
    uint256 public vestingPeriod;

    /// @notice Maximum allowed vesting period (90 days)
    uint256 public constant MAX_VESTING_PERIOD = 90 days;

    /// @notice Minimum withdrawal amount (10 USDat, 6 decimals)
    uint256 public constant MIN_WITHDRAWAL = 10e6;

    /// @notice Tolerance in basis points for validation
    uint256 public toleranceBps;

    /// @notice Maximum tolerance (100%)
    uint256 public constant MAX_TOLERANCE_BPS = 10000;

    /// @notice Minimum tolerance (1%)
    uint256 public constant MIN_TOLERANCE_BPS = 100;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Maximum deposit fee (5%)
    uint256 public constant MAX_DEPOSIT_FEE_BPS = 500;

    /// @notice Deposit fee in basis points
    uint256 public depositFeeBps;

    /// @notice Address that receives deposit fees
    address public feeRecipient;

    /// @notice Internally tracked USDat balance (6 decimals)
    uint256 public usdatBalance;

    /// @notice Internally tracked STRC balance (6 decimals, matches USDat)
    uint256 public strcBalance;

    /// @notice Maximum rewards per transfer in basis points of totalAssets. Used to validate transferInRewards
    uint256 public maxRewardsBps;

    modifier notZero(uint256 amount) {
        _notZero(amount);
        _;
    }

    /// @dev Reverts if the given amount is zero.
    function _notZero(uint256 amount) internal pure {
        require(amount != 0, ZeroAmount());
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(IStrcPriceOracle strcOracle, IWithdrawalQueueERC721 withdrawalQueue) {
        require(address(strcOracle) != address(0) && address(withdrawalQueue) != address(0), InvalidZeroAddress());
        STRC_ORACLE = strcOracle;
        WITHDRAWAL_QUEUE = withdrawalQueue;
        _disableInitializers();
    }

    /// @notice Initializes the contract (called once via proxy)
    /// @param defaultAdmin The default admin of the contract
    /// @param processor The address of the processor
    /// @param compliance The address of the compliance role
    /// @param depositFeeRecipient The address that receives deposit fees
    /// @param usdat USDat contract address
    function initialize(
        address defaultAdmin,
        address processor,
        address compliance,
        address depositFeeRecipient,
        IERC20 usdat
    ) external initializer {
        require(
            defaultAdmin != address(0) && address(usdat) != address(0) && processor != address(0)
                && compliance != address(0),
            InvalidZeroAddress()
        );

        __AccessControl_init();
        __Pausable_init();
        __ERC20_init("Staked USDat", "sUSDat");
        __ERC20Permit_init("Staked USDat");
        __ERC4626_init(usdat);

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(PROCESSOR_ROLE, processor);
        _grantRole(COMPLIANCE_ROLE, compliance);

        vestingPeriod = 30 days;
        depositFeeBps = 10;
        feeRecipient = depositFeeRecipient;
        toleranceBps = 2000;
        maxRewardsBps = 250; // 2.5% of totalAssets
    }

    /// @dev Authorizes an upgrade to a new implementation. Only callable by DEFAULT_ADMIN_ROLE.
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ============ Blacklist Functions ============

    /// @inheritdoc IStakedUSDat
    function addToBlacklist(address target) external onlyRole(COMPLIANCE_ROLE) {
        require(!hasRole(DEFAULT_ADMIN_ROLE, target), CannotBlacklistAdmin());
        require(!_blacklisted[target], AddressBlacklisted());
        _blacklisted[target] = true;
        emit Blacklisted(target);
    }

    /// @inheritdoc IStakedUSDat
    function removeFromBlacklist(address target) external onlyRole(COMPLIANCE_ROLE) {
        require(_blacklisted[target], AddressNotBlacklisted());
        _blacklisted[target] = false;
        emit UnBlacklisted(target);
    }

    /// @dev Reverts if the given account is blacklisted.
    function _requireNotBlacklisted(address account) internal view {
        require(!_blacklisted[account], AddressBlacklisted());
    }

    /// @inheritdoc IStakedUSDat
    function isBlacklisted(address account) external view returns (bool) {
        return _blacklisted[account];
    }

    /// @inheritdoc IERC20
    function transfer(address to, uint256 amount) public override(ERC20Upgradeable, IERC20) returns (bool) {
        _requireNotBlacklisted(msg.sender);
        _requireNotBlacklisted(to);
        return super.transfer(to, amount);
    }

    /// @inheritdoc IERC20
    function transferFrom(address from, address to, uint256 amount)
        public
        override(ERC20Upgradeable, IERC20)
        returns (bool)
    {
        _requireNotBlacklisted(from);
        _requireNotBlacklisted(to);
        return super.transferFrom(from, to, amount);
    }

    /// @inheritdoc IStakedUSDat
    function redistributeLockedAmount(address from) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_blacklisted[from], AddressNotBlacklisted());
        uint256 amountToDistribute = balanceOf(from);

        require(amountToDistribute > 0, ZeroAmount());
        require(totalSupply() > amountToDistribute, NoRecipientsForRedistribution());

        bool wasPaused = paused();
        if (wasPaused) _unpause();
        _burn(from, amountToDistribute);
        if (wasPaused) _pause();

        emit LockedAmountRedistributed(from, amountToDistribute);
    }

    // ============ ERC4626 Overrides ============

    /// @inheritdoc IERC4626
    /// @dev Includes both USDat balance and vested tSTRC value.
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return usdatBalance + _strcTotalAssets();
    }

    /// @inheritdoc IStakedUSDat
    function getUnvestedAmount() public view returns (uint256) {
        uint256 timeSinceLastDistribution = block.timestamp - lastDistributionTimestamp;

        if (timeSinceLastDistribution >= vestingPeriod) {
            return 0;
        }

        return Math.mulDiv(vestingPeriod - timeSinceLastDistribution, vestingAmount, vestingPeriod, Math.Rounding.Ceil);
    }

    /// @dev Calculates the total value of vested STRC holdings in USD terms (6 decimals).
    function _strcTotalAssets() internal view returns (uint256) {
        (uint256 strcPrice, uint8 priceDecimals) = STRC_ORACLE.getPrice();

        uint256 vestedBalance = strcBalance - getUnvestedAmount();

        return Math.mulDiv(vestedBalance, strcPrice, 10 ** priceDecimals, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC20Metadata
    function decimals() public pure override(ERC4626Upgradeable, ERC20Upgradeable, IERC20Metadata) returns (uint8) {
        return 18;
    }

    /// @dev Returns a non-zero offset to protect against ERC4626 inflation attacks.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 12;
    }

    /// @inheritdoc IERC4626
    /// @dev Accounts for deposit fees when calculating shares.
    function previewDeposit(uint256 assets) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (depositFeeBps == 0 || feeRecipient == address(0)) {
            return super.previewDeposit(assets);
        }
        uint256 fee = Math.mulDiv(assets, depositFeeBps, BPS_DENOMINATOR, Math.Rounding.Ceil);
        return super.previewDeposit(assets - fee);
    }

    /// @inheritdoc IERC4626
    /// @dev Accounts for deposit fees when calculating required assets.
    function previewMint(uint256 shares) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (depositFeeBps == 0 || feeRecipient == address(0)) {
            return super.previewMint(shares);
        }
        uint256 assets = super.previewMint(shares);
        return Math.mulDiv(assets, BPS_DENOMINATOR, BPS_DENOMINATOR - depositFeeBps, Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC4626
    /// @dev Returns 0 when paused per ERC4626 spec.
    function maxDeposit(address) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    /// @inheritdoc IERC4626
    /// @dev Returns 0 when paused per ERC4626 spec.
    function maxMint(address) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    /// @inheritdoc IERC4626
    /// @dev Always returns 0 - use requestRedeem instead.
    function maxWithdraw(address) public pure override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return 0;
    }

    /// @inheritdoc IERC4626
    /// @dev Returns 0 when paused per ERC4626 spec.
    function maxRedeem(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return paused() ? 0 : balanceOf(owner);
    }

    // ============ Asset Management Functions ============

    /// @inheritdoc IStakedUSDat
    function rescueTokens(address token, uint256 amount, address to)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (token == asset()) {
            uint256 excessBalance = IERC20(token).balanceOf(address(this)) - usdatBalance;
            require(amount <= excessBalance, InsufficientBalance());
        }

        IERC20(token).safeTransfer(to, amount);
    }

    /// @dev Checks if a value is within ±toleranceBps of an expected value.
    function _isWithinTolerance(uint256 value, uint256 expected) internal view returns (bool) {
        uint256 minExpected = Math.mulDiv(expected, BPS_DENOMINATOR - toleranceBps, BPS_DENOMINATOR);
        uint256 maxExpected = Math.mulDiv(expected, BPS_DENOMINATOR + toleranceBps, BPS_DENOMINATOR);
        return value >= minExpected && value <= maxExpected;
    }

    /// @dev Validates that strcAmount matches usdatAmount / strcPurchasePrice within tolerance.
    function _validateConversion(uint256 usdatAmount, uint256 strcAmount, uint256 strcPurchasePrice) internal view {
        (uint256 oraclePrice, uint8 priceDecimals) = STRC_ORACLE.getPrice();

        uint256 expectedStrc = Math.mulDiv(usdatAmount, 10 ** priceDecimals, strcPurchasePrice);
        require(_isWithinTolerance(strcAmount, expectedStrc), ExecutionPriceMismatch());

        require(_isWithinTolerance(strcPurchasePrice, oraclePrice), OraclePriceMismatch());
    }

    /// @inheritdoc IStakedUSDat
    function convertFromUsdat(uint256 usdatAmount, uint256 strcAmount, uint256 strcPurchasePrice)
        external
        whenNotPaused
        onlyRole(PROCESSOR_ROLE)
    {
        require(usdatBalance >= usdatAmount, InsufficientBalance());

        _validateConversion(usdatAmount, strcAmount, strcPurchasePrice);

        usdatBalance -= usdatAmount;
        strcBalance += strcAmount;

        IERC20(asset()).safeTransfer(msg.sender, usdatAmount);

        emit Converted(usdatAmount, strcAmount);
    }

    /// @inheritdoc IStakedUSDat
    function convertFromStrc(uint256 strcAmount, uint256 usdatAmount, uint256 strcSalePrice)
        external
        whenNotPaused
        onlyRole(PROCESSOR_ROLE)
    {
        uint256 unvestedAmount = getUnvestedAmount();
        uint256 vestedBalance = strcBalance - unvestedAmount;
        require(strcAmount <= vestedBalance, InsufficientBalance());

        _validateConversion(usdatAmount, strcAmount, strcSalePrice);

        strcBalance -= strcAmount;
        usdatBalance += usdatAmount;

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), usdatAmount);

        emit Converted(usdatAmount, strcAmount);
    }

    /// @inheritdoc IStakedUSDat
    function transferInRewards(uint256 strcAmount) external nonReentrant onlyRole(PROCESSOR_ROLE) notZero(strcAmount) {
        require(getUnvestedAmount() == 0, StillVesting());

        uint256 maxRewards = Math.mulDiv(totalAssets(), maxRewardsBps, BPS_DENOMINATOR);

        (uint256 strcPrice, uint8 priceDecimals) = STRC_ORACLE.getPrice();
        uint256 strcAmountUsd = Math.mulDiv(strcAmount, strcPrice, 10 ** priceDecimals);

        require(strcAmountUsd <= maxRewards, RewardsExceedMax());

        strcBalance += strcAmount;

        vestingAmount = strcAmount;
        lastDistributionTimestamp = block.timestamp;

        emit RewardsReceived(strcAmount, strcAmount);
    }

    // ============ Deposit Functions ============

    /// @dev Deposit/mint common workflow with fee handling and blacklist checks.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
        notZero(assets)
        notZero(shares)
    {
        _requireNotBlacklisted(caller);
        _requireNotBlacklisted(receiver);

        uint256 fee = 0;
        if (depositFeeBps > 0 && feeRecipient != address(0)) {
            fee = Math.mulDiv(assets, depositFeeBps, BPS_DENOMINATOR, Math.Rounding.Ceil);
            IERC20(asset()).safeTransferFrom(caller, feeRecipient, fee);
        }

        uint256 netAssets = assets - fee;
        usdatBalance += netAssets;

        super._deposit(caller, receiver, netAssets, shares);
    }

    /// @inheritdoc IStakedUSDat
    function depositWithMinShares(uint256 assets, address receiver, uint256 minShares) public returns (uint256 shares) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }
        shares = previewDeposit(assets);
        require(shares >= minShares, SlippageExceeded());
        _deposit(msg.sender, receiver, assets, shares);
    }

    /// @inheritdoc IStakedUSDat
    function mintWithMaxAssets(uint256 shares, address receiver, uint256 maxAssets) public returns (uint256 assets) {
        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        }
        assets = previewMint(shares);
        require(assets <= maxAssets, SlippageExceeded());
        _deposit(msg.sender, receiver, assets, shares);
    }

    /// @inheritdoc IStakedUSDat
    /// @dev Uses try-catch to handle permit front-running gracefully. If permit fails
    /// (e.g., already used by front-runner), the deposit proceeds if allowance is sufficient.
    function depositWithPermit(
        uint256 assets,
        address receiver,
        uint256 minShares,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 shares) {
        try IERC20PermitExtended(asset()).permit(msg.sender, address(this), assets, deadline, v, r, s) {} catch {}

        return depositWithMinShares(assets, receiver, minShares);
    }

    /// @inheritdoc IStakedUSDat
    /// @dev Uses try-catch to handle permit front-running gracefully. If permit fails
    /// (e.g., already used by front-runner), the mint proceeds if allowance is sufficient.
    function mintWithPermit(
        uint256 shares,
        address receiver,
        uint256 maxAssets,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 assets) {
        try IERC20PermitExtended(asset()).permit(msg.sender, address(this), maxAssets, deadline, v, r, s) {} catch {}

        return mintWithMaxAssets(shares, receiver, maxAssets);
    }

    /// @inheritdoc IStakedUSDat
    /// @dev EIP-1271 compatible permit for smart contract wallets (e.g., Gnosis Safe, Argent).
    /// Uses try-catch to handle permit front-running gracefully.
    function depositWithPermit(
        uint256 assets,
        address receiver,
        uint256 minShares,
        uint256 deadline,
        bytes memory signature
    ) external returns (uint256 shares) {
        try IERC20PermitExtended(asset()).permit(msg.sender, address(this), assets, deadline, signature) {} catch {}

        return depositWithMinShares(assets, receiver, minShares);
    }

    /// @inheritdoc IStakedUSDat
    /// @dev EIP-1271 compatible permit for smart contract wallets (e.g., Gnosis Safe, Argent).
    /// Uses try-catch to handle permit front-running gracefully.
    function mintWithPermit(
        uint256 shares,
        address receiver,
        uint256 maxAssets,
        uint256 deadline,
        bytes memory signature
    ) external returns (uint256 assets) {
        try IERC20PermitExtended(asset()).permit(msg.sender, address(this), maxAssets, deadline, signature) {} catch {}

        return mintWithMaxAssets(shares, receiver, maxAssets);
    }

    /// @inheritdoc IERC4626
    /// @dev Disabled - use requestRedeem instead.
    function withdraw(uint256, address, address) public pure override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        revert OperationNotAllowed();
    }

    /// @inheritdoc IERC4626
    /// @dev Disabled - use requestRedeem instead.
    function redeem(uint256, address, address) public pure override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        revert OperationNotAllowed();
    }

    // ============ Withdrawal Functions ============

    /// @inheritdoc IStakedUSDat
    function requestRedeem(uint256 shares, uint256 minUsdatReceived) external returns (uint256 requestId) {
        uint256 maxShares = maxRedeem(msg.sender);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(msg.sender, shares, maxShares);
        }

        uint256 assets = previewRedeem(shares);

        requestId = _processWithdrawal(msg.sender, msg.sender, assets, shares, minUsdatReceived);
    }

    /// @dev Processes a withdrawal request by escrowing shares in the withdrawal queue.
    function _processWithdrawal(address caller, address owner, uint256 assets, uint256 shares, uint256 minUsdatReceived)
        internal
        nonReentrant
        notZero(assets)
        notZero(shares)
        returns (uint256 requestId)
    {
        _requireNotBlacklisted(caller);
        _requireNotBlacklisted(owner);
        require(assets >= MIN_WITHDRAWAL, WithdrawalTooSmall());

        _transfer(owner, address(WITHDRAWAL_QUEUE), shares);

        requestId = WITHDRAWAL_QUEUE.addRequest(owner, shares, minUsdatReceived);
    }

    /// @inheritdoc IStakedUSDat
    function claim() external returns (uint256 totalAmount) {
        return WITHDRAWAL_QUEUE.claimAllFor(msg.sender);
    }

    /// @inheritdoc IStakedUSDat
    function claimBatch(uint256[] calldata tokenIds) external returns (uint256 totalAmount) {
        return WITHDRAWAL_QUEUE.claimBatchFor(msg.sender, tokenIds);
    }

    /// @inheritdoc IStakedUSDat
    function burnQueuedShares(uint256 shares, uint256 strcAmount) external {
        require(msg.sender == address(WITHDRAWAL_QUEUE), OperationNotAllowed());
        strcBalance -= strcAmount;
        _burn(address(WITHDRAWAL_QUEUE), shares);
    }

    /// @inheritdoc IStakedUSDat
    function collectDust(uint256 amount) external {
        require(msg.sender == address(WITHDRAWAL_QUEUE), OperationNotAllowed());
        IERC20(asset()).safeTransferFrom(address(WITHDRAWAL_QUEUE), address(this), amount);
        usdatBalance += amount;
    }

    // ============ View Functions ============

    /// @inheritdoc IStakedUSDat
    function getWithdrawalQueue() external view returns (address) {
        return address(WITHDRAWAL_QUEUE);
    }

    /// @inheritdoc IStakedUSDat
    function getStrcOracle() external view returns (address) {
        return address(STRC_ORACLE);
    }

    // ============ Admin Functions ============

    /// @inheritdoc IStakedUSDat
    function setVestingPeriod(uint256 newVestingPeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newVestingPeriod > 0 && newVestingPeriod <= MAX_VESTING_PERIOD, InvalidVestingPeriod());
        require(getUnvestedAmount() == 0, StillVesting());

        uint256 oldPeriod = vestingPeriod;
        vestingPeriod = newVestingPeriod;
        vestingAmount = 0;

        emit VestingPeriodUpdated(oldPeriod, newVestingPeriod);
    }

    /// @inheritdoc IStakedUSDat
    function setDepositFee(uint256 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFeeBps <= MAX_DEPOSIT_FEE_BPS, InvalidFee());

        depositFeeBps = newFeeBps;

        emit DepositFeeUpdated(newFeeBps);
    }

    /// @inheritdoc IStakedUSDat
    function setFeeRecipient(address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        feeRecipient = newRecipient;

        emit FeeRecipientUpdated(newRecipient);
    }

    /// @inheritdoc IStakedUSDat
    function setTolerance(uint256 newToleranceBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newToleranceBps >= MIN_TOLERANCE_BPS && newToleranceBps <= MAX_TOLERANCE_BPS, InvalidFee());

        toleranceBps = newToleranceBps;

        emit ToleranceUpdated(newToleranceBps);
    }

    /// @inheritdoc IStakedUSDat
    function setMaxRewardsBps(uint256 newMaxBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newMaxBps > 0, InvalidFee());

        maxRewardsBps = newMaxBps;

        emit MaxRewardsBpsUpdated(newMaxBps);
    }

    /// @inheritdoc IStakedUSDat
    function pause() external onlyRole(COMPLIANCE_ROLE) {
        _pause();
    }

    /// @inheritdoc IStakedUSDat
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @dev Blocks all token movements when paused, except burns from blacklisted addresses by DEFAULT_ADMIN_ROLE.
    function _update(address from, address to, uint256 value) internal override(ERC20Upgradeable) whenNotPaused {
        super._update(from, to, value);
    }
}
