//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { SafeERC20 } from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from
    "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { ReentrancyGuard } from
    "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { IUSD0ppMinter } from "./interfaces/IUSD0ppMinter.sol";
import { IParaSwapAugustus } from "./interfaces/IParaSwapAugustus.sol";
import { IParaSwapAugustusRegistry } from
    "./interfaces/IParaSwapAugustusRegistry.sol";
import { IRegistryContract } from "./interfaces/IRegistryContract.sol";
import { IRegistryAccess } from "./interfaces/IRegistryAccess.sol";
import { IVaultRouter, PermitParams } from "./interfaces/IVaultRouter.sol";
import { WrappedDollarVault } from "./WrappedDollarVault.sol";

import {
    ADDRESS_SUSDS,
    CONTRACT_REGISTRY_ACCESS,
    CONTRACT_USD0,
    CONTRACT_USD0PP,
    ROUTER_RESCUER_ROLE,
    ROUTER_PAUSER_ROLE,
    ROUTER_UNPAUSER_ROLE
} from "./constants.sol";

import {
    PermitFailed,
    NoSlippageAllowedForSUSDS,
    InsufficientBalanceBeforeSwap,
    IncorrectAmountSent,
    InsufficientAmountReceivedAfterSwap,
    InsufficientSharesReceived,
    InvalidAugustus,
    NullAddress,
    TokenDoesNotSupportPermit,
    InvalidInputToken,
    NotAuthorized
} from "./errors.sol";

