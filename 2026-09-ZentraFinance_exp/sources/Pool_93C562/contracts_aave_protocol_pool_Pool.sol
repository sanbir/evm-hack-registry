// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {VersionedInitializable} from '../libraries/aave-upgradeability/VersionedInitializable.sol';
import {Errors} from '../libraries/helpers/Errors.sol';
import {ReserveConfiguration} from '../libraries/configuration/ReserveConfiguration.sol';
import {PoolLogic} from '../libraries/logic/PoolLogic.sol';
import {ReserveLogic} from '../libraries/logic/ReserveLogic.sol';
import {EModeLogic} from '../libraries/logic/EModeLogic.sol';
import {SupplyLogic} from '../libraries/logic/SupplyLogic.sol';
import {FlashLoanLogic} from '../libraries/logic/FlashLoanLogic.sol';
import {BorrowLogic} from '../libraries/logic/BorrowLogic.sol';
import {LiquidationLogic} from '../libraries/logic/LiquidationLogic.sol';
import {DataTypes} from '../libraries/types/DataTypes.sol';
import {BridgeLogic} from '../libraries/logic/BridgeLogic.sol';
import {IERC20WithPermit} from '../../interfaces/IERC20WithPermit.sol';
import {IPoolAddressesProvider} from '../../interfaces/IPoolAddressesProvider.sol';
import {IPool} from '../../interfaces/IPool.sol';
import {IPoolHooks} from '../../interfaces/IPoolHooks.sol';
import {IACLManager} from '../../interfaces/IACLManager.sol';
import {PoolStorage} from './PoolStorage.sol';

/**
 * @title Pool contract
 * @author Aave
 * @notice Main point of interaction with an Aave protocol's market
 * - Users can:
 *   # Supply
 *   # Withdraw
 *   # Borrow
 *   # Repay
 *   # Swap their loans between variable and stable rate
 *   # Enable/disable their supplied assets as collateral rebalance stable rate borrow positions
 *   # Liquidate positions
 *   # Execute Flash Loans
 * @dev To be covered by a proxy contract, owned by the PoolAddressesProvider of the specific market
 * @dev All admin functions are callable by the PoolConfigurator contract defined also in the
 *   PoolAddressesProvider
 */
