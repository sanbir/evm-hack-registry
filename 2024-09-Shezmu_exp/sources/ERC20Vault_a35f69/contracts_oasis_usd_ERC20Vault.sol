// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import '@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol';

import '../../interfaces/IStableCoin.sol';
import '../../interfaces/IStrategy.sol';
import '../../utils/RateLib.sol';
import {ERC20ValueProvider} from './ERC20ValueProvider.sol';
import {AbstractAssetVault} from './AbstractAssetVault.sol';

/// @title ERC20 lending vault
/// @notice This contracts allows users to borrow ShezmuUSD using ERC20 tokens as collateral.
/// The price of the collateral token is fetched using a chainlink oracle
contract ERC20Vault is AbstractAssetVault {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeERC20Upgradeable for IStableCoin;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;
    using RateLib for RateLib.Rate;
    /// @notice The Shezmu trait boost locker contract
    address public valueProvider;

    IERC20Upgradeable public tokenContract;

    IStrategy public strategy;

    /// @notice This function is only called once during deployment of the proxy contract. It's not called after upgrades.
    /// @param _stablecoin ShezUSD address
    /// @param _tokenContract The collateral token address
    /// @param _valueProvider The collateral token value provider
    /// @param _settings Initial settings used by the contract
    function initialize(
        IStableCoin _stablecoin,
        IERC20Upgradeable _tokenContract,
        IStrategy _strategy,
        address _valueProvider,
        VaultSettings calldata _settings
    ) external virtual initializer {
        __initialize(_stablecoin, _settings);
        tokenContract = _tokenContract;
        valueProvider = _valueProvider;
        strategy = _strategy;
    }

    function setValueProvider(
        address _valueProvider
    ) external onlyRole(SETTER_ROLE) {
        valueProvider = _valueProvider;
    }

    /// @dev See {addCollateral}
    function _addCollateral(
        address _account,
        address _onBehalfOf,
        uint256 _colAmount
    ) internal override {
        if (_colAmount == 0) revert InvalidAmount(_colAmount);

        tokenContract.safeTransferFrom(_account, address(this), _colAmount);
        uint share = _colAmount;
        if (address(strategy) != address(0)) {
            tokenContract.safeApprove(address(strategy), _colAmount);
            share = strategy.deposit(_onBehalfOf, _colAmount);
        }

        Position storage position = positions[_onBehalfOf];

        if (!userIndexes.contains(_onBehalfOf)) {
            userIndexes.add(_onBehalfOf);
        }
        position.collateral += share;

        emit CollateralAdded(_onBehalfOf, _colAmount);
    }

    /// @dev See {removeCollateral}
    function _removeCollateral(
        address _account,
        uint256 _colShare
    ) internal override {
        Position storage position = positions[_account];

        uint256 _debtAmount = _getDebtAmount(_account);
        uint256 _creditLimit = _getCreditLimit(
            _account,
            position.collateral - _colShare
        );

        if (_debtAmount > _creditLimit) revert InsufficientCollateral();

        uint withdrawn = _colShare;
        if (address(strategy) != address(0)) {
            withdrawn = strategy.withdraw(_account, _colShare);
        }
        position.collateral -= _colShare;

        if (position.collateral == 0) {
            delete positions[_account];
            userIndexes.remove(_account);
        }

        tokenContract.safeTransfer(_account, withdrawn);

        emit CollateralRemoved(_account, withdrawn);
    }

    /// @dev See {liquidate}
    function _liquidate(
        address _account,
        address _owner,
        address _recipient
    ) internal override {
        _checkRole(LIQUIDATOR_ROLE, _account);

        Position storage position = positions[_owner];
        uint256 colAmount = position.collateral;

        uint256 debtAmount = _getDebtAmount(_owner);
        if (debtAmount < _getLiquidationLimit(_owner, position.collateral))
            revert InvalidPosition(_owner);

        // burn all payment
        stablecoin.burnFrom(_account, debtAmount);

        // update debt portion
        totalDebtPortion -= position.debtPortion;
        totalDebtAmount -= debtAmount;
        position.debtPortion = 0;

        // transfer collateral to liquidator
        delete positions[_owner];
        userIndexes.remove(_owner);
        tokenContract.safeTransfer(_recipient, colAmount);

        emit Liquidated(_account, _owner, colAmount);
    }

    /// @dev Returns the credit limit
    /// @param _owner The position owner
    /// @param _colAmount The collateral amount
    /// @return creditLimitUSD The credit limit
    function _getCreditLimit(
        address _owner,
        uint256 _colAmount
    ) internal view virtual override returns (uint256 creditLimitUSD) {
        uint _uAmount = _colAmount;
        if (address(strategy) != address(0)) {
            _uAmount = strategy.toAmount(_colAmount);
        }
        creditLimitUSD = ERC20ValueProvider(valueProvider).getCreditLimitUSD(
            _owner,
            _uAmount
        );
    }

    /// @dev Returns the minimum amount of debt necessary to liquidate the position
    /// @param _owner The position owner
    /// @param _colAmount The collateral amount
    /// @return liquidationLimitUSD The minimum amount of debt to liquidate the position
    function _getLiquidationLimit(
        address _owner,
        uint256 _colAmount
    ) internal view virtual override returns (uint256 liquidationLimitUSD) {
        uint _uAmount = _colAmount;
        if (address(strategy) != address(0)) {
            _uAmount = strategy.toAmount(_colAmount);
        }
        liquidationLimitUSD = ERC20ValueProvider(valueProvider)
            .getLiquidationLimitUSD(_owner, _uAmount);
    }
}
