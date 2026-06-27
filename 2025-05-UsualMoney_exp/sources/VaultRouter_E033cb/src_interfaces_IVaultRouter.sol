//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IParaSwapAugustus } from "./IParaSwapAugustus.sol";

/// @notice Parameters for permit function calls
/// @param value The amount to approve
/// @param deadline The deadline for the permit
/// @param v The v component of the signature
/// @param r The r component of the signature
/// @param s The s component of the signature
struct PermitParams {
    uint256 value;
    uint256 deadline;
    uint8 v;
    bytes32 r;
    bytes32 s;
}

/// @title IVaultRouter
/// @notice A router that allows users to deposit and withdraw from a
/// WrappedDollarVault
/// using ParaSwap for swaps and permits for approvals, ensuring that arbitrary
/// tokens are accepted as input and USD0PP is accepted as output.
/// @author Usual Labs
interface IVaultRouter {
    // ##########
    // # EVENTS #
    // ##########

    /// @notice event emitted when a user withdraws assets from the vault
    /// @param receiver The address of the receiver of the vault shares
    /// @param assets The amount of assets withdrawn
    /// @param amountUSD0pp The amount of USD0PP received
    event Withdraw(
        address indexed receiver, uint256 assets, uint256 amountUSD0pp
    );

    /// @notice event emitted when a user deposits assets into the vault
    /// @param receiver The address of the receiver of the vault shares
    /// @param tokenIn The address of the token deposited
    /// @param amountIn The amount of tokenIn deposited
    /// @param sharesReceived The amount of vault shares received
    event Deposit(
        address indexed receiver,
        address tokenIn,
        uint256 amountIn,
        uint256 sharesReceived
    );

    /// @notice event emitted when a token is rescued
    /// @param token The token that was rescued
    /// @param balance The balance of the token that was rescued
    event TokenRescued(IERC20 token, uint256 balance);

    /// @notice event emitted when ether is rescued
    /// @param balance The balance of ether that was rescued
    event EtherRescued(uint256 balance);

    // ########################
    // # FUNCTIONS #
    // ########################

    /// @notice Rescue ERC20 tokens mistakenly sent in, as this contract should
    /// not hold any tokens.
    /// @param token The token to rescue
    function rescueToken(IERC20 token) external;

    /// @notice Rescue ETH mistakenly sent in, as this contract should
    /// not hold any ETH
    function rescueEther() external;

    /// @notice Disables most contract functionality
    function pause() external;

    /// @notice Enables most contract functionality
    function unpause() external;

    /// @notice Deposits an ERC20 token into the vault and converts it to sUSDS
    /// @param augustus The paraswap augustus to use for the swap
    /// @param tokenIn The token to deposit
    /// @param amountIn The amount of tokenIn to deposit
    /// @param minTokensToReceive The minimum amount of tokens to receive
    /// @param minSharesToReceive The minimum amount of vault shares to receive
    /// @param receiver The address to receive the vault shares
    /// @param swapData The swap data to use for the swap
    /// @return sharesReceived The amount of vault shares received
    function deposit(
        IParaSwapAugustus augustus,
        IERC20 tokenIn,
        uint256 amountIn,
        uint256 minTokensToReceive,
        uint256 minSharesToReceive,
        address receiver,
        bytes calldata swapData
    )
        external
        payable
        returns (uint256 sharesReceived);

    /// @notice Executes a permit, converts an ERC20 token to sUSDS, and
    /// deposits it into the vault
    /// @param augustus The paraswap augustus to use for the swap
    /// @param tokenIn The token to deposit
    /// @param amountIn The amount of tokenIn to deposit
    /// @param minTokensToReceive The minimum amount of tokens to receive
    /// @param minSharesToReceive The minimum amount of vault shares to receive
    /// @param receiver The address to receive the vault shares
    /// @param swapData The swap data to use for the swap
    /// @param permitParams The permit parameters to use for the permit
    /// @return sharesReceived The amount of vault shares received
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
        external
        returns (uint256 sharesReceived);

    /// @notice Withdraws assets from the vault and converts them to USD0PP
    /// @param augustus The paraswap augustus to use for the swap
    /// @param assets The amount of assets to withdraw
    /// @param minUSD0ppToReceive The minimum amount of USD0PP to receive
    /// @param receiver The address to receive the USD0PP
    /// @param swapData The swap data to use for the swap
    /// @return amountUSD0pp The amount of USD0PP received
    function withdraw(
        IParaSwapAugustus augustus,
        uint256 assets,
        uint256 minUSD0ppToReceive,
        address receiver,
        bytes calldata swapData
    )
        external
        returns (uint256 amountUSD0pp);

    /// @notice Executes a permit and withdraws assets from the vault,
    /// converting them to USD0PP
    /// @param augustus The paraswap augustus to use for the swap
    /// @param assets The amount of assets to withdraw
    /// @param minUSD0ppToReceive The minimum amount of USD0PP to receive
    /// @param receiver The address to receive the USD0PP
    /// @param swapData The swap data to use for the swap
    /// @param permitParams The permit parameters to use for the permit
    /// @return amountUSD0pp The amount of USD0PP received
    function withdrawWithPermit(
        IParaSwapAugustus augustus,
        uint256 assets,
        uint256 minUSD0ppToReceive,
        address receiver,
        bytes calldata swapData,
        PermitParams calldata permitParams
    )
        external
        returns (uint256 amountUSD0pp);
}
