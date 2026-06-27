//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

/* solhint-disable ordering */

import { SafeERC20 } from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import {
    ERC20Upgradeable,
    IERC20,
    IERC20Metadata
} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { ERC20PermitUpgradeable } from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { ERC20PausableUpgradeable } from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { ERC4626Upgradeable } from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { IRegistryAccess } from "./interfaces/IRegistryAccess.sol";
import { IRegistryContract } from "./interfaces/IRegistryContract.sol";

using Math for uint256; // only used for `mulDiv` operations.
using SafeERC20 for IERC20; // `safeTransfer` and `safeTransferFrom`

import { IWrappedDollarVault } from "./interfaces/IWrappedDollarVault.sol";

import {
    INITIAL_SHARES_SUPPLY,
    ONE_DAY,
    ONE_WEEK,
    VAULT_DECIMALS,
    DEAD_ADDRESS,
    VAULT_PAUSER_ROLE,
    VAULT_UNPAUSER_ROLE,
    VAULT_SET_ROUTER_ROLE,
    VAULT_SET_FEE_ROLE,
    DEFAULT_FEE_RATE_BPS,
    MAX_FEE_RATE_BPS,
    BPS_DIVIDER,
    VAULT_HARVESTER_ROLE,
    CONTRACT_REGISTRY_ACCESS,
    CONTRACT_YIELD_TREASURY
} from "./constants.sol";

import {
    NullAddress,
    CallerNotAuthorizedRouter,
    ZeroAmount,
    SameRouterActivity,
    NotAuthorized,
    InvalidFeeRate,
    HarvestTooFrequent,
    FeeRateUpdateTooFrequent,
    SameFeeRate
} from "./errors.sol";

