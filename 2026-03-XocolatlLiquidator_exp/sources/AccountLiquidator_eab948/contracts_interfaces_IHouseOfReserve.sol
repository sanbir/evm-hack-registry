// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

interface IHouseOfReserve {
    /**
     * @dev Returns the reserveAsset of this HouseOfReserve.
     */
    function reserveAsset() external view returns (address);

    /**
     * @dev Returns the backedAsset of this HouseOfReserve.
     */
    function backedAsset() external view returns (address);

    /**
     * @dev Returns the reserveTokenID (used in {AssetsAccountant}) for this HouseOfReserve.
     */
    function reserveTokenID() external view returns (uint256);

    /**
     * @dev Returns the backedTokenID (used in {AssetsAccountant}) for this HouseOfReserve.
     */
    function backedTokenID() external view returns (uint256);

    /**
     * @dev Returns the type of House Contract.
     */
    function HOUSE_TYPE() external returns (bytes32);

    /**
     * @dev Returns the maximum Loan-To-Value of this HouseOfReserve.
     */
    function maxLTVFactor() external view returns (uint256);

    /**
     * @dev Returns the liquidation factor of this HouseOfReserve.
     */
    function liquidationFactor() external view returns (uint256);

    /**
     * @dev Returns the latest price according to activeOracle
     */
    function getLatestPrice() external view returns (uint256 price);

    /**
     * @dev Returns the reserve mint fee of this HouseOfReserve in BPS x 10**2.
     */
    function reserveMintFee() external view returns (uint256);

    /**
     * @dev Deposit reserves in this contract on behalf caller.
     */
    function deposit(uint256 amount) external;

    /**
     * @dev Withdraw reserves in this contract on behalf caller.
     */
    function withdraw(uint256 amount) external;
}
