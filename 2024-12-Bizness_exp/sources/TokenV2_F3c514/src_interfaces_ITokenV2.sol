// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {IERC20MetadataUpgradeable} from
    "@openzeppelin-contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

import {IERC20PermitUpgradeable} from
    "@openzeppelin-contracts-upgradeable/token/ERC20/extensions/IERC20PermitUpgradeable.sol";

interface ITokenV2 is IERC20MetadataUpgradeable, IERC20PermitUpgradeable {
    function initialize(
        address _v2Pool,
        address _v3Pool,
        string memory name,
        string memory symbol,
        string memory meta,
        uint256 maxSupply
    ) external;

    /// @notice Remove the transferring constraints of the token
    /// @dev This can only be called by the owner of the contract
    function removeTransferConstraints() external;

    function metaURI() external view returns (string memory);

    /// @notice the max supply of the token
    function maxSupply() external view returns (uint256);

    /// @notice the predicted pool address for uniswap v2 & v3
    function pools() external view returns (address v2, address v3);

    //
    // Customized Events to ease the indexer
    //

    // custom transfer event

    /// @notice the same as the ERC20 Transfer event, we intentionally duplicate it here
    /// This would make the indexer easier to index our transfer event only.
    /// To save gas, we remove indexed from the from and to
    event TransferFlapToken(address from, address to, uint256 value);
}
