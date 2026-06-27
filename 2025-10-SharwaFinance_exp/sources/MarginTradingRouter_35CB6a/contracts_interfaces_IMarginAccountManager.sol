pragma solidity 0.8.20;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IMarginAccountManager is IERC721{

    /**
     * @notice Creates a new margin account for the caller.
     * @dev Mints a new ERC721 token representing the margin account and assigns it to the caller.
     * @return marginAccountID The ID of the created margin account.
     */
    function createMarginAccount() external returns (uint marginAccountID);

    /**
     * @notice Checks if the given spender is approved or the owner of the specified token.
     * @param spender The address to check for approval or ownership.
     * @param tokenID The ID of the token to check.
     * @return True if the spender is approved or the owner, false otherwise.
     */
    function isApprovedOrOwner(address spender, uint tokenID) external view returns (bool);

    // EVENTS // 

    /**
     * @notice Emitted when a new margin account is created.
     * @param tokenID The ID of the newly created margin account token.
     */
    event CreateMarginAccount(uint tokenID);
}
