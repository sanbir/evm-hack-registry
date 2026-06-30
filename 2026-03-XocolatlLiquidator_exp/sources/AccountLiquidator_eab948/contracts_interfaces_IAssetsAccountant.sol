// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import {IERC1155Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/IERC1155Upgradeable.sol";

interface IAssetsAccountant is IERC1155Upgradeable {
    /**
     * @dev Returns the address of the HouseOfReserve corresponding to reserveAsset.
     */
    function houseOfReserves(uint256 reserveAssetTokenID) external view returns (address);

    /**
     * @dev Returns the address of the HouseOfCoin corresponding to backedAsset.
     */
    function houseOfCoins(address backedAsset) external view returns (address);

    /**
     * @notice Returns true if house addres is registered.
     */
    function isARegisteredHouse(address house) external view returns (bool);

    /**
     * @dev Returns the reserve Token Ids that correspond to reserveAsset and backedAsset
     */
    function getReserveIds(address reserveAsset, address backedAsset) external view returns (uint256[] memory);

    /**
     * @dev Registers a HouseOfReserve or HouseOfCoinMinting contract address in AssetsAccountant.
     * grants MINTER_ROLE and BURNER_ROLE to House
     * Requirements:
     * - the caller must have ADMIN_ROLE.
     */
    function registerHouse(address houseAddress, address asset) external;

    /**
     * @dev Creates `amount` new tokens for `to`, of token type `id`.
     * See {ERC1155-_mint}.
     * Requirements:
     * - the caller must have the `MINTER_ROLE`.
     */
    function mint(address account, uint256 id, uint256 amount, bytes memory data) external;

    /**
     * @dev Burns `amount` of tokens from `to`, of token type `id`.
     * See {ERC1155-_burn}.
     * Requirements:
     * - the caller must have the `BURNER_ROLE`.
     */
    function burn(address account, uint256 id, uint256 value) external;
}
