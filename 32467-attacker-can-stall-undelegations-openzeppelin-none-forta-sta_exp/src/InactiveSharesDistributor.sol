// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { OwnableUpgradeable } from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import { ERC20Upgradeable, IERC20 } from "@openzeppelin-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import { ERC1155HolderUpgradeable } from
    "@openzeppelin-upgradeable/contracts/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IFortaStaking, DELEGATOR_SCANNER_POOL_SUBJECT } from "./interfaces/IFortaStaking.sol";

/**
 * @title Inactives shares distributor
 * @author Nethermind
 * @notice Simulates the behavior of a vault so the invalidShares in each of the pools can be distributed given that
 * they are not transferrable
 */
contract InactiveSharesDistributor is OwnableUpgradeable, ERC20Upgradeable, ERC1155HolderUpgradeable {
    using SafeERC20 for IERC20;

    IFortaStaking private _staking;
    bool private _claimable;
    uint64 private _deadline;
    IERC20 private _token;
    uint256 private _subject;
    uint256 private _shares;
    uint256 private _assetsReceived;

    constructor() {
        _disableInitializers();
    }

    /**
     * Initializes the contract
     * @param stakingContract FortaStaking contract address
     * @param token Forta token address
     * @param subject Subject from where inactive shares are going to be distributed
     * @param shares Shares to distribute
     */
    function initialize(
        IFortaStaking stakingContract,
        IERC20 token,
        uint256 subject,
        uint256 shares
    )
        public
        initializer
    {
        __Ownable_init(msg.sender);
        __ERC20_init("Inactive Shares", "IS");

        _staking = stakingContract;
        _shares = shares;
        _subject = subject;
        _token = token;

        _mint(msg.sender, shares);
    }

    /**
     * @notice Initiates the undelegation process
     * @dev Shares become inactive at this point
     */
    function initiateUndelegate() public onlyOwner returns (uint64) {
        _deadline = _staking.initiateWithdrawal(DELEGATOR_SCANNER_POOL_SUBJECT, _subject, _shares);
        return _deadline;
    }

    /**
     * @notice Finish the undelegation process
     * @dev Shares are redeemed and Vault shares are sent to the vault
     */
    function undelegate() public onlyOwner {
        _staking.withdraw(DELEGATOR_SCANNER_POOL_SUBJECT, _subject);
        uint256 assetsReceived = _token.balanceOf(address(this));
        _assetsReceived = assetsReceived;
        _claimable = true;

        uint256 vaultShares = balanceOf(owner());
        uint256 nonVaultShares = _shares - vaultShares;
        uint256 vaultAssets = assetsReceived - Math.mulDiv(nonVaultShares, _assetsReceived, _shares);
        if (vaultAssets > 0) {
            _token.safeTransfer(owner(), vaultAssets);
        }
        if (vaultShares > 0) {
            _burn(owner(), vaultShares);
        }
    }

    /**
     * @notice Claim the portion of the inactive shares owned by the caller
     * @dev Shares are burned in the process
     */
    function claim() public returns (bool) {
        if (!_claimable) return false;

        uint256 assetsToDeliver = Math.mulDiv(balanceOf(msg.sender), _assetsReceived, _shares);
        if (assetsToDeliver > 0) {
            _token.safeTransfer(msg.sender, assetsToDeliver);
        }
        _burn(msg.sender, balanceOf(msg.sender));
        return true;
    }
}
