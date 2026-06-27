// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {JimboController} from "./JimboController.sol";

/// @notice ERC4626 for JIMBO.
/// @dev    previewWithdraw and previewRedeem function DO NOT WORK PROPERLY.
///         This is due to reflection fee in withdraw and redeem being bricked.
///         DO NOT USE THOSE FUNCTIONS FOR FRONTENDS.
contract UltraJimbo is ERC4626 {
    using SafeTransferLib for ERC20;

    error CooldownNotFinished();
    error OnlyTransfersWithController();
    error BalanceLowerThanPrincipal();
    error UseWithdraw();

    event Exit(address indexed user, uint256 assets_, uint256 shares_);

    address public controller;

    /// @notice Reflection fee applied on withdraws which accrues to
    /// remaining stakers.
    uint256 public constant REFLECTION_FEE = 5; // 0.5%

    constructor(
        address asset_
    ) ERC4626(ERC20(asset_), "ULTRA JIMBO", "uJIMBO") {
        controller = msg.sender;
    }

    /// @notice Locking all transfers not involving controller.
    function transfer(
        address recipient_,
        uint256 amount_
    ) public override returns (bool) {
        if (msg.sender != controller && recipient_ != controller)
            revert OnlyTransfersWithController();
        return super.transfer(recipient_, amount_);
    }

    /// @notice Locking all transfers not involving controller.
    function transferFrom(
        address sender_,
        address recipient_,
        uint256 amount_
    ) public override returns (bool) {
        if (sender_ != controller && recipient_ != controller)
            revert OnlyTransfersWithController();
        return super.transferFrom(sender_, recipient_, amount_);
    }

    function withdraw(
        uint256 assets_,
        address receiver_,
        address owner_
    ) public override returns (uint256 shares) {
        // Subtract reflection fee from withdrawn amount. Fee stays in
        // vault, accruing to remaining stakers.
        uint256 assetsMinusFee = (assets_ * (1000 - REFLECTION_FEE)) / 1000;

        shares = previewWithdraw(assetsMinusFee); // No need to check for rounding error, previewWithdraw rounds up.

        if (msg.sender != owner_) {
            uint256 allowed = allowance[owner_][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max)
                allowance[owner_][msg.sender] = allowed - shares;
        }

        beforeWithdraw(assetsMinusFee, shares);

        _burn(owner_, shares);

        emit Withdraw(msg.sender, receiver_, owner_, assetsMinusFee, shares);

        asset.safeTransfer(receiver_, assetsMinusFee);
    }

    /// @notice Don't redeem, use withdraw.
    function redeem(
        uint256 shares_,
        address receiver_,
        address owner_
    ) public override returns (uint256 assets) {
        revert UseWithdraw();
    }

    /// @notice Call rebalance
    function afterDeposit(uint256 assets_, uint256 shares_) internal override {
        // Need to check for controller otherwise breaks in constructor
        if (msg.sender != controller) JimboController(controller).rebalance();
    }

    /// @notice Only call rebalance.
    function beforeWithdraw(
        uint256 assets_,
        uint256 shares_
    ) internal override {
        JimboController(controller).rebalance();
    }

    function totalAssets() public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }
}
