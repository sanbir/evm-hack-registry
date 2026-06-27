// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { Id, IMoolahStaticTyping, IMoolahBase, MarketParams, Position, Market, Authorization, Signature } from "./interfaces/IMoolah.sol";
import { IMoolahLiquidateCallback, IMoolahRepayCallback, IMoolahSupplyCallback, IMoolahSupplyCollateralCallback, IMoolahFlashLoanCallback } from "./interfaces/IMoolahCallbacks.sol";
import { IIrm } from "./interfaces/IIrm.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { IOracle } from "./interfaces/IOracle.sol";

import "./libraries/ConstantsLib.sol";
import { UtilsLib } from "./libraries/UtilsLib.sol";
import { EventsLib } from "./libraries/EventsLib.sol";
import { ErrorsLib } from "./libraries/ErrorsLib.sol";
import { MathLib, WAD } from "./libraries/MathLib.sol";
import { SharesMathLib } from "./libraries/SharesMathLib.sol";
import { MarketParamsLib } from "./libraries/MarketParamsLib.sol";
import { SafeTransferLib } from "./libraries/SafeTransferLib.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IProvider } from "../provider/interfaces/IProvider.sol";

/// @title Moolah
/// @author Lista DAO
/// @notice The Moolah contract.
contract Moolah is
  UUPSUpgradeable,
  AccessControlEnumerableUpgradeable,
  ReentrancyGuardUpgradeable,
  PausableUpgradeable,
  IMoolahStaticTyping
{
  using MathLib for uint128;
  using MathLib for uint256;
  using UtilsLib for uint256;
  using SharesMathLib for uint256;
  using SafeTransferLib for IERC20;
  using MarketParamsLib for MarketParams;
  using EnumerableSet for EnumerableSet.AddressSet;

  /* IMMUTABLES */

  /// @inheritdoc IMoolahBase
  bytes32 public immutable DOMAIN_SEPARATOR;

  /* STORAGE */

  /// @inheritdoc IMoolahBase
  address public feeRecipient;
  /// @inheritdoc IMoolahStaticTyping
  mapping(Id => mapping(address => Position)) public position;
  /// @inheritdoc IMoolahStaticTyping
  mapping(Id => Market) public market;
  /// @inheritdoc IMoolahBase
  mapping(address => bool) public isIrmEnabled;
  /// @inheritdoc IMoolahBase
  mapping(uint256 => bool) public isLltvEnabled;
  /// @inheritdoc IMoolahBase
  mapping(address => mapping(address => bool)) public isAuthorized;
  /// @inheritdoc IMoolahBase
  mapping(address => uint256) public nonce;
  /// @inheritdoc IMoolahStaticTyping
  mapping(Id => MarketParams) public idToMarketParams;
  /// marketId => liquidation whitelist addresses
  mapping(Id => EnumerableSet.AddressSet) private liquidationWhitelist;
  /// The minimum loan token position value, using the same precision as the oracle (8 decimals).
  uint256 public minLoanValue;
  /// @inheritdoc IMoolahBase
  mapping(Id => mapping(address => address)) public providers;

  /// if whitelist is set, only whitelisted addresses can supply, supply collateral, borrow
  mapping(Id => EnumerableSet.AddressSet) private whiteList;

  bytes32 public constant MANAGER = keccak256("MANAGER"); // manager role
  bytes32 public constant PAUSER = keccak256("PAUSER"); // pauser role
  bytes32 public constant OPERATOR = keccak256("OPERATOR"); // operator role

  /* CONSTRUCTOR */

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
    DOMAIN_SEPARATOR = keccak256(abi.encode(DOMAIN_TYPEHASH, block.chainid, address(this)));
  }

  /// @param admin The new admin of the contract.
  /// @param manager The new manager of the contract.
  /// @param pauser The new pauser of the contract.
  function initialize(address admin, address manager, address pauser, uint256 _minLoanValue) public initializer {
    require(admin != address(0), ErrorsLib.ZERO_ADDRESS);
    require(manager != address(0), ErrorsLib.ZERO_ADDRESS);
    require(pauser != address(0), ErrorsLib.ZERO_ADDRESS);

    __Pausable_init();
    __AccessControl_init();
    __ReentrancyGuard_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MANAGER, manager);
    _grantRole(PAUSER, pauser);

    minLoanValue = _minLoanValue;
  }

  /* ONLY MANAGER FUNCTIONS */

  /// @inheritdoc IMoolahBase
  function enableIrm(address irm) external onlyRole(MANAGER) {
    require(!isIrmEnabled[irm], ErrorsLib.ALREADY_SET);

    isIrmEnabled[irm] = true;

    emit EventsLib.EnableIrm(irm);
  }

  /// @inheritdoc IMoolahBase
  function enableLltv(uint256 lltv) external onlyRole(MANAGER) {
    require(!isLltvEnabled[lltv], ErrorsLib.ALREADY_SET);
    require(lltv < WAD, ErrorsLib.MAX_LLTV_EXCEEDED);

    isLltvEnabled[lltv] = true;

    emit EventsLib.EnableLltv(lltv);
  }

  /// @inheritdoc IMoolahBase
  function setFee(MarketParams memory marketParams, uint256 newFee) external onlyRole(MANAGER) {
    Id id = marketParams.id();
    require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
    require(newFee != market[id].fee, ErrorsLib.ALREADY_SET);
    require(newFee <= MAX_FEE, ErrorsLib.MAX_FEE_EXCEEDED);

    // Accrue interest using the previous fee set before changing it.
    _accrueInterest(marketParams, id);

    // Safe "unchecked" cast.
    market[id].fee = uint128(newFee);

    emit EventsLib.SetFee(id, newFee);
  }

  /// @inheritdoc IMoolahBase
  function setFeeRecipient(address newFeeRecipient) external onlyRole(MANAGER) {
    require(newFeeRecipient != feeRecipient, ErrorsLib.ALREADY_SET);

    feeRecipient = newFeeRecipient;

    emit EventsLib.SetFeeRecipient(newFeeRecipient);
  }

  /// @inheritdoc IMoolahBase
  function setMinLoanValue(uint256 _minLoanValue) external onlyRole(MANAGER) {
    require(_minLoanValue != minLoanValue, ErrorsLib.ALREADY_SET);
    minLoanValue = _minLoanValue;

    emit EventsLib.SetMinLoanValue(_minLoanValue);
  }

  /// @inheritdoc IMoolahBase
  function addLiquidationWhitelist(Id id, address account) public onlyRole(MANAGER) {
    require(!liquidationWhitelist[id].contains(account), ErrorsLib.ALREADY_SET);
    liquidationWhitelist[id].add(account);

    emit EventsLib.AddLiquidationWhitelist(id, account);
  }

  /// @inheritdoc IMoolahBase
  function removeLiquidationWhitelist(Id id, address account) public onlyRole(MANAGER) {
    require(liquidationWhitelist[id].contains(account), ErrorsLib.NOT_SET);
    liquidationWhitelist[id].remove(account);

    emit EventsLib.RemoveLiquidationWhitelist(id, account);
  }

  /// @inheritdoc IMoolahBase
  function batchToggleLiquidationWhitelist(
    Id[] memory ids,
    address[][] memory accounts,
    bool isAddition
  ) external onlyRole(MANAGER) {
    require(ids.length == accounts.length, ErrorsLib.INCONSISTENT_INPUT);
    // add/remove accounts from liquidation whitelist for each market
    for (uint256 i = 0; i < ids.length; ++i) {
      Id id = ids[i];
      address[] memory accountList = accounts[i];
      for (uint256 j = 0; j < accountList.length; ++j) {
        address account = accountList[j];
        // add to whitelist
        if (isAddition) {
          addLiquidationWhitelist(id, account);
        } else {
          // remove from whitelist
          removeLiquidationWhitelist(id, account);
        }
      }
    }
  }

  /// @inheritdoc IMoolahBase
  function addWhiteList(Id id, address account) external onlyRole(MANAGER) {
    require(!whiteList[id].contains(account), ErrorsLib.ALREADY_SET);
    whiteList[id].add(account);

    emit EventsLib.AddWhiteList(id, account);
  }

  /// @inheritdoc IMoolahBase
  function removeWhiteList(Id id, address account) external onlyRole(MANAGER) {
    require(whiteList[id].contains(account), ErrorsLib.NOT_SET);
    whiteList[id].remove(account);

    emit EventsLib.RemoveWhiteList(id, account);
  }

  function addProvider(Id id, address provider) external onlyRole(MANAGER) {
    address token = IProvider(provider).TOKEN();
    require(token != address(0), ErrorsLib.ZERO_ADDRESS);
    require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
    require(provider != address(0), ErrorsLib.ZERO_ADDRESS);
    require(providers[id][token] == address(0), ErrorsLib.ALREADY_SET);

    providers[id][token] = provider;

    emit EventsLib.AddProvider(id, token, provider);
  }

  function removeProvider(Id id, address token) external onlyRole(MANAGER) {
    require(providers[id][token] != address(0), ErrorsLib.NOT_SET);

    address provider = providers[id][token];
    delete providers[id][token];

    emit EventsLib.RemoveProvider(id, token, provider);
  }

  /* MARKET CREATION */

  /// @inheritdoc IMoolahBase
  function createMarket(MarketParams memory marketParams) external {
    require(getRoleMemberCount(OPERATOR) == 0 || hasRole(OPERATOR, msg.sender), ErrorsLib.UNAUTHORIZED);
    Id id = marketParams.id();
    require(isIrmEnabled[marketParams.irm], ErrorsLib.IRM_NOT_ENABLED);
    require(isLltvEnabled[marketParams.lltv], ErrorsLib.LLTV_NOT_ENABLED);
    require(market[id].lastUpdate == 0, ErrorsLib.MARKET_ALREADY_CREATED);
    require(marketParams.oracle != address(0), ErrorsLib.ZERO_ADDRESS);
    require(marketParams.loanToken != address(0), ErrorsLib.ZERO_ADDRESS);
    require(marketParams.collateralToken != address(0), ErrorsLib.ZERO_ADDRESS);

    // Safe "unchecked" cast.
    market[id].lastUpdate = uint128(block.timestamp);
    market[id].fee = DEFAULT_FEE;
    idToMarketParams[id] = marketParams;
    IOracle(marketParams.oracle).peek(marketParams.loanToken);
    IOracle(marketParams.oracle).peek(marketParams.collateralToken);

    emit EventsLib.CreateMarket(id, marketParams);

    // Call to initialize the IRM in case it is stateful.
    if (marketParams.irm != address(0)) IIrm(marketParams.irm).borrowRate(marketParams, market[id]);
  }

  /* SUPPLY MANAGEMENT */

  /// @inheritdoc IMoolahBase
  function supply(
    MarketParams memory marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes calldata data
  ) external whenNotPaused nonReentrant returns (uint256, uint256) {
    Id id = marketParams.id();
    require(isWhiteList(id, onBehalf), ErrorsLib.NOT_WHITELIST);
    require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
    require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
    require(onBehalf != address(0), ErrorsLib.ZERO_ADDRESS);

    _accrueInterest(marketParams, id);

    if (assets > 0) shares = assets.toSharesDown(market[id].totalSupplyAssets, market[id].totalSupplyShares);
    else assets = shares.toAssetsUp(market[id].totalSupplyAssets, market[id].totalSupplyShares);

    position[id][onBehalf].supplyShares += shares;
    market[id].totalSupplyShares += shares.toUint128();
    market[id].totalSupplyAssets += assets.toUint128();

    emit EventsLib.Supply(id, msg.sender, onBehalf, assets, shares);

    if (data.length > 0) IMoolahSupplyCallback(msg.sender).onMoolahSupply(assets, data);

    IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);

    require(_checkSupplyAssets(marketParams, onBehalf), ErrorsLib.REMAIN_SUPPLY_TOO_LOW);

    return (assets, shares);
  }

  /// @inheritdoc IMoolahBase
  function withdraw(
    MarketParams memory marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    address receiver
  ) external whenNotPaused nonReentrant returns (uint256, uint256) {
    Id id = marketParams.id();
    require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
    require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
    require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
    // No need to verify that onBehalf != address(0) thanks to the following authorization check.
    require(_isSenderAuthorized(onBehalf), ErrorsLib.UNAUTHORIZED);

    _accrueInterest(marketParams, id);

    if (assets > 0) shares = assets.toSharesUp(market[id].totalSupplyAssets, market[id].totalSupplyShares);
    else assets = shares.toAssetsDown(market[id].totalSupplyAssets, market[id].totalSupplyShares);

    position[id][onBehalf].supplyShares -= shares;
    market[id].totalSupplyShares -= shares.toUint128();
    market[id].totalSupplyAssets -= assets.toUint128();

    require(market[id].totalBorrowAssets <= market[id].totalSupplyAssets, ErrorsLib.INSUFFICIENT_LIQUIDITY);

    emit EventsLib.Withdraw(id, msg.sender, onBehalf, receiver, assets, shares);

    IERC20(marketParams.loanToken).safeTransfer(receiver, assets);

    return (assets, shares);
  }

  /* BORROW MANAGEMENT */

  /// @inheritdoc IMoolahBase
  function borrow(
    MarketParams memory marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    address receiver
  ) external whenNotPaused nonReentrant returns (uint256, uint256) {
    Id id = marketParams.id();
    require(isWhiteList(id, onBehalf), ErrorsLib.NOT_WHITELIST);
    require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
    require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
    require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
    // No need to verify that onBehalf != address(0) thanks to the following authorization check.
    address provider = providers[id][marketParams.loanToken];
    if (provider == msg.sender) {
      require(receiver == provider, ErrorsLib.NOT_PROVIDER);
    } else {
      require(_isSenderAuthorized(onBehalf), ErrorsLib.UNAUTHORIZED);
    }

    _accrueInterest(marketParams, id);

    if (assets > 0) shares = assets.toSharesUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);
    else assets = shares.toAssetsDown(market[id].totalBorrowAssets, market[id].totalBorrowShares);

    position[id][onBehalf].borrowShares += shares.toUint128();
    market[id].totalBorrowShares += shares.toUint128();
    market[id].totalBorrowAssets += assets.toUint128();

    require(_isHealthy(marketParams, id, onBehalf), ErrorsLib.INSUFFICIENT_COLLATERAL);
    require(market[id].totalBorrowAssets <= market[id].totalSupplyAssets, ErrorsLib.INSUFFICIENT_LIQUIDITY);

    emit EventsLib.Borrow(id, msg.sender, onBehalf, receiver, assets, shares);

    IERC20(marketParams.loanToken).safeTransfer(receiver, assets);

    require(_checkBorrowAssets(marketParams, onBehalf), ErrorsLib.REMAIN_BORROW_TOO_LOW);

    return (assets, shares);
  }

  /// @inheritdoc IMoolahBase
  function repay(
    MarketParams memory marketParams,
    uint256 assets,
    uint256 shares,
    address onBehalf,
    bytes calldata data
  ) external whenNotPaused nonReentrant returns (uint256, uint256) {
    Id id = marketParams.id();
    require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
    require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
    require(onBehalf != address(0), ErrorsLib.ZERO_ADDRESS);

    _accrueInterest(marketParams, id);

    if (assets > 0) shares = assets.toSharesDown(market[id].totalBorrowAssets, market[id].totalBorrowShares);
    else assets = shares.toAssetsUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);

    position[id][onBehalf].borrowShares -= shares.toUint128();
    market[id].totalBorrowShares -= shares.toUint128();
    market[id].totalBorrowAssets = UtilsLib.zeroFloorSub(market[id].totalBorrowAssets, assets).toUint128();

    // `assets` may be greater than `totalBorrowAssets` by 1.
    emit EventsLib.Repay(id, msg.sender, onBehalf, assets, shares);

    if (data.length > 0) IMoolahRepayCallback(msg.sender).onMoolahRepay(assets, data);

    IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);

    require(_checkBorrowAssets(marketParams, onBehalf), ErrorsLib.REMAIN_BORROW_TOO_LOW);

    return (assets, shares);
  }

  /* COLLATERAL MANAGEMENT */

  /// @inheritdoc IMoolahBase
  function supplyCollateral(
    MarketParams memory marketParams,
    uint256 assets,
    address onBehalf,
    bytes calldata data
  ) external whenNotPaused nonReentrant {
    Id id = marketParams.id();
    require(isWhiteList(id, onBehalf), ErrorsLib.NOT_WHITELIST);
    require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
    require(assets != 0, ErrorsLib.ZERO_ASSETS);
    require(onBehalf != address(0), ErrorsLib.ZERO_ADDRESS);
    address provider = providers[id][marketParams.collateralToken];
    if (provider != address(0)) {
      require(msg.sender == provider, ErrorsLib.NOT_PROVIDER);
    }
    // Don't accrue interest because it's not required and it saves gas.

    position[id][onBehalf].collateral += assets.toUint128();

    emit EventsLib.SupplyCollateral(id, msg.sender, onBehalf, assets);

    if (data.length > 0) IMoolahSupplyCollateralCallback(msg.sender).onMoolahSupplyCollateral(assets, data);

    IERC20(marketParams.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
  }

  /// @inheritdoc IMoolahBase
  function withdrawCollateral(
    MarketParams memory marketParams,
    uint256 assets,
    address onBehalf,
    address receiver
  ) external whenNotPaused nonReentrant {
    Id id = marketParams.id();
    require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
    require(assets != 0, ErrorsLib.ZERO_ASSETS);
    require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
    // No need to verify that onBehalf != address(0) thanks to the following authorization check.
    address provider = providers[id][marketParams.collateralToken];
    if (provider != address(0)) {
      require(msg.sender == provider && receiver == provider, ErrorsLib.NOT_PROVIDER);
    } else {
      require(_isSenderAuthorized(onBehalf), ErrorsLib.UNAUTHORIZED);
    }

    _accrueInterest(marketParams, id);

    position[id][onBehalf].collateral -= assets.toUint128();

    require(_isHealthy(marketParams, id, onBehalf), ErrorsLib.INSUFFICIENT_COLLATERAL);

    emit EventsLib.WithdrawCollateral(id, msg.sender, onBehalf, receiver, assets);

    IERC20(marketParams.collateralToken).safeTransfer(receiver, assets);
  }

  /* LIQUIDATION */

  /// @inheritdoc IMoolahBase
  function liquidate(
    MarketParams memory marketParams,
    address borrower,
    uint256 seizedAssets,
    uint256 repaidShares,
    bytes calldata data
  ) external whenNotPaused nonReentrant returns (uint256, uint256) {
    Id id = marketParams.id();
    require(_checkLiquidationWhiteList(id, msg.sender), ErrorsLib.NOT_LIQUIDATION_WHITELIST);
    require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
    require(UtilsLib.exactlyOneZero(seizedAssets, repaidShares), ErrorsLib.INCONSISTENT_INPUT);

    _accrueInterest(marketParams, id);

    {
      uint256 collateralPrice = getPrice(marketParams);

      require(!_isHealthy(marketParams, id, borrower, collateralPrice), ErrorsLib.HEALTHY_POSITION);

      // The liquidation incentive factor is min(maxLiquidationIncentiveFactor, 1/(1 - cursor*(1 - lltv))).
      uint256 liquidationIncentiveFactor = UtilsLib.min(
        MAX_LIQUIDATION_INCENTIVE_FACTOR,
        WAD.wDivDown(WAD - LIQUIDATION_CURSOR.wMulDown(WAD - marketParams.lltv))
      );

      if (seizedAssets > 0) {
        uint256 seizedAssetsQuoted = seizedAssets.mulDivUp(collateralPrice, ORACLE_PRICE_SCALE);

        repaidShares = seizedAssetsQuoted.wDivUp(liquidationIncentiveFactor).toSharesUp(
          market[id].totalBorrowAssets,
          market[id].totalBorrowShares
        );
      } else {
        seizedAssets = repaidShares
          .toAssetsDown(market[id].totalBorrowAssets, market[id].totalBorrowShares)
          .wMulDown(liquidationIncentiveFactor)
          .mulDivDown(ORACLE_PRICE_SCALE, collateralPrice);
      }
    }
    uint256 repaidAssets = repaidShares.toAssetsUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);

    position[id][borrower].borrowShares -= repaidShares.toUint128();
    market[id].totalBorrowShares -= repaidShares.toUint128();
    market[id].totalBorrowAssets = UtilsLib.zeroFloorSub(market[id].totalBorrowAssets, repaidAssets).toUint128();

    position[id][borrower].collateral -= seizedAssets.toUint128();

    uint256 badDebtShares;
    uint256 badDebtAssets;
    if (position[id][borrower].collateral == 0) {
      badDebtShares = position[id][borrower].borrowShares;
      badDebtAssets = UtilsLib.min(
        market[id].totalBorrowAssets,
        badDebtShares.toAssetsUp(market[id].totalBorrowAssets, market[id].totalBorrowShares)
      );

      market[id].totalBorrowAssets -= badDebtAssets.toUint128();
      market[id].totalSupplyAssets -= badDebtAssets.toUint128();
      market[id].totalBorrowShares -= badDebtShares.toUint128();
      position[id][borrower].borrowShares = 0;
    }

    // `repaidAssets` may be greater than `totalBorrowAssets` by 1.
    emit EventsLib.Liquidate(
      id,
      msg.sender,
      borrower,
      repaidAssets,
      repaidShares,
      seizedAssets,
      badDebtAssets,
      badDebtShares
    );

    IERC20(marketParams.collateralToken).safeTransfer(msg.sender, seizedAssets);

    {
      address provider = providers[id][marketParams.collateralToken];
      if (provider != address(0)) {
        IProvider(provider).liquidate(id, borrower);
      }
    }

    if (data.length > 0) IMoolahLiquidateCallback(msg.sender).onMoolahLiquidate(repaidAssets, data);

    IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), repaidAssets);

    require(_isHealthyAfterLiquidate(marketParams, borrower), ErrorsLib.UNHEALTHY_POSITION);

    return (seizedAssets, repaidAssets);
  }

  /* FLASH LOANS */

  /// @inheritdoc IMoolahBase
  function flashLoan(address token, uint256 assets, bytes calldata data) external whenNotPaused {
    require(assets != 0, ErrorsLib.ZERO_ASSETS);

    emit EventsLib.FlashLoan(msg.sender, token, assets);

    IERC20(token).safeTransfer(msg.sender, assets);

    IMoolahFlashLoanCallback(msg.sender).onMoolahFlashLoan(assets, data);

    IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
  }

  /* AUTHORIZATION */

  /// @inheritdoc IMoolahBase
  function setAuthorization(address authorized, bool newIsAuthorized) external {
    require(newIsAuthorized != isAuthorized[msg.sender][authorized], ErrorsLib.ALREADY_SET);

    isAuthorized[msg.sender][authorized] = newIsAuthorized;

    emit EventsLib.SetAuthorization(msg.sender, msg.sender, authorized, newIsAuthorized);
  }

  /// @inheritdoc IMoolahBase
  function setAuthorizationWithSig(Authorization memory authorization, Signature calldata signature) external {
    /// Do not check whether authorization is already set because the nonce increment is a desired side effect.
    require(block.timestamp <= authorization.deadline, ErrorsLib.SIGNATURE_EXPIRED);
    require(authorization.nonce == nonce[authorization.authorizer]++, ErrorsLib.INVALID_NONCE);

    bytes32 hashStruct = keccak256(abi.encode(AUTHORIZATION_TYPEHASH, authorization));
    bytes32 digest = keccak256(bytes.concat("\x19\x01", DOMAIN_SEPARATOR, hashStruct));
    address signatory = ecrecover(digest, signature.v, signature.r, signature.s);

    require(signatory != address(0) && authorization.authorizer == signatory, ErrorsLib.INVALID_SIGNATURE);

    emit EventsLib.IncrementNonce(msg.sender, authorization.authorizer, authorization.nonce);

    isAuthorized[authorization.authorizer][authorization.authorized] = authorization.isAuthorized;

    emit EventsLib.SetAuthorization(
      msg.sender,
      authorization.authorizer,
      authorization.authorized,
      authorization.isAuthorized
    );
  }

  /// @dev Returns whether the sender is authorized to manage `onBehalf`'s positions.
  function _isSenderAuthorized(address onBehalf) internal view returns (bool) {
    return msg.sender == onBehalf || isAuthorized[onBehalf][msg.sender];
  }

  /* INTEREST MANAGEMENT */

  /// @inheritdoc IMoolahBase
  function accrueInterest(MarketParams memory marketParams) external {
    Id id = marketParams.id();
    require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);

    _accrueInterest(marketParams, id);
  }

  /// @dev Accrues interest for the given market `marketParams`.
  /// @dev Assumes that the inputs `marketParams` and `id` match.
  function _accrueInterest(MarketParams memory marketParams, Id id) internal {
    uint256 elapsed = block.timestamp - market[id].lastUpdate;
    if (elapsed == 0) return;

    if (marketParams.irm != address(0)) {
      uint256 borrowRate = IIrm(marketParams.irm).borrowRate(marketParams, market[id]);
      uint256 interest = market[id].totalBorrowAssets.wMulDown(borrowRate.wTaylorCompounded(elapsed));
      market[id].totalBorrowAssets += interest.toUint128();
      market[id].totalSupplyAssets += interest.toUint128();

      uint256 feeShares;
      if (market[id].fee != 0) {
        uint256 feeAmount = interest.wMulDown(market[id].fee);
        // The fee amount is subtracted from the total supply in this calculation to compensate for the fact
        // that total supply is already increased by the full interest (including the fee amount).
        feeShares = feeAmount.toSharesDown(market[id].totalSupplyAssets - feeAmount, market[id].totalSupplyShares);
        position[id][feeRecipient].supplyShares += feeShares;
        market[id].totalSupplyShares += feeShares.toUint128();
      }

      emit EventsLib.AccrueInterest(id, borrowRate, interest, feeShares);
    }

    // Safe "unchecked" cast.
    market[id].lastUpdate = uint128(block.timestamp);
  }

  /* HEALTH CHECK */

  /// @dev Returns whether the position of `borrower` in the given market `marketParams` is healthy.
  /// @dev Assumes that the inputs `marketParams` and `id` match.
  function _isHealthy(MarketParams memory marketParams, Id id, address borrower) internal view returns (bool) {
    if (position[id][borrower].borrowShares == 0) return true;
    uint256 collateralPrice = getPrice(marketParams);

    return _isHealthy(marketParams, id, borrower, collateralPrice);
  }

  /// @dev Returns whether the position of `borrower` in the given market `marketParams` is healthy.
  /// @dev Assumes that the inputs `marketParams` and `id` match.
  function isHealthy(MarketParams memory marketParams, Id id, address borrower) external view returns (bool) {
    return _isHealthy(marketParams, id, borrower);
  }

  /// @dev Returns whether the position of `borrower` in the given market `marketParams` with the given
  /// `collateralPrice` is healthy.
  /// @dev Assumes that the inputs `marketParams` and `id` match.
  /// @dev Rounds in favor of the protocol, so one might not be able to borrow exactly `maxBorrow` but one unit less.
  function _isHealthy(
    MarketParams memory marketParams,
    Id id,
    address borrower,
    uint256 collateralPrice
  ) internal view returns (bool) {
    uint256 borrowed = uint256(position[id][borrower].borrowShares).toAssetsUp(
      market[id].totalBorrowAssets,
      market[id].totalBorrowShares
    );
    uint256 maxBorrow = uint256(position[id][borrower].collateral)
      .mulDivDown(collateralPrice, ORACLE_PRICE_SCALE)
      .wMulDown(marketParams.lltv);

    return maxBorrow >= borrowed;
  }

  function getPrice(MarketParams memory marketParams) public view returns (uint256) {
    IOracle _oracle = IOracle(marketParams.oracle);
    uint256 baseTokenDecimals = IERC20Metadata(marketParams.collateralToken).decimals();
    uint256 quotaTokenDecimals = IERC20Metadata(marketParams.loanToken).decimals();
    uint256 basePrice = _oracle.peek(marketParams.collateralToken);
    uint256 quotaPrice = _oracle.peek(marketParams.loanToken);

    uint256 scaleFactor = 10 ** (36 + quotaTokenDecimals - baseTokenDecimals);
    return scaleFactor.mulDivDown(basePrice, quotaPrice);
  }

  /// @inheritdoc IMoolahBase
  function getWhiteList(Id id) external view returns (address[] memory) {
    return whiteList[id].values();
  }

  /// @inheritdoc IMoolahBase
  function isWhiteList(Id id, address account) public view returns (bool) {
    return whiteList[id].length() == 0 || whiteList[id].contains(account);
  }

  /// @inheritdoc IMoolahBase
  function getLiquidationWhitelist(Id id) external view returns (address[] memory) {
    address[] memory whitelist = new address[](liquidationWhitelist[id].length());
    for (uint256 i = 0; i < liquidationWhitelist[id].length(); i++) {
      whitelist[i] = liquidationWhitelist[id].at(i);
    }
    return whitelist;
  }

  /// @inheritdoc IMoolahBase
  function isLiquidationWhitelist(Id id, address account) external view returns (bool) {
    return _checkLiquidationWhiteList(id, account);
  }

  function _checkLiquidationWhiteList(Id id, address account) internal view returns (bool) {
    return liquidationWhitelist[id].length() == 0 || liquidationWhitelist[id].contains(account);
  }

  function _checkSupplyAssets(MarketParams memory marketParams, address account) internal view returns (bool) {
    Id id = marketParams.id();
    if (position[id][account].supplyShares == 0) {
      return true;
    }

    return
      uint256(position[id][account].supplyShares).toAssetsDown(
        market[id].totalSupplyAssets,
        market[id].totalSupplyShares
      ) >= minLoan(marketParams);
  }

  function _checkBorrowAssets(MarketParams memory marketParams, address account) internal view returns (bool) {
    Id id = marketParams.id();
    if (position[id][account].borrowShares == 0) {
      return true;
    }

    return
      uint256(position[id][account].borrowShares).toAssetsDown(
        market[id].totalBorrowAssets,
        market[id].totalBorrowShares
      ) >= minLoan(marketParams);
  }

  function _isHealthyAfterLiquidate(MarketParams memory marketParams, address account) internal view returns (bool) {
    Id id = marketParams.id();
    if (position[id][account].borrowShares == 0 || position[id][account].collateral == 0) {
      return true;
    }

    uint256 borrowAssets = uint256(position[id][account].borrowShares).toAssetsDown(
      market[id].totalBorrowAssets,
      market[id].totalBorrowShares
    );
    if (borrowAssets >= minLoan(marketParams)) {
      return true;
    }
    return _isHealthy(marketParams, marketParams.id(), account, getPrice(marketParams));
  }

  /// @inheritdoc IMoolahBase
  function minLoan(MarketParams memory marketParams) public view returns (uint256) {
    uint256 price = IOracle(marketParams.oracle).peek(marketParams.loanToken);
    uint8 decimals = IERC20Metadata(marketParams.loanToken).decimals();
    return price == 0 ? 0 : minLoanValue.mulDivDown(10 ** decimals, price);
  }

  /**
   * @dev pause contract
   */
  function pause() external onlyRole(PAUSER) {
    _pause();
  }

  /**
   * @dev unpause contract
   */
  function unpause() external onlyRole(MANAGER) {
    _unpause();
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