/// @title WrappedDollarVault
/// @notice A vault that holds another USD-denominated ERC4626 and allows users
/// to deposit and withdraw this token, with fees accrued in USD, and a
/// monotonic increase in USD value per share only, rather than a monotonic
/// increase in assets / share.  The price in units of asset decreases over time
/// due to fees accruing.
/// @author Usual Labs
contract WrappedDollarVault is
    ERC4626Upgradeable,
    ERC20PermitUpgradeable,
    ERC20PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IWrappedDollarVault
{
    /// @custom:storage-location erc7201:WrappedDollarVault.storage.v0

    struct WrappedDollarVaultStorageV0 {
        /// @notice The registry contract
        IRegistryContract registryContract;
        /// @notice The registry access contract
        IRegistryAccess registryAccess;
        /// @notice The treasury address
        address treasury;
        /// @notice router contract addresses that can bypass routing
        /// restrictions
        mapping(address router => bool isActive) routers;
        /// @notice The fee rate in basis points
        uint32 feeRateBps;
        /// @notice Timestamp of the last fee rate update
        uint256 lastFeeRateUpdateTimestamp;
        /// @notice Timestamp of the last harvest
        uint256 lastHarvestTimestamp;
    }

    // keccak256(abi.encode(uint256(keccak256("WrappedDollarVault.storage.v0"))
    // - 1)) & ~bytes32(uint256(0xff))
    // solhint-disable-next-line
    bytes32 public constant WrappedDollarVaultStorageV0Location =
        0x665abf5ce1d9fa2825cde69f0783b4cc2f3f90f409ca1923e47f911cae6e6400;

    function _wrappedDollarVaultStorageV0()
        internal
        pure
        returns (WrappedDollarVaultStorageV0 storage $)
    {
        bytes32 position = WrappedDollarVaultStorageV0Location;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := position
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice initialize the vault
    /// @param registryContract_ The address of the registry contract
    /// @param underlyingAsset_ The underlying asset
    /// @param name_ The name of the vault
    /// @param symbol_ The symbol of the vault
    function initialize(
        address registryContract_,
        address underlyingAsset_,
        string memory name_,
        string memory symbol_
    )
        public
        initializer
    {
        if (registryContract_ == address(0) || underlyingAsset_ == address(0)) {
            revert NullAddress();
        }
        __ReentrancyGuard_init();
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        __ERC20Pausable_init();
        __ERC4626_init(IERC20(underlyingAsset_));
        WrappedDollarVaultStorageV0 storage $ = _wrappedDollarVaultStorageV0();
        $.registryContract = IRegistryContract(registryContract_);
        $.registryAccess = IRegistryAccess(
            $.registryContract.getContract(CONTRACT_REGISTRY_ACCESS)
        );
        $.treasury = $.registryContract.getContract(CONTRACT_YIELD_TREASURY);
        $.feeRateBps = DEFAULT_FEE_RATE_BPS;
        $.lastFeeRateUpdateTimestamp = block.timestamp;
        _mint(DEAD_ADDRESS, INITIAL_SHARES_SUPPLY);
    }

    /*
     * ##########
     * # MODIFIERS #
     * ##########
     */
    /// @notice modifier to check if caller is allowed to route transactions
    modifier checkRouter() {
        WrappedDollarVaultStorageV0 storage $ = _wrappedDollarVaultStorageV0();
        if (!$.routers[_msgSender()]) {
            revert CallerNotAuthorizedRouter();
        }
        _;
    }

    /**
     *
     * RESTRICTED FUNCTIONS
     *
     */

    /// @inheritdoc IWrappedDollarVault
    function pause() external {
        WrappedDollarVaultStorageV0 storage $ = _wrappedDollarVaultStorageV0();
        if (!$.registryAccess.hasRole(VAULT_PAUSER_ROLE, _msgSender())) {
            revert NotAuthorized();
        }
        _pause();
    }

    /// @inheritdoc IWrappedDollarVault
    function unpause() external {
        WrappedDollarVaultStorageV0 storage $ = _wrappedDollarVaultStorageV0();
        if (!$.registryAccess.hasRole(VAULT_UNPAUSER_ROLE, _msgSender())) {
            revert NotAuthorized();
        }
        _unpause();
    }

    /// @inheritdoc IWrappedDollarVault
    function setRouter(address router, bool isActive) public whenNotPaused {
        WrappedDollarVaultStorageV0 storage $ = _wrappedDollarVaultStorageV0();
        if (!$.registryAccess.hasRole(VAULT_SET_ROUTER_ROLE, _msgSender())) {
            revert NotAuthorized();
        }
        if (router == address(0)) revert NullAddress();
        if ($.routers[router] == isActive) {
            revert SameRouterActivity(router, isActive);
        }

        $.routers[router] = isActive;
        emit RouterUpdated(router, isActive);
    }

    /// @inheritdoc IWrappedDollarVault
    function setFeeRateBps(uint32 newFeeRateBps) external whenNotPaused {
        if (newFeeRateBps > MAX_FEE_RATE_BPS) revert InvalidFeeRate();

        WrappedDollarVaultStorageV0 storage $ = _wrappedDollarVaultStorageV0();
        if (!$.registryAccess.hasRole(VAULT_SET_FEE_ROLE, _msgSender())) {
            revert NotAuthorized();
        }
        if (newFeeRateBps == $.feeRateBps) revert SameFeeRate();
        if (block.timestamp < $.lastFeeRateUpdateTimestamp + ONE_WEEK) {
            revert FeeRateUpdateTooFrequent();
        }
        uint32 oldFeeRateBps = $.feeRateBps;
        $.feeRateBps = newFeeRateBps;
        $.lastFeeRateUpdateTimestamp = block.timestamp;
        emit FeeRateUpdated(oldFeeRateBps, newFeeRateBps);
    }

    /// @inheritdoc IWrappedDollarVault
    function harvest()
        external
        whenNotPaused
        nonReentrant
        returns (uint256 sharesMinted)
    {
        WrappedDollarVaultStorageV0 storage $ = _wrappedDollarVaultStorageV0();

        if (!$.registryAccess.hasRole(VAULT_HARVESTER_ROLE, _msgSender())) {
            revert NotAuthorized();
        }

        if (block.timestamp < $.lastHarvestTimestamp + ONE_DAY) {
            revert HarvestTooFrequent();
        }

        uint256 currentSupply = totalSupply();
        sharesMinted = _feeOnTotal(currentSupply, $.feeRateBps);

        if (sharesMinted == 0) revert ZeroAmount();

        $.lastHarvestTimestamp = block.timestamp;

        _mint($.treasury, sharesMinted);

        emit Harvested(_msgSender(), sharesMinted);

        return sharesMinted;
    }

    /**
     *
     * VIEW FUNCTIONS
     *
     */

    /// @inheritdoc IWrappedDollarVault
    function decimals()
        public
        pure
        override(ERC4626Upgradeable, ERC20Upgradeable, IWrappedDollarVault)
        returns (uint8)
    {
        return VAULT_DECIMALS;
    }

    /// @inheritdoc IERC4626
    /// @dev Returns 0 if contract is paused
    function maxDeposit(address receiver)
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        if (paused()) return 0;
        return super.maxDeposit(receiver);
    }

    /// @inheritdoc IERC4626
    /// @dev Returns 0 if contract is paused
    function maxMint(address receiver)
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        if (paused()) return 0;
        return super.maxMint(receiver);
    }

    /// @inheritdoc IERC4626
    /// @dev Returns 0 if contract is paused
    function maxWithdraw(address owner)
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        if (paused()) return 0;

        // Get the maximum assets the user could withdraw without considering
        // fees
        uint256 assets = super.maxWithdraw(owner);
        if (assets == 0) return 0;

        WrappedDollarVaultStorageV0 storage $ = _wrappedDollarVaultStorageV0();
        // Apply fee calculation consistent with previewWithdraw
        uint256 fee = _feeOnRaw(assets, $.feeRateBps);

        // Return the maximum assets - fee
        return assets - fee;
    }

    function maxRedeem(address owner)
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        if (paused()) return 0;
        return super.maxRedeem(owner);
    }

    /// @dev Preview adding an exit fee on withdraw. See
    /// {IERC4626-previewWithdraw}.
    function previewWithdraw(uint256 assets)
        public
        view
        virtual
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        WrappedDollarVaultStorageV0 storage $ = _wrappedDollarVaultStorageV0();
        // Calculate fee amount
        uint256 fee = _feeOnTotal(assets, $.feeRateBps);

        // Calculate shares needed for assets + fee
        return super.previewWithdraw(assets + fee);
    }

    /// @dev Preview taking an exit fee on redeem. See {IERC4626-previewRedeem}.
    function previewRedeem(uint256 shares)
        public
        view
        virtual
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        // Convert shares to assets
        uint256 assets = super.previewRedeem(shares);

        WrappedDollarVaultStorageV0 storage $ = _wrappedDollarVaultStorageV0();
        // Calculate and deduct fee
        uint256 fee = _feeOnRaw(assets, $.feeRateBps);

        return assets - fee;
    }

    /// @inheritdoc IWrappedDollarVault
    function feeRateBps() public view returns (uint32) {
        WrappedDollarVaultStorageV0 storage $ = _wrappedDollarVaultStorageV0();
        return $.feeRateBps;
    }

    /// @inheritdoc IWrappedDollarVault
    function getRouterState(address router)
        public
        view
        returns (bool isActive)
    {
        WrappedDollarVaultStorageV0 storage $ = _wrappedDollarVaultStorageV0();
        return $.routers[router];
    }

    /**
     *
     * PUBLIC FUNCTIONS
     *
     */

    /// @inheritdoc IERC4626
    function deposit(
        uint256 assets,
        address receiver
    )
        public
        override(ERC4626Upgradeable, IERC4626)
        whenNotPaused
        nonReentrant
        checkRouter
        returns (uint256)
    {
        if (assets == 0 || previewDeposit(assets) == 0) revert ZeroAmount();
        if (receiver == address(0)) revert NullAddress();
        return super.deposit(assets, receiver);
    }

    /// @inheritdoc IERC4626
    function mint(
        uint256 shares,
        address receiver
    )
        public
        override(ERC4626Upgradeable, IERC4626)
        whenNotPaused
        nonReentrant
        checkRouter
        returns (uint256)
    {
        if (shares == 0 || previewMint(shares) == 0) revert ZeroAmount();
        if (receiver == address(0)) revert NullAddress();
        return super.mint(shares, receiver);
    }

    /// @inheritdoc IERC4626
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    )
        public
        override(ERC4626Upgradeable, IERC4626)
        whenNotPaused
        nonReentrant
        checkRouter
        returns (uint256)
    {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert NullAddress();

        return super.withdraw(assets, receiver, owner);
    }

    /// @inheritdoc IERC4626
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    )
        public
        override(ERC4626Upgradeable, IERC4626)
        whenNotPaused
        nonReentrant
        checkRouter
        returns (uint256)
    {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert NullAddress();

        return super.redeem(shares, receiver, owner);
    }

    /**
     *
     * INTERNAL FUNCTIONS
     *
     */

    /// @notice internal ERC20 function to update the balances
    /// @param from The address of the sender
    /// @param to The address of the receiver
    /// @param value The amount of tokens to be transferred
    function _update(
        address from,
        address to,
        uint256 value
    )
        internal
        override(ERC20Upgradeable, ERC20PausableUpgradeable)
    {
        ERC20PausableUpgradeable._update(from, to, value);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    )
        internal
        virtual
        override
    {
        WrappedDollarVaultStorageV0 storage $ = _wrappedDollarVaultStorageV0();

        // Calculate fee shares
        uint256 feeShares = _feeOnRaw(shares, $.feeRateBps);

        // Call parent implementation to handle the withdrawal
        super._withdraw(caller, receiver, owner, assets, shares);

        // Mint fee shares to treasury
        if (feeShares > 0) {
            _mint($.treasury, feeShares);
        }
    }

    /// @dev Calculates the fees that should be added to an amount `shares` that
    /// does not already include fees.
    /// Used in withdrawal operations.
    function _feeOnRaw(
        uint256 amount,
        uint256 feeBasisPoints
    )
        private
        pure
        returns (uint256)
    {
        return amount.mulDiv(feeBasisPoints, BPS_DIVIDER, Math.Rounding.Ceil);
    }

    /// @dev Calculates the fee part of an amount `shares` that already includes
    /// fees.
    /// Used in redemption operations.
    function _feeOnTotal(
        uint256 amount,
        uint256 feeBasisPoints
    )
        private
        pure
        returns (uint256)
    {
        return amount.mulDiv(
            feeBasisPoints, BPS_DIVIDER - feeBasisPoints, Math.Rounding.Ceil
        );
    }
}