/// @title VaultRouter
/// @notice A router that allows users to deposit and withdraw from a
/// WrappedDollarVault
/// using ParaSwap for swaps and permits for approvals, ensuring that USD0++
/// tokens are accepted as input and output.
/// @author Usual Labs
contract VaultRouter is Pausable, ReentrancyGuard, IVaultRouter {
    using SafeERC20 for IERC20;
    using Address for address payable;

    /*
     * ##########
     * # STATE #
     * ##########
     */
    /// @notice The registry contract
    IRegistryContract public immutable REGISTRY_CONTRACT;
    /// @notice The registry access contract
    IRegistryAccess public immutable REGISTRY_ACCESS;
    /// @notice The vault contract
    WrappedDollarVault public immutable VAULT;
    /// @notice The USD0PP token contract
    IERC20 public immutable USD0PP;
    /// @notice The USD0 token contract
    IERC20 public immutable USD0;
    /// @notice The sUSDS token contract
    IERC20 public immutable SUSDS;
    /// @notice The USD0PP minter contract
    IUSD0ppMinter public immutable MINTER_USD0PP;
    /// @notice The ParaSwap Augustus Registry contract
    IParaSwapAugustusRegistry public immutable AUGUSTUS_REGISTRY;

    /*
     * ########################
     * # CONSTRUCTOR #
     * ########################
     */

    /// @notice constructor for the VaultRouter
    /// @param _registryContract The address of the registry contract
    /// @param _augustusRegistry The address of the paraswap augustus registry
    /// @param _vault The address of the vault
    constructor(
        address _registryContract,
        address _augustusRegistry,
        address _vault
    )
        ReentrancyGuard()
        Pausable()
    {
        if (
            _registryContract == address(0) || _augustusRegistry == address(0)
                || _vault == address(0)
        ) {
            revert NullAddress();
        }
        REGISTRY_CONTRACT = IRegistryContract(_registryContract);
        REGISTRY_ACCESS = IRegistryAccess(
            REGISTRY_CONTRACT.getContract(CONTRACT_REGISTRY_ACCESS)
        );
        USD0 = IERC20(REGISTRY_CONTRACT.getContract(CONTRACT_USD0));
        USD0PP = IERC20(REGISTRY_CONTRACT.getContract(CONTRACT_USD0PP));
        SUSDS = IERC20(ADDRESS_SUSDS);
        MINTER_USD0PP = IUSD0ppMinter(address(USD0PP));
        VAULT = WrappedDollarVault(_vault);
        AUGUSTUS_REGISTRY = IParaSwapAugustusRegistry(_augustusRegistry);
        SUSDS.approve(address(VAULT), type(uint256).max);
        USD0.approve(address(MINTER_USD0PP), type(uint256).max);
    }

    /// @inheritdoc IVaultRouter
    function rescueToken(IERC20 token) external whenNotPaused nonReentrant {
        if (!REGISTRY_ACCESS.hasRole(ROUTER_RESCUER_ROLE, _msgSender())) {
            revert NotAuthorized();
        }
        uint256 balance = token.balanceOf(address(this));
        token.safeTransfer(_msgSender(), balance);
        emit TokenRescued(token, balance);
    }

    /// @inheritdoc IVaultRouter
    function rescueEther() external whenNotPaused nonReentrant {
        if (!REGISTRY_ACCESS.hasRole(ROUTER_RESCUER_ROLE, _msgSender())) {
            revert NotAuthorized();
        }
        uint256 balance = address(this).balance;
        payable(_msgSender()).sendValue(balance);
        emit EtherRescued(balance);
    }

    /// @inheritdoc IVaultRouter
    function pause() external nonReentrant {
        if (!REGISTRY_ACCESS.hasRole(ROUTER_PAUSER_ROLE, _msgSender())) {
            revert NotAuthorized();
        }
        _pause();
    }

    /// @inheritdoc IVaultRouter
    function unpause() external nonReentrant {
        if (!REGISTRY_ACCESS.hasRole(ROUTER_UNPAUSER_ROLE, _msgSender())) {
            revert NotAuthorized();
        }
        _unpause();
    }

    /*
     * ########################
     * # PUBLIC #
     * ########################
     */

    /// @inheritdoc IVaultRouter
    function deposit(
        IParaSwapAugustus augustus,
        IERC20 tokenIn,
        uint256 amountIn,
        uint256 minTokensToReceive,
        uint256 minSharesToReceive,
        address receiver,
        bytes calldata swapData
    )
        public
        payable
        whenNotPaused
        nonReentrant
        returns (uint256 sharesReceived)
    {
        if (tokenIn != USD0PP && tokenIn != SUSDS) {
            revert InvalidInputToken(address(tokenIn));
        }
        if (receiver == address(0)) {
            revert NullAddress();
        }
        uint256 tokensAmount = _convertToTokens(
            augustus, tokenIn, amountIn, minTokensToReceive, swapData
        );

        sharesReceived = VAULT.deposit(tokensAmount, receiver);
        if (sharesReceived < minSharesToReceive) {
            revert InsufficientSharesReceived();
        }
        emit Deposit(receiver, address(tokenIn), amountIn, sharesReceived);
        return sharesReceived;
    }

    /// @inheritdoc IVaultRouter
    function depositWithPermit(
        IParaSwapAugustus augustus,
        IERC20 tokenIn,
        uint256 amountIn,
        uint256 minTokensToReceive,
        uint256 minSharesToReceive,
        address receiver,
        bytes calldata swapData,
        PermitParams calldata permitParams
    )
        public
        whenNotPaused
        returns (uint256 sharesReceived)
    {
        try ERC20Permit(address(tokenIn)).permit(
            _msgSender(),
            address(this),
            permitParams.value,
            permitParams.deadline,
            permitParams.v,
            permitParams.r,
            permitParams.s
        ) { } catch { } // solhint-disable-line no-empty-blocks

        return deposit(
            augustus,
            tokenIn,
            amountIn,
            minTokensToReceive,
            minSharesToReceive,
            receiver,
            swapData
        );
    }

    /// @inheritdoc IVaultRouter
    function withdraw(
        IParaSwapAugustus augustus,
        uint256 assets,
        uint256 minUSD0ppToReceive,
        address receiver,
        bytes calldata swapData
    )
        public
        whenNotPaused
        nonReentrant
        returns (uint256 amountUSD0pp)
    {
        if (receiver == address(0)) {
            revert NullAddress();
        }

        VAULT.withdraw(assets, address(this), _msgSender());

        amountUSD0pp = _convertTokensToUSD0pp(
            augustus, assets, minUSD0ppToReceive, swapData
        );

        USD0PP.safeTransfer(receiver, amountUSD0pp);
        emit Withdraw(receiver, assets, amountUSD0pp);
        return amountUSD0pp;
    }

    /// @inheritdoc IVaultRouter
    function withdrawWithPermit(
        IParaSwapAugustus augustus,
        uint256 assets,
        uint256 minUSD0ppToReceive,
        address receiver,
        bytes calldata swapData,
        PermitParams calldata permitParams
    )
        public
        whenNotPaused
        returns (uint256 amountUSD0pp)
    {
        try ERC20Permit(address(VAULT)).permit(
            _msgSender(),
            address(this),
            permitParams.value,
            permitParams.deadline,
            permitParams.v,
            permitParams.r,
            permitParams.s
        ) { } catch { } // solhint-disable-line no-empty-blocks

        return
            withdraw(augustus, assets, minUSD0ppToReceive, receiver, swapData);
    }
    /*
     * ########################
     * # INTERNAL #
     * ########################
     */

    /// @notice convert any token to another token
    /// @param augustus the paraswap augustus to use for the swap
    /// @param tokenIn the token to convert
    /// @param amountIn the amount of tokenIn to convert
    /// @param minTokensToReceive the minimum amount of tokens to receive
    /// @param swapData the swap data to use for the swap
    /// @return amount The amount of tokens received
    function _convertToTokens(
        IParaSwapAugustus augustus,
        IERC20 tokenIn,
        uint256 amountIn,
        uint256 minTokensToReceive,
        bytes calldata swapData
    )
        internal
        returns (uint256)
    {
        if (tokenIn == SUSDS) {
            // No slippage allowed for SUSDS because the vault is a 1:1 vault
            if (amountIn != minTokensToReceive) {
                revert NoSlippageAllowedForSUSDS();
            }
            SUSDS.safeTransferFrom(
                _msgSender(), address(this), minTokensToReceive
            );
            return minTokensToReceive;
        }

        return _convertUSD0ppToTokens(
            augustus, amountIn, minTokensToReceive, swapData
        );
    }

    /// @notice convert USD0PP to tokens
    /// @param augustus the paraswap augustus to use for the swap
    /// @param amountUSD0ppIn the amount of USD0PP to convert
    /// @param minTokensToReceive the minimum amount of tokens to receive
    /// @param swapData the swap data to use for the swap
    /// @return amount The amount of tokens received
    function _convertUSD0ppToTokens(
        IParaSwapAugustus augustus,
        uint256 amountUSD0ppIn,
        uint256 minTokensToReceive,
        bytes calldata swapData
    )
        internal
        returns (uint256)
    {
        uint256 initialUSD0Balance = USD0.balanceOf(address(this));

        IERC20(USD0PP).safeTransferFrom(
            _msgSender(), address(this), amountUSD0ppIn
        );

        MINTER_USD0PP.unwrapWithCap(amountUSD0ppIn);

        uint256 amountUSD0 = USD0.balanceOf(address(this)) - initialUSD0Balance;

        return _executeParaswap(
            augustus, swapData, USD0, SUSDS, amountUSD0, minTokensToReceive
        );
    }

    /// @notice convert tokens to USD0PP
    /// @param augustus the paraswap augustus to use for the swap
    /// @param amountsTokensIn the amount of tokens to convert
    /// @param minUSD0ppToReceive the minimum amount of USD0PP to receive
    /// @param swapData the swap data to use for the swap
    /// @return amount The amount of USD0PP received
    function _convertTokensToUSD0pp(
        IParaSwapAugustus augustus,
        uint256 amountsTokensIn,
        uint256 minUSD0ppToReceive,
        bytes calldata swapData
    )
        internal
        returns (uint256)
    {
        // Here, we can convert the minUSD0ppToReceive to minUSD0ToReceive
        // because USD0PP is minted at a 1:1 ratio to USD0
        uint256 minUSD0ToReceive = minUSD0ppToReceive;
        uint256 usd0Received = _executeParaswap(
            augustus, swapData, SUSDS, USD0, amountsTokensIn, minUSD0ToReceive
        );

        MINTER_USD0PP.mint(usd0Received);

        return usd0Received;
    }

    /// @notice execute paraswap
    /// @param augustus the paraswap augustus to use for the swap
    /// @param data the swap data to use for the swap
    /// @param assetToSwapFrom the asset to swap from
    /// @param assetToSwapTo the asset to swap to
    /// @param amountToSwap the amount of assetToSwapFrom to swap
    /// @param minAmountToReceive the minimum amount of assetToSwapTo to receive
    /// @return amount The amount of assetToSwapTo received
    function _executeParaswap(
        IParaSwapAugustus augustus,
        bytes calldata data,
        IERC20 assetToSwapFrom,
        IERC20 assetToSwapTo,
        uint256 amountToSwap,
        uint256 minAmountToReceive
    )
        internal
        returns (uint256)
    {
        if (!AUGUSTUS_REGISTRY.isValidAugustus(address(augustus))) {
            revert InvalidAugustus();
        }

        uint256 balanceBeforeAssetFrom =
            assetToSwapFrom.balanceOf(address(this));
        if (balanceBeforeAssetFrom < amountToSwap) {
            revert InsufficientBalanceBeforeSwap();
        }

        uint256 balanceBeforeAssetTo = assetToSwapTo.balanceOf(address(this));

        address tokenTransferProxy = augustus.getTokenTransferProxy();

        assetToSwapFrom.approve(tokenTransferProxy, amountToSwap);

        // solhint-disable-next-line avoid-low-level-calls
        (bool success,) = address(augustus).call(data);
        if (!success) {
            // solhint-disable-next-line no-inline-assembly
            assembly {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }

        if (
            assetToSwapFrom.balanceOf(address(this))
                != balanceBeforeAssetFrom - amountToSwap
        ) {
            revert IncorrectAmountSent();
        }

        uint256 amountReceived =
            assetToSwapTo.balanceOf(address(this)) - balanceBeforeAssetTo;

        if (amountReceived < minAmountToReceive) {
            revert InsufficientAmountReceivedAfterSwap();
        }

        return amountReceived;
    }
}
