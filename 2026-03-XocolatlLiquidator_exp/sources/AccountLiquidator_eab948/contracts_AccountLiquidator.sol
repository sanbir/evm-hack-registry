// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

/**
 * @title Account Liquidator
 * @author xocolatl.eth
 * @notice  Allows liquidation of users.
 */
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20Extension} from "./interfaces/IERC20Extension.sol";
import {IAssetsAccountant} from "./interfaces/IAssetsAccountant.sol";
import {IHouseOfCoin} from "./interfaces/IHouseOfCoin.sol";
import {IHouseOfReserve} from "./interfaces/IHouseOfReserve.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract AccountLiquidator is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    /**
     * @dev Log when a user is in the danger zone of being liquidated.
     * @param user Address of user that is on margin call.
     * @param mintedAsset ERC20 address of user's token debt on margin call.
     * @param reserveAsset ERC20 address of user's backing collateral.
     */
    event MarginCall(address indexed user, address indexed mintedAsset, address indexed reserveAsset);

    /**
     * @dev Log when a user is liquidated.
     * @param userLiquidated Address of user that is being liquidated.
     * @param liquidator Address of user that liquidates.
     * @param collateralAmount sold.
     */
    event Liquidation(
        address indexed userLiquidated,
        address indexed liquidator,
        uint256 collateralAmount,
        uint256 debtAmount
    );

    /// Custom errors
    error AccountLiquidator_invalidInput();
    error AccountLiquidator_notApplicable();
    error AccountLiquidator_noBalances();
    error AccountLiquidator_notLiquidatable();

    IAssetsAccountant public assetsAccountant;
    IHouseOfCoin public houseOfCoin;
    IERC20Extension public backedAsset;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address houseOfCoin_, address assetsAccountant_) public initializer {
        if (houseOfCoin_ == address(0) || assetsAccountant_ == address(0)) {
            revert AccountLiquidator_invalidInput();
        }

        houseOfCoin = IHouseOfCoin(houseOfCoin_);
        assetsAccountant = IAssetsAccountant(assetsAccountant_);
        backedAsset = IERC20Extension(houseOfCoin.backedAsset());

        __Ownable_init();
        __UUPSUpgradeable_init();
    }

    /**
     * @dev Call latest price from applicable HouseOfReserve
     * @param hOfReserve_ address to get applicable price feed
     */
    function getLatestPrice(address hOfReserve_) public view returns (uint256 price) {
        price = IHouseOfReserve(hOfReserve_).getLatestPrice();
    }

    /**
     * @dev Called to liquidate a user or publish margin call event.
     * @param userToLiquidate address to liquidate.
     * @param houseOfReserve address in where user has collateral backing debt.
     */
    function liquidateUser(address userToLiquidate, address houseOfReserve) external {
        // Get all the required inputs.
        IHouseOfReserve hOfReserve = IHouseOfReserve(houseOfReserve);
        address reserveAsset = hOfReserve.reserveAsset();

        uint256 reserveTokenID_ = hOfReserve.reserveTokenID();
        uint256 backedTokenID_ = hOfReserve.backedTokenID();

        (uint256 reserveBal, ) = _checkBalances(userToLiquidate, reserveTokenID_, backedTokenID_);

        uint256 latestPrice = getLatestPrice(houseOfReserve);

        uint256 reserveAssetDecimals = IERC20Extension(reserveAsset).decimals();

        // Get health ratio
        uint256 healthRatio = houseOfCoin.computeUserHealthRatio(userToLiquidate, houseOfReserve);

        IHouseOfCoin.LiquidationParam memory liqParam = houseOfCoin.getLiqParams();

        // User on marginCall
        if (healthRatio <= liqParam.marginCallThreshold) {
            emit MarginCall(userToLiquidate, address(backedAsset), reserveAsset);
            // User at liquidation level
            if (healthRatio <= liqParam.liquidationThreshold) {
                // check liquidator ERC20 approval
                (uint256 costofLiquidation, uint256 collatPenaltyBal) = _computeCostOfLiquidation(
                    reserveBal,
                    latestPrice,
                    reserveAssetDecimals,
                    liqParam
                );
                require(backedAsset.allowance(msg.sender, address(this)) >= costofLiquidation, "No allowance!");

                _executeLiquidation(
                    userToLiquidate,
                    reserveTokenID_,
                    backedTokenID_,
                    costofLiquidation,
                    collatPenaltyBal
                );
            }
        } else {
            revert AccountLiquidator_notLiquidatable();
        }
    }

    /**
     * @notice  Function to get the theoretical cost of liquidating a user.
     * @param user address.
     * * @param houseOfReserve address in where user has collateral backing debt.
     */
    function computeCostOfLiquidation(
        address user,
        address houseOfReserve
    ) public view returns (uint256 costAmount, uint256 collateralAtPenalty) {
        // Get all the required inputs.
        // Get all the required inputs.
        IHouseOfReserve hOfReserve = IHouseOfReserve(houseOfReserve);

        uint256 reserveTokenID_ = hOfReserve.reserveTokenID();
        uint256 backedTokenID_ = hOfReserve.backedTokenID();

        (uint256 reserveBal, ) = _checkBalances(user, reserveTokenID_, backedTokenID_);
        if (reserveBal == 0) {
            revert AccountLiquidator_noBalances();
        }

        uint256 latestPrice = getLatestPrice(houseOfReserve);

        uint256 reserveAssetDecimals = IERC20Extension(hOfReserve.reserveAsset()).decimals();

        IHouseOfCoin.LiquidationParam memory liqParam = houseOfCoin.getLiqParams();

        (costAmount, collateralAtPenalty) = _computeCostOfLiquidation(
            reserveBal,
            latestPrice,
            reserveAssetDecimals,
            liqParam
        );

        return (costAmount, collateralAtPenalty);
    }

    /**
     * @dev  Internal function to query balances in {AssetsAccountant}
     */
    function _checkBalances(
        address user,
        uint256 reservesTokenID_,
        uint256 bAssetRTokenID_
    ) internal view returns (uint256 reserveBal, uint256 mintedCoinBal) {
        reserveBal = assetsAccountant.balanceOf(user, reservesTokenID_);
        mintedCoinBal = assetsAccountant.balanceOf(user, bAssetRTokenID_);
    }

    function _computeCostOfLiquidation(
        uint256 reserveBal,
        uint256 price,
        uint256 reserveAssetDecimals,
        IHouseOfCoin.LiquidationParam memory liqParam_
    ) internal view returns (uint256 costofLiquidation, uint256 collatPenaltyBal) {
        uint256 discount = 1e18 - liqParam_.liquidationPricePenaltyDiscount;
        uint256 liqDiscountedPrice = (price * discount) / 1e18;

        collatPenaltyBal = (reserveBal * liqParam_.collateralPenalty) / 1e18;

        uint256 amountTemp = (collatPenaltyBal * liqDiscountedPrice) / 10 ** 8;

        uint256 decimalDiff;
        uint256 backedAssetDecimals = backedAsset.decimals();

        if (reserveAssetDecimals > backedAssetDecimals) {
            decimalDiff = reserveAssetDecimals - backedAssetDecimals;
            amountTemp = amountTemp / 10 ** decimalDiff;
        } else {
            decimalDiff = backedAssetDecimals - reserveAssetDecimals;
            amountTemp = amountTemp * 10 ** decimalDiff;
        }

        costofLiquidation = amountTemp;
    }

    function _executeLiquidation(
        address user,
        uint256 reserveTokenID,
        uint256 backedTokenID,
        uint256 costofLiquidation,
        uint256 collatPenaltyBal
    ) internal {
        // Transfer of Assets.

        // BackedAsset to this contract.
        backedAsset.transferFrom(msg.sender, address(this), costofLiquidation);
        // Penalty collateral from liquidated user to liquidator.
        assetsAccountant.safeTransferFrom(user, msg.sender, reserveTokenID, collatPenaltyBal, "");

        // Burning tokens and debt.
        // Burn 'costofLiquidation' debt amount from liquidated user in {AssetsAccountant}
        assetsAccountant.burn(user, backedTokenID, costofLiquidation);

        // Burn the received backedAsset tokens.
        IERC20Extension bAsset = IERC20Extension(backedAsset);
        bAsset.burn(address(this), costofLiquidation);

        // Emit event
        emit Liquidation(user, msg.sender, collatPenaltyBal, costofLiquidation);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
