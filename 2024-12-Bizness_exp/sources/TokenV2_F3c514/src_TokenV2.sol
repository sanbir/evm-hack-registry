// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {ITokenV2} from "./interfaces/ITokenV2.sol";

import {ERC20Upgradeable} from "@openzeppelin-contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin-contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @notice Token with max supply and metaURI
contract TokenV2 is ITokenV2, ERC20PermitUpgradeable, OwnableUpgradeable {
    /// @notice The max supply of the token
    uint256 public maxSupply;

    /// @notice URI for the token metadata
    string public metaURI;

    /// @notice If true, transferring to uniswap v2/v3 pool is not allowed
    bool public transferConstraints;

    /// @dev uniswap v2 pool
    address internal uniswapV2Pool;

    /// @dev uni v3 pool
    address internal uniswapV3Pool;

    constructor() {}

    function initialize(
        address _v2Pool,
        address _v3Pool,
        string memory name_,
        string memory symbol_,
        string memory meta_,
        uint256 maxSupply_
    ) external override initializer {
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        __Ownable_init();

        uniswapV2Pool = _v2Pool;
        uniswapV3Pool = _v3Pool;

        maxSupply = maxSupply_;
        metaURI = meta_;

        // restrict transferring when initialized
        transferConstraints = true;

        // mint the maxsupply to the msg.sender
        _mint(msg.sender, maxSupply);
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        // emit our custom event for easier indexing
        emit TransferFlapToken(from, to, amount);
    }

    function _beforeTokenTransfer(address from, address to, uint256) internal view override {
        if (transferConstraints) {
            if (from == uniswapV2Pool || to == uniswapV2Pool) {
                revert("Token: transfer to/from uniswap v2 pool is not allowed");
            }

            if (from == uniswapV3Pool || to == uniswapV3Pool) {
                revert("Token: transfer to/from uniswap v3 pool is not allowed");
            }
        }
    }

    /// @inheritdoc ITokenV2
    function removeTransferConstraints() external override onlyOwner {
        transferConstraints = false;
    }

    /// @inheritdoc ITokenV2
    function pools() external view override returns (address v2, address v3) {
        return (uniswapV2Pool, uniswapV3Pool);
    }
}
