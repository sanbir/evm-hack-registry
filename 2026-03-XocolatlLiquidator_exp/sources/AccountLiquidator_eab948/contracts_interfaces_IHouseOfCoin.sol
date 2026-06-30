// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

interface IHouseOfCoin {
    struct LiquidationParam {
        uint256 marginCallThreshold;
        uint256 liquidationThreshold;
        uint256 liquidationPricePenaltyDiscount;
        uint256 collateralPenalty;
    }

    /**
     * @dev Returns the type of House Contract.
     */
    function HOUSE_TYPE() external returns (bytes32);

    /**
     * @dev Returns the backedAsset that is minted by this HouseOfCoin.
     */
    function backedAsset() external view returns (address);

    /**
     * @dev Returns the treasury address of this HouseOfCoin.
     */
    function treasury() external view returns (address);

    /**
     * @notice  Function to mint ERC20 'backedAsset' of this HouseOfCoin.
     * @dev  Requires user to have reserves for this backed asset at HouseOfReserves.
     * @param reserveAsset ERC20 address of asset to be used to back the minted coins.
     * @param houseOfReserve Address of the {HouseOfReserves} contract that manages the 'reserveAsset'.
     * @param amount To mint.
     * Emits a {CoinMinted} event.
     */
    function mintCoin(address reserveAsset, address houseOfReserve, uint256 amount) external;

    /**
     * @notice  Function to payback ERC20 'backedAsset' of this HouseOfCoin.
     * @dev Requires knowledge of the reserve asset used to back the minted coins.
     * @param _backedTokenID Token Id in {AssetsAccountant}, releases the reserve asset used in 'getTokenID'.
     * @param amount To payback.
     * Emits a {CoinPayback} event.
     */
    function paybackCoin(uint256 _backedTokenID, uint256 amount) external;

    /**
     * @notice  External function that returns the amount of backed asset coins user can mint with unused reserve asset.
     * @param user to check minting power.
     * @param reserveAsset Address of reserve asset.
     */
    function checkMintingPower(address user, address reserveAsset) external view returns (uint256);

    /**
     * @notice  Function to get the health ratio of user.
     * @param user address.
     * @param houseOfReserve address in where user has collateral backing debt.
     */
    function computeUserHealthRatio(address user, address houseOfReserve) external view returns (uint256);

    /**
     * @dev Returns the _liqParams as a struct
     */
    function getLiqParams() external view returns (LiquidationParam memory);
}
