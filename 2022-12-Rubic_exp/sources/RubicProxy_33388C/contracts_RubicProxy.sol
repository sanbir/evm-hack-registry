// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

/**

  ██████╗ ██╗   ██╗██████╗ ██╗ ██████╗    ██████╗ ██████╗  ██████╗ ██╗  ██╗██╗   ██╗
  ██╔══██╗██║   ██║██╔══██╗██║██╔════╝    ██╔══██╗██╔══██╗██╔═══██╗╚██╗██╔╝╚██╗ ██╔╝
  ██████╔╝██║   ██║██████╔╝██║██║         ██████╔╝██████╔╝██║   ██║ ╚███╔╝  ╚████╔╝
  ██╔══██╗██║   ██║██╔══██╗██║██║         ██╔═══╝ ██╔══██╗██║   ██║ ██╔██╗   ╚██╔╝
  ██║  ██║╚██████╔╝██████╔╝██║╚██████╗    ██║     ██║  ██║╚██████╔╝██╔╝ ██╗   ██║
  ╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚═╝ ╚═════╝    ╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝   ╚═╝

*/

import 'rubic-bridge-base/contracts/architecture/OnlySourceFunctionality.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol';
import 'rubic-bridge-base/contracts/errors/Errors.sol';

error DifferentAmountSpent();
error RouterNotAvailable();

/**
    @title RubicProxy
    @author Vladislav Yaroshuk
    @author George Eliseev
    @notice Universal proxy contract to Symbiosis, LiFi, deBridge and other cross-chain solutions
 */
contract RubicProxy is OnlySourceFunctionality {
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    constructor(
        uint256 _fixedCryptoFee,
        uint256 _RubicPlatformFee,
        address[] memory _routers,
        address[] memory _tokens,
        uint256[] memory _minTokenAmounts,
        uint256[] memory _maxTokenAmounts
    ) {
        initialize(_fixedCryptoFee, _RubicPlatformFee, _routers, _tokens, _minTokenAmounts, _maxTokenAmounts);
    }

    function initialize(
        uint256 _fixedCryptoFee,
        uint256 _RubicPlatformFee,
        address[] memory _routers,
        address[] memory _tokens,
        uint256[] memory _minTokenAmounts,
        uint256[] memory _maxTokenAmounts
    ) private initializer {
        __OnlySourceFunctionalityInit(
            _fixedCryptoFee,
            _RubicPlatformFee,
            _routers,
            _tokens,
            _minTokenAmounts,
            _maxTokenAmounts
        );
    }

    function routerCall(
        string calldata _providerInfo,
        BaseCrossChainParams calldata _params,
        address _gateway,
        bytes calldata _data
    ) external payable nonReentrant whenNotPaused eventEmitter(_params, _providerInfo) {
        if (!(availableRouters.contains(_params.router) && availableRouters.contains(_gateway))) {
            revert RouterNotAvailable();
        }

        uint256 balanceBeforeTransfer = IERC20Upgradeable(_params.srcInputToken).balanceOf(address(this));
        IERC20Upgradeable(_params.srcInputToken).safeTransferFrom(msg.sender, address(this), _params.srcInputAmount);
        uint256 balanceAfterTransfer = IERC20Upgradeable(_params.srcInputToken).balanceOf(address(this));

        // input amount for deflationary tokens
        uint256 _amountIn = balanceAfterTransfer - balanceBeforeTransfer;

        IntegratorFeeInfo memory _info = integratorToFeeInfo[_params.integrator];

        _amountIn = accrueTokenFees(_params.integrator, _info, _amountIn, 0, _params.srcInputToken);

        SafeERC20Upgradeable.safeIncreaseAllowance(IERC20Upgradeable(_params.srcInputToken), _gateway, _amountIn);

        AddressUpgradeable.functionCallWithValue(
            _params.router,
            _data,
            accrueFixedCryptoFee(_params.integrator, _info)
        );

        if (balanceAfterTransfer - IERC20Upgradeable(_params.srcInputToken).balanceOf(address(this)) != _amountIn) {
            revert DifferentAmountSpent();
        }

        // reset allowance back to zero, just in case
        if (IERC20Upgradeable(_params.srcInputToken).allowance(address(this), _gateway) > 0) {
            IERC20Upgradeable(_params.srcInputToken).safeApprove(_gateway, 0);
        }
    }

    function routerCallNative(
        string calldata _providerInfo,
        BaseCrossChainParams calldata _params,
        bytes calldata _data
    ) external payable nonReentrant whenNotPaused eventEmitter(_params, _providerInfo) {
        if (!availableRouters.contains(_params.router)) {
            revert RouterNotAvailable();
        }

        IntegratorFeeInfo memory _info = integratorToFeeInfo[_params.integrator];

        uint256 _amountIn = accrueTokenFees(
            _params.integrator,
            _info,
            accrueFixedCryptoFee(_params.integrator, _info),
            0,
            address(0)
        );

        AddressUpgradeable.functionCallWithValue(_params.router, _data, _amountIn);
    }

    function sweepTokens(address _token, uint256 _amount) external onlyAdmin {
        sendToken(_token, _amount, msg.sender);
    }
}