contract Pool is VersionedInitializable, PoolStorage, IPool {
  using ReserveLogic for DataTypes.ReserveData;

  uint256 public constant POOL_REVISION = 0x1;
  IPoolAddressesProvider public immutable ADDRESSES_PROVIDER;

  /**
   * @dev Only pool configurator can call functions marked by this modifier.
   */
  modifier onlyPoolConfigurator() {
    _onlyPoolConfigurator();
    _;
  }

  /**
   * @dev Only pool admin can call functions marked by this modifier.
   */
  modifier onlyPoolAdmin() {
    _onlyPoolAdmin();
    _;
  }

  /**
   * @dev Only bridge can call functions marked by this modifier.
   */
  modifier onlyBridge() {
    _onlyBridge();
    _;
  }

  function _onlyPoolConfigurator() internal view virtual {
    require(
      ADDRESSES_PROVIDER.getPoolConfigurator() == msg.sender,
      Errors.CALLER_NOT_POOL_CONFIGURATOR
    );
  }

  function _onlyPoolAdmin() internal view virtual {
    require(
      IACLManager(ADDRESSES_PROVIDER.getACLManager()).isPoolAdmin(msg.sender),
      Errors.CALLER_NOT_POOL_ADMIN
    );
  }

  function _onlyBridge() internal view virtual {
    require(
      IACLManager(ADDRESSES_PROVIDER.getACLManager()).isBridge(msg.sender),
      Errors.CALLER_NOT_BRIDGE
    );
  }

  function getRevision() internal pure virtual override returns (uint256) {
    return POOL_REVISION;
  }

  /**
   * @dev Constructor.
   * @param provider The address of the PoolAddressesProvider contract
   */
  constructor(IPoolAddressesProvider provider) {
    ADDRESSES_PROVIDER = provider;
  }

  /**
   * @notice Initializes the Pool.
   * @dev Function is invoked by the proxy contract when the Pool contract is added to the
   * PoolAddressesProvider of the market.
   * @dev Caching the address of the PoolAddressesProvider in order to reduce gas consumption on subsequent operations
   * @param provider The address of the PoolAddressesProvider
   */
  function initialize(IPoolAddressesProvider provider) external virtual initializer {
    require(provider == ADDRESSES_PROVIDER, Errors.INVALID_ADDRESSES_PROVIDER);
    _maxStableRateBorrowSizePercent = 0.25e4;
  }

  /// @inheritdoc IPool
  function mintUnbacked(
    address asset,
    uint256 amount,
    address onBehalfOf,
    uint16 referralCode
  ) external virtual override onlyBridge {
    BridgeLogic.executeMintUnbacked(
      _reserves,
      _reservesList,
      _usersConfig[onBehalfOf],
      asset,
      amount,
      onBehalfOf,
      referralCode
    );
  }

  /// @inheritdoc IPool
  function backUnbacked(
    address asset,
    uint256 amount,
    uint256 fee
  ) external virtual override onlyBridge returns (uint256) {
    return
      BridgeLogic.executeBackUnbacked(_reserves[asset], asset, amount, fee, _bridgeProtocolFee);
  }

  /// @inheritdoc IPool
  function supply(
    address asset,
    uint256 amount,
    address onBehalfOf,
    uint16 referralCode
  ) public virtual override {
    // BEFORE hook: Security validation (blocking)
    require(_callBeforeSupply(asset, amount, onBehalfOf, referralCode), Errors.HOOK_BLOCKED);

    SupplyLogic.executeSupply(
      _reserves,
      _reservesList,
      _usersConfig[onBehalfOf],
      DataTypes.ExecuteSupplyParams({
        asset: asset,
        amount: amount,
        onBehalfOf: onBehalfOf,
        referralCode: referralCode
      })
    );

    // AFTER hook: Tracking and logging (non-blocking)
    _callAfterSupply(asset, amount, onBehalfOf, referralCode);
  }

  /// @inheritdoc IPool
  function supplyWithPermit(
    address asset,
    uint256 amount,
    address onBehalfOf,
    uint16 referralCode,
    uint256 deadline,
    uint8 permitV,
    bytes32 permitR,
    bytes32 permitS
  ) public virtual override {
    // BEFORE hook: Security validation (blocking) - check before permit to save gas on rejection
    require(_callBeforeSupply(asset, amount, onBehalfOf, referralCode), Errors.HOOK_BLOCKED);

    IERC20WithPermit(asset).permit(
      msg.sender,
      address(this),
      amount,
      deadline,
      permitV,
      permitR,
      permitS
    );
    SupplyLogic.executeSupply(
      _reserves,
      _reservesList,
      _usersConfig[onBehalfOf],
      DataTypes.ExecuteSupplyParams({
        asset: asset,
        amount: amount,
        onBehalfOf: onBehalfOf,
        referralCode: referralCode
      })
    );

    // AFTER hook: Tracking and logging (non-blocking)
    _callAfterSupply(asset, amount, onBehalfOf, referralCode);
  }

  /// @inheritdoc IPool
  function withdraw(
    address asset,
    uint256 amount,
    address to
  ) public virtual override returns (uint256) {
    return
      SupplyLogic.executeWithdraw(
        _reserves,
        _reservesList,
        _eModeCategories,
        _usersConfig[msg.sender],
        DataTypes.ExecuteWithdrawParams({
          asset: asset,
          amount: amount,
          to: to,
          reservesCount: _reservesCount,
          oracle: ADDRESSES_PROVIDER.getPriceOracle(),
          userEModeCategory: _usersEModeCategory[msg.sender]
        })
      );
  }

  /// @inheritdoc IPool
  function borrow(
    address asset,
    uint256 amount,
    uint256 interestRateMode,
    uint16 referralCode,
    address onBehalfOf
  ) public virtual override {
    // BEFORE hook: Security validation (blocking)
    require(
      _callBeforeBorrow(asset, msg.sender, onBehalfOf, amount, interestRateMode, referralCode),
      Errors.HOOK_BLOCKED
    );

    BorrowLogic.executeBorrow(
      _reserves,
      _reservesList,
      _eModeCategories,
      _usersConfig[onBehalfOf],
      DataTypes.ExecuteBorrowParams({
        asset: asset,
        user: msg.sender,
        onBehalfOf: onBehalfOf,
        amount: amount,
        interestRateMode: DataTypes.InterestRateMode(interestRateMode),
        referralCode: referralCode,
        releaseUnderlying: true,
        maxStableRateBorrowSizePercent: _maxStableRateBorrowSizePercent,
        reservesCount: _reservesCount,
        oracle: ADDRESSES_PROVIDER.getPriceOracle(),
        userEModeCategory: _usersEModeCategory[onBehalfOf],
        priceOracleSentinel: ADDRESSES_PROVIDER.getPriceOracleSentinel()
      })
    );

    // AFTER hook: Tracking and logging (non-blocking)
    _callAfterBorrow(asset, amount, interestRateMode, onBehalfOf, msg.sender, referralCode);
  }

  /// @inheritdoc IPool
  function repay(
    address asset,
    uint256 amount,
    uint256 interestRateMode,
    address onBehalfOf
  ) public virtual override returns (uint256) {
    return
      BorrowLogic.executeRepay(
        _reserves,
        _reservesList,
        _usersConfig[onBehalfOf],
        DataTypes.ExecuteRepayParams({
          asset: asset,
          amount: amount,
          interestRateMode: DataTypes.InterestRateMode(interestRateMode),
          onBehalfOf: onBehalfOf,
          useATokens: false
        })
      );
  }

  /// @inheritdoc IPool
  function repayWithPermit(
    address asset,
    uint256 amount,
    uint256 interestRateMode,
    address onBehalfOf,
    uint256 deadline,
    uint8 permitV,
    bytes32 permitR,
    bytes32 permitS
  ) public virtual override returns (uint256) {
    {
      IERC20WithPermit(asset).permit(
        msg.sender,
        address(this),
        amount,
        deadline,
        permitV,
        permitR,
        permitS
      );
    }
    {
      DataTypes.ExecuteRepayParams memory params = DataTypes.ExecuteRepayParams({
        asset: asset,
        amount: amount,
        interestRateMode: DataTypes.InterestRateMode(interestRateMode),
        onBehalfOf: onBehalfOf,
        useATokens: false
      });
      return BorrowLogic.executeRepay(_reserves, _reservesList, _usersConfig[onBehalfOf], params);
    }
  }

  /// @inheritdoc IPool
  function repayWithATokens(
    address asset,
    uint256 amount,
    uint256 interestRateMode
  ) public virtual override returns (uint256) {
    return
      BorrowLogic.executeRepay(
        _reserves,
        _reservesList,
        _usersConfig[msg.sender],
        DataTypes.ExecuteRepayParams({
          asset: asset,
          amount: amount,
          interestRateMode: DataTypes.InterestRateMode(interestRateMode),
          onBehalfOf: msg.sender,
          useATokens: true
        })
      );
  }

  /// @inheritdoc IPool
  function swapBorrowRateMode(address asset, uint256 interestRateMode) public virtual override {
    BorrowLogic.executeSwapBorrowRateMode(
      _reserves[asset],
      _usersConfig[msg.sender],
      asset,
      DataTypes.InterestRateMode(interestRateMode)
    );
  }

  /// @inheritdoc IPool
  function rebalanceStableBorrowRate(address asset, address user) public virtual override {
    BorrowLogic.executeRebalanceStableBorrowRate(_reserves[asset], asset, user);
  }

  /// @inheritdoc IPool
  function setUserUseReserveAsCollateral(
    address asset,
    bool useAsCollateral
  ) public virtual override {
    SupplyLogic.executeUseReserveAsCollateral(
      _reserves,
      _reservesList,
      _eModeCategories,
      _usersConfig[msg.sender],
      asset,
      useAsCollateral,
      _reservesCount,
      ADDRESSES_PROVIDER.getPriceOracle(),
      _usersEModeCategory[msg.sender]
    );
  }

  /// @inheritdoc IPool
  function liquidationCall(
    address collateralAsset,
    address debtAsset,
    address user,
    uint256 debtToCover,
    bool receiveAToken
  ) public virtual override {
    // BEFORE hook: Security validation (blocking)
    require(
      _callBeforeLiquidation(collateralAsset, debtAsset, user, debtToCover, receiveAToken),
      Errors.HOOK_BLOCKED
    );

    LiquidationLogic.executeLiquidationCall(
      _reserves,
      _reservesList,
      _usersConfig,
      _eModeCategories,
      DataTypes.ExecuteLiquidationCallParams({
        reservesCount: _reservesCount,
        debtToCover: debtToCover,
        collateralAsset: collateralAsset,
        debtAsset: debtAsset,
        user: user,
        receiveAToken: receiveAToken,
        priceOracle: ADDRESSES_PROVIDER.getPriceOracle(),
        userEModeCategory: _usersEModeCategory[user],
        priceOracleSentinel: ADDRESSES_PROVIDER.getPriceOracleSentinel()
      })
    );

    // AFTER hook: Tracking and logging (non-blocking) - Primary hook for bad debt detection
    _callAfterLiquidation(collateralAsset, debtAsset, user, debtToCover, msg.sender, receiveAToken);
  }

  /// @inheritdoc IPool
  function flashLoan(
    address receiverAddress,
    address[] calldata assets,
    uint256[] calldata amounts,
    uint256[] calldata interestRateModes,
    address onBehalfOf,
    bytes calldata params,
    uint16 referralCode
  ) public virtual override {
    // BEFORE hook: Security validation (blocking)
    require(
      _callBeforeFlashLoan(
        receiverAddress,
        assets,
        amounts,
        interestRateModes,
        onBehalfOf,
        params,
        referralCode
      ),
      Errors.HOOK_BLOCKED
    );

    DataTypes.FlashloanParams memory flashParams = DataTypes.FlashloanParams({
      receiverAddress: receiverAddress,
      assets: assets,
      amounts: amounts,
      interestRateModes: interestRateModes,
      onBehalfOf: onBehalfOf,
      params: params,
      referralCode: referralCode,
      flashLoanPremiumToProtocol: _flashLoanPremiumToProtocol,
      flashLoanPremiumTotal: _flashLoanPremiumTotal,
      maxStableRateBorrowSizePercent: _maxStableRateBorrowSizePercent,
      reservesCount: _reservesCount,
      addressesProvider: address(ADDRESSES_PROVIDER),
      userEModeCategory: _usersEModeCategory[onBehalfOf],
      isAuthorizedFlashBorrower: IACLManager(ADDRESSES_PROVIDER.getACLManager()).isFlashBorrower(
        msg.sender
      )
    });

    FlashLoanLogic.executeFlashLoan(
      _reserves,
      _reservesList,
      _eModeCategories,
      _usersConfig[onBehalfOf],
      flashParams
    );

    // AFTER hook: Tracking and logging (non-blocking)
    _callAfterFlashLoan(flashParams);
  }

  /// @inheritdoc IPool
  function flashLoanSimple(
    address receiverAddress,
    address asset,
    uint256 amount,
    bytes calldata params,
    uint16 referralCode
  ) public virtual override {
    // BEFORE hook: Security validation (blocking)
    // Convert single asset to arrays for hook compatibility
    address[] memory assets = new address[](1);
    assets[0] = asset;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = amount;
    uint256[] memory interestRateModes = new uint256[](1);
    interestRateModes[0] = 0; // Simple flash loans don't open debt

    require(
      _callBeforeFlashLoanSimple(
        receiverAddress,
        assets,
        amounts,
        interestRateModes,
        msg.sender, // onBehalfOf is msg.sender for simple flash loans
        params,
        referralCode
      ),
      Errors.HOOK_BLOCKED
    );

    DataTypes.FlashloanSimpleParams memory flashParams = DataTypes.FlashloanSimpleParams({
      receiverAddress: receiverAddress,
      asset: asset,
      amount: amount,
      params: params,
      referralCode: referralCode,
      flashLoanPremiumToProtocol: _flashLoanPremiumToProtocol,
      flashLoanPremiumTotal: _flashLoanPremiumTotal
    });
    FlashLoanLogic.executeFlashLoanSimple(_reserves[asset], flashParams);

    // AFTER hook: Tracking and logging (non-blocking)
    _callAfterFlashLoanSimple(receiverAddress, asset, amount, referralCode);
  }

  /// @inheritdoc IPool
  function mintToTreasury(address[] calldata assets) external virtual override {
    PoolLogic.executeMintToTreasury(_reserves, assets);
  }

  /// @inheritdoc IPool
  function getReserveData(
    address asset
  ) external view virtual override returns (DataTypes.ReserveData memory) {
    return _reserves[asset];
  }

  /// @inheritdoc IPool
  function getUserAccountData(
    address user
  )
    external
    view
    virtual
    override
    returns (
      uint256 totalCollateralBase,
      uint256 totalDebtBase,
      uint256 availableBorrowsBase,
      uint256 currentLiquidationThreshold,
      uint256 ltv,
      uint256 healthFactor
    )
  {
    return
      PoolLogic.executeGetUserAccountData(
        _reserves,
        _reservesList,
        _eModeCategories,
        DataTypes.CalculateUserAccountDataParams({
          userConfig: _usersConfig[user],
          reservesCount: _reservesCount,
          user: user,
          oracle: ADDRESSES_PROVIDER.getPriceOracle(),
          userEModeCategory: _usersEModeCategory[user]
        })
      );
  }

  /// @inheritdoc IPool
  function getConfiguration(
    address asset
  ) external view virtual override returns (DataTypes.ReserveConfigurationMap memory) {
    return _reserves[asset].configuration;
  }

  /// @inheritdoc IPool
  function getUserConfiguration(
    address user
  ) external view virtual override returns (DataTypes.UserConfigurationMap memory) {
    return _usersConfig[user];
  }

  /// @inheritdoc IPool
  function getReserveNormalizedIncome(
    address asset
  ) external view virtual override returns (uint256) {
    return _reserves[asset].getNormalizedIncome();
  }

  /// @inheritdoc IPool
  function getReserveNormalizedVariableDebt(
    address asset
  ) external view virtual override returns (uint256) {
    return _reserves[asset].getNormalizedDebt();
  }

  /// @inheritdoc IPool
  function getReservesList() external view virtual override returns (address[] memory) {
    uint256 reservesListCount = _reservesCount;
    uint256 droppedReservesCount = 0;
    address[] memory reservesList = new address[](reservesListCount);

    for (uint256 i = 0; i < reservesListCount; i++) {
      if (_reservesList[i] != address(0)) {
        reservesList[i - droppedReservesCount] = _reservesList[i];
      } else {
        droppedReservesCount++;
      }
    }

    // Reduces the length of the reserves array by `droppedReservesCount`
    assembly {
      mstore(reservesList, sub(reservesListCount, droppedReservesCount))
    }
    return reservesList;
  }

  /// @inheritdoc IPool
  function getReserveAddressById(uint16 id) external view returns (address) {
    return _reservesList[id];
  }

  /// @inheritdoc IPool
  function MAX_STABLE_RATE_BORROW_SIZE_PERCENT() public view virtual override returns (uint256) {
    return _maxStableRateBorrowSizePercent;
  }

  /// @inheritdoc IPool
  function BRIDGE_PROTOCOL_FEE() public view virtual override returns (uint256) {
    return _bridgeProtocolFee;
  }

  /// @inheritdoc IPool
  function FLASHLOAN_PREMIUM_TOTAL() public view virtual override returns (uint128) {
    return _flashLoanPremiumTotal;
  }

  /// @inheritdoc IPool
  function FLASHLOAN_PREMIUM_TO_PROTOCOL() public view virtual override returns (uint128) {
    return _flashLoanPremiumToProtocol;
  }

  /// @inheritdoc IPool
  function MAX_NUMBER_RESERVES() public view virtual override returns (uint16) {
    return ReserveConfiguration.MAX_RESERVES_COUNT;
  }

  /// @inheritdoc IPool
  function finalizeTransfer(
    address asset,
    address from,
    address to,
    uint256 amount,
    uint256 balanceFromBefore,
    uint256 balanceToBefore
  ) external virtual override {
    require(msg.sender == _reserves[asset].aTokenAddress, Errors.CALLER_NOT_ATOKEN);
    SupplyLogic.executeFinalizeTransfer(
      _reserves,
      _reservesList,
      _eModeCategories,
      _usersConfig,
      DataTypes.FinalizeTransferParams({
        asset: asset,
        from: from,
        to: to,
        amount: amount,
        balanceFromBefore: balanceFromBefore,
        balanceToBefore: balanceToBefore,
        reservesCount: _reservesCount,
        oracle: ADDRESSES_PROVIDER.getPriceOracle(),
        fromEModeCategory: _usersEModeCategory[from]
      })
    );
  }

  /// @inheritdoc IPool
  function initReserve(
    address asset,
    address aTokenAddress,
    address stableDebtAddress,
    address variableDebtAddress,
    address interestRateStrategyAddress
  ) external virtual override onlyPoolConfigurator {
    if (
      PoolLogic.executeInitReserve(
        _reserves,
        _reservesList,
        DataTypes.InitReserveParams({
          asset: asset,
          aTokenAddress: aTokenAddress,
          stableDebtAddress: stableDebtAddress,
          variableDebtAddress: variableDebtAddress,
          interestRateStrategyAddress: interestRateStrategyAddress,
          reservesCount: _reservesCount,
          maxNumberReserves: MAX_NUMBER_RESERVES()
        })
      )
    ) {
      _reservesCount++;
    }
  }

  /// @inheritdoc IPool
  function dropReserve(address asset) external virtual override onlyPoolConfigurator {
    PoolLogic.executeDropReserve(_reserves, _reservesList, asset);
  }

  /// @inheritdoc IPool
  function setReserveInterestRateStrategyAddress(
    address asset,
    address rateStrategyAddress
  ) external virtual override onlyPoolConfigurator {
    require(asset != address(0), Errors.ZERO_ADDRESS_NOT_VALID);
    require(_reserves[asset].id != 0 || _reservesList[0] == asset, Errors.ASSET_NOT_LISTED);
    _reserves[asset].interestRateStrategyAddress = rateStrategyAddress;
  }

  /// @inheritdoc IPool
  function setConfiguration(
    address asset,
    DataTypes.ReserveConfigurationMap calldata configuration
  ) external virtual override onlyPoolConfigurator {
    require(asset != address(0), Errors.ZERO_ADDRESS_NOT_VALID);
    require(_reserves[asset].id != 0 || _reservesList[0] == asset, Errors.ASSET_NOT_LISTED);
    _reserves[asset].configuration = configuration;
  }

  /// @inheritdoc IPool
  function updateBridgeProtocolFee(
    uint256 protocolFee
  ) external virtual override onlyPoolConfigurator {
    _bridgeProtocolFee = protocolFee;
  }

  /// @inheritdoc IPool
  function updateFlashloanPremiums(
    uint128 flashLoanPremiumTotal,
    uint128 flashLoanPremiumToProtocol
  ) external virtual override onlyPoolConfigurator {
    _flashLoanPremiumTotal = flashLoanPremiumTotal;
    _flashLoanPremiumToProtocol = flashLoanPremiumToProtocol;
  }

  /// @inheritdoc IPool
  function configureEModeCategory(
    uint8 id,
    DataTypes.EModeCategory memory category
  ) external virtual override onlyPoolConfigurator {
    // category 0 is reserved for volatile heterogeneous assets and it's always disabled
    require(id != 0, Errors.EMODE_CATEGORY_RESERVED);
    _eModeCategories[id] = category;
  }

  /// @inheritdoc IPool
  function getEModeCategoryData(
    uint8 id
  ) external view virtual override returns (DataTypes.EModeCategory memory) {
    return _eModeCategories[id];
  }

  /// @inheritdoc IPool
  function setUserEMode(uint8 categoryId) external virtual override {
    EModeLogic.executeSetUserEMode(
      _reserves,
      _reservesList,
      _eModeCategories,
      _usersEModeCategory,
      _usersConfig[msg.sender],
      DataTypes.ExecuteSetUserEModeParams({
        reservesCount: _reservesCount,
        oracle: ADDRESSES_PROVIDER.getPriceOracle(),
        categoryId: categoryId
      })
    );
  }

  /// @inheritdoc IPool
  function getUserEMode(address user) external view virtual override returns (uint256) {
    return _usersEModeCategory[user];
  }

  /// @inheritdoc IPool
  function resetIsolationModeTotalDebt(
    address asset
  ) external virtual override onlyPoolConfigurator {
    PoolLogic.executeResetIsolationModeTotalDebt(_reserves, asset);
  }

  /// @inheritdoc IPool
  function rescueTokens(
    address token,
    address to,
    uint256 amount
  ) external virtual override onlyPoolAdmin {
    PoolLogic.executeRescueTokens(token, to, amount);
  }

  /// @inheritdoc IPool
  /// @dev Deprecated: maintained for compatibility purposes
  function deposit(
    address asset,
    uint256 amount,
    address onBehalfOf,
    uint16 referralCode
  ) external virtual override {
    // BEFORE hook: Security validation (blocking) - deposit uses same hook as supply
    require(_callBeforeSupply(asset, amount, onBehalfOf, referralCode), Errors.HOOK_BLOCKED);

    SupplyLogic.executeSupply(
      _reserves,
      _reservesList,
      _usersConfig[onBehalfOf],
      DataTypes.ExecuteSupplyParams({
        asset: asset,
        amount: amount,
        onBehalfOf: onBehalfOf,
        referralCode: referralCode
      })
    );

    // AFTER hook: Tracking and logging (non-blocking) - deposit is alias for supply
    _callAfterSupply(asset, amount, onBehalfOf, referralCode);
  }

  // ============================================================
  //                  POOL HOOKS ADMIN
  // ============================================================

  /**
   * @notice Sets the address of the pool hooks contract
   * @dev Only callable by the PoolConfigurator. Set to address(0) to disable hooks.
   *      When enabled, this should point to the SecurityIntegrationV2 contract.
   * @param hooks The address of the hooks contract (SecurityIntegrationV2), or address(0) to disable
   */
  function setPoolHooks(address hooks) external virtual override onlyPoolConfigurator {
    _poolHooks = hooks;
    emit PoolHooksUpdated(hooks);
  }

  /**
   * @notice Returns the current pool hooks contract address
   * @return The address of the hooks contract, or address(0) if disabled
   */
  function getPoolHooks() external view virtual override returns (address) {
    return _poolHooks;
  }

  // ============================================================
  //                    POOL HOOKS SYSTEM
  // ============================================================

  // -------------------- BEFORE HOOKS (Blocking) --------------------

  /**
   * @notice Internal function to call beforeSupply hook
   * @dev Fail-closed: If hook reverts, operation is blocked for security.
   *      Returns true if no hooks configured (permissive default).
   * @param asset The asset to supply
   * @param amount The amount to supply
   * @param onBehalfOf The recipient of aTokens
   * @param referralCode The referral code
   * @return allowed True if operation should proceed, false to block
   */
  function _callBeforeSupply(
    address asset,
    uint256 amount,
    address onBehalfOf,
    uint16 referralCode
  ) internal returns (bool) {
    address hooks = _poolHooks;
    if (hooks == address(0)) return true; // No hooks = allow

    // Fail-closed: If hook reverts, the require in the caller will fail
    return IPoolHooks(hooks).beforeSupply(asset, amount, onBehalfOf, referralCode);
  }

  /**
   * @notice Internal function to call beforeBorrow hook
   * @dev Fail-closed: If hook reverts, operation is blocked for security.
   *      Returns true if no hooks configured (permissive default).
   * @param asset The asset to borrow
   * @param user The borrower (msg.sender)
   * @param onBehalfOf The debt recipient
   * @param amount The amount to borrow
   * @param interestRateMode The interest rate mode
   * @param referralCode The referral code
   * @return allowed True if operation should proceed, false to block
   */
  function _callBeforeBorrow(
    address asset,
    address user,
    address onBehalfOf,
    uint256 amount,
    uint256 interestRateMode,
    uint16 referralCode
  ) internal returns (bool) {
    address hooks = _poolHooks;
    if (hooks == address(0)) return true; // No hooks = allow

    // Fail-closed: If hook reverts, the require in the caller will fail
    return IPoolHooks(hooks).beforeBorrow(asset, user, onBehalfOf, amount, interestRateMode, referralCode);
  }

  /**
   * @notice Internal function to call beforeLiquidation hook
   * @dev Fail-closed: If hook reverts, operation is blocked for security.
   *      Returns true if no hooks configured (permissive default).
   * @param collateralAsset The collateral to liquidate
   * @param debtAsset The debt to repay
   * @param user The user being liquidated
   * @param debtToCover The amount of debt to cover
   * @param receiveAToken Whether liquidator wants aTokens
   * @return allowed True if operation should proceed, false to block
   */
  function _callBeforeLiquidation(
    address collateralAsset,
    address debtAsset,
    address user,
    uint256 debtToCover,
    bool receiveAToken
  ) internal returns (bool) {
    address hooks = _poolHooks;
    if (hooks == address(0)) return true; // No hooks = allow

    // Fail-closed: If hook reverts, the require in the caller will fail
    return IPoolHooks(hooks).beforeLiquidation(collateralAsset, debtAsset, user, debtToCover, receiveAToken);
  }

  /**
   * @notice Internal function to call beforeFlashLoan hook
   * @dev Fail-closed: If hook reverts, operation is blocked for security.
   *      Returns true if no hooks configured (permissive default).
   * @param receiverAddress The flash loan receiver
   * @param assets Array of assets to borrow
   * @param amounts Array of amounts to borrow
   * @param interestRateModes Array of interest rate modes
   * @param onBehalfOf The debt recipient (if any)
   * @param params Additional parameters
   * @param referralCode The referral code
   * @return allowed True if operation should proceed, false to block
   */
  function _callBeforeFlashLoan(
    address receiverAddress,
    address[] calldata assets,
    uint256[] calldata amounts,
    uint256[] calldata interestRateModes,
    address onBehalfOf,
    bytes calldata params,
    uint16 referralCode
  ) internal returns (bool) {
    address hooks = _poolHooks;
    if (hooks == address(0)) return true; // No hooks = allow

    // Fail-closed: If hook reverts, the require in the caller will fail
    return IPoolHooks(hooks).beforeFlashLoan(
      receiverAddress,
      assets,
      amounts,
      interestRateModes,
      onBehalfOf,
      params,
      referralCode
    );
  }

  /**
   * @notice Internal function to call beforeFlashLoan hook for simple flash loans
   * @dev Fail-closed: If hook reverts, operation is blocked for security.
   *      Uses memory arrays to match the hook interface.
   * @param receiverAddress The flash loan receiver
   * @param assets Array of assets (single element for simple flash loan)
   * @param amounts Array of amounts (single element for simple flash loan)
   * @param interestRateModes Array of interest rate modes (single element, always 0)
   * @param onBehalfOf The debt recipient (msg.sender for simple flash loans)
   * @param params Additional parameters
   * @param referralCode The referral code
   * @return allowed True if operation should proceed, false to block
   */
  function _callBeforeFlashLoanSimple(
    address receiverAddress,
    address[] memory assets,
    uint256[] memory amounts,
    uint256[] memory interestRateModes,
    address onBehalfOf,
    bytes calldata params,
    uint16 referralCode
  ) internal returns (bool) {
    address hooks = _poolHooks;
    if (hooks == address(0)) return true; // No hooks = allow

    // Fail-closed: If hook reverts, the require in the caller will fail
    return IPoolHooks(hooks).beforeFlashLoan(
      receiverAddress,
      assets,
      amounts,
      interestRateModes,
      onBehalfOf,
      params,
      referralCode
    );
  }

  // -------------------- AFTER HOOKS (Non-blocking) --------------------

  /**
   * @notice Internal function to call afterSupply hook
   * @dev Uses try/catch to prevent hook failures from blocking supply operations
   * @param asset The supplied asset address
   * @param amount The supplied amount
   * @param onBehalfOf The recipient of aTokens
   * @param referralCode The referral code
   */
  function _callAfterSupply(
    address asset,
    uint256 amount,
    address onBehalfOf,
    uint16 referralCode
  ) internal {
    address hooks = _poolHooks;
    if (hooks == address(0)) return;

    try IPoolHooks(hooks).afterSupply(asset, amount, onBehalfOf, referralCode) {
      // Hook executed successfully
    } catch {
      // Hook failed - do not revert, just continue
      // This ensures hook failures never block Pool operations
    }
  }

  /**
   * @notice Internal function to call afterBorrow hook
   * @dev Uses try/catch to prevent hook failures from blocking borrow operations
   * @param asset The borrowed asset address
   * @param amount The borrowed amount
   * @param interestRateMode The interest rate mode (1=Stable, 2=Variable)
   * @param onBehalfOf The debt recipient
   * @param borrower The initiator of the borrow
   * @param referralCode The referral code
   */
  function _callAfterBorrow(
    address asset,
    uint256 amount,
    uint256 interestRateMode,
    address onBehalfOf,
    address borrower,
    uint16 referralCode
  ) internal {
    address hooks = _poolHooks;
    if (hooks == address(0)) return;

    try IPoolHooks(hooks).afterBorrow(
      asset,
      amount,
      interestRateMode,
      onBehalfOf,
      borrower,
      referralCode
    ) {
      // Hook executed successfully
    } catch {
      // Hook failed - do not revert, just continue
    }
  }

  /**
   * @notice Internal function to call afterLiquidation hook
   * @dev Uses try/catch to prevent hook failures from blocking liquidation operations.
   *      This is the primary hook for bad debt detection.
   * @param collateralAsset The liquidated collateral asset
   * @param debtAsset The repaid debt asset
   * @param user The liquidated user
   * @param debtToCover The amount of debt covered
   * @param liquidator The liquidator address
   * @param receiveAToken Whether liquidator received aTokens
   */
  function _callAfterLiquidation(
    address collateralAsset,
    address debtAsset,
    address user,
    uint256 debtToCover,
    address liquidator,
    bool receiveAToken
  ) internal {
    address hooks = _poolHooks;
    if (hooks == address(0)) return;

    // Note: liquidatedCollateralAmount is not directly available from executeLiquidationCall
    // The hook contract can calculate it if needed using debtToCover and prices
    try IPoolHooks(hooks).afterLiquidation(
      collateralAsset,
      debtAsset,
      user,
      debtToCover,
      0, // liquidatedCollateralAmount - SecurityIntegrationV2 can calculate if needed
      liquidator,
      receiveAToken
    ) {
      // Hook executed successfully
    } catch {
      // Hook failed - do not revert, just continue
    }
  }

  /**
   * @notice Internal function to call afterFlashLoan hook
   * @dev Uses try/catch to prevent hook failures from blocking flash loan operations.
   *      Uses a separate internal function to avoid stack-too-deep in flashLoan context.
   * @param flashParams The flash loan parameters struct
   */
  function _callAfterFlashLoan(
    DataTypes.FlashloanParams memory flashParams
  ) internal {
    address hooks = _poolHooks;
    if (hooks == address(0)) return;

    try IPoolHooks(hooks).afterFlashLoan(
      flashParams.receiverAddress,
      flashParams.assets,
      flashParams.amounts,
      flashParams.interestRateModes,
      flashParams.onBehalfOf,
      flashParams.referralCode
    ) {
      // Hook executed successfully
    } catch {
      // Hook failed - do not revert, just continue
    }
  }

  /**
   * @notice Internal function to call afterFlashLoan hook for simple flash loans
   * @dev Uses try/catch to prevent hook failures from blocking flash loan operations.
   *      Converts single asset parameters to arrays for hook compatibility.
   * @param receiverAddress The flash loan receiver
   * @param asset The asset that was flash borrowed
   * @param amount The amount that was flash borrowed
   * @param referralCode The referral code
   */
  function _callAfterFlashLoanSimple(
    address receiverAddress,
    address asset,
    uint256 amount,
    uint16 referralCode
  ) internal {
    address hooks = _poolHooks;
    if (hooks == address(0)) return;

    // Convert single asset to arrays for hook compatibility
    address[] memory assets = new address[](1);
    assets[0] = asset;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = amount;
    uint256[] memory interestRateModes = new uint256[](1);
    interestRateModes[0] = 0; // Simple flash loans don't open debt

    try IPoolHooks(hooks).afterFlashLoan(
      receiverAddress,
      assets,
      amounts,
      interestRateModes,
      msg.sender, // onBehalfOf is msg.sender for simple flash loans
      referralCode
    ) {
      // Hook executed successfully
    } catch {
      // Hook failed - do not revert, just continue
    }
  }
}
