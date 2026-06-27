pragma solidity ^0.8.20;

interface IErrors {
    /// @notice trying to do swap/remove liquidity without sufficient liquidity
    error NotEnoughLiquidity();

    /// @notice trying to do something with a token that is not in the pool or initializing token that doesn't have expiry
    error InvalidToken();

    /// @notice trying to change fee to a value higher than MAX_FEE that is 100e18
    error InvalidFee();

    /// @notice trying to add liquidity through the pool manager
    error DisableNativeLiquidityModification();

    /// @notice trying to initialize the pool more than once
    error AlreadyInitialized();

    /// @notice trying to swap/remove liquidity from non-initialized pool
    error NotInitialized();

    /// @notice trying to swap with invalid amount or adding liquidity without proportion, e.g 0
    error InvalidAmount();

    /// @notice somehow the sender is not set in the forwarder contract when using hook swap function
    error NoSender();

    /// @notice only self call is allowed when forwarding callback in hook forwarder
    error OnlySelfCall();

    /// @notice trying to add liquidity with insufficient amount
    error Insufficient0Amount();

    /// @notice trying to add liquidity with insufficient amount
    error Insufficient1Amount();

    /// @notice trying to remove liquidity, but the liquidity removed is less than what expected
    error InsufficientOutputAmout();

    /// @notice deadline has passed
    error Deadline();

    /// @notice trying to do flash swap with exact in
    error NoExactIn();
}
