//SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IXToken
 * @author Protofire
 * @dev XToken Interface.
 *
 */
interface IXToken is IERC20 {
    /**
     * @dev Triggers stopped state.
     *
     */
    function pause() external;

    /**
     * @dev Returns to normal state.
     */
    function unpause() external;

    /**
     * @dev Sets authorization.
     *
     */
    function setAuthorization(address authorization_) external;

    /**
     * @dev Sets operationsRegistry.
     *
     */
    function setOperationsRegistry(address operationsRegistry_) external;

    /**
     * @dev Sets kya.
     *
     */
    function setKya(string memory kya_) external;

    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     */
    function mint(address account, uint256 amount) external;

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     */
    function burnFrom(address account, uint256 amount) external;
}
