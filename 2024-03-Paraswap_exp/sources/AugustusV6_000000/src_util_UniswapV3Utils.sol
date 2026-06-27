// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Contracts
import { AugustusFees } from "../fees/AugustusFees.sol";

// Interfaces
import { IUniswapV3SwapCallback } from "../interfaces/IUniswapV3SwapCallback.sol";

// Libraries
import { SafeCastLib } from "@solady/utils/SafeCastLib.sol";

/// @title UniswapV3Utils
/// @notice A contract containing common utilities for UniswapV3 swaps
abstract contract UniswapV3Utils is IUniswapV3SwapCallback, AugustusFees {
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using SafeCastLib for int256;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Error emitted if the caller is not a Uniswap V3 pool
    error InvalidCaller();
    /// @notice Error emitted if the transfer of tokens to the pool inside the callback failed
    error CallbackTransferFailed();

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Used to caluclate pool address
    uint256 public immutable UNISWAP_V3_POOL_INIT_CODE_HASH;

    /// @dev Right padded FF + UniswapV3Factory address
    uint256 public immutable UNISWAP_V3_FACTORY_AND_FF;

    /// @dev Permit2 address
    address private immutable PERMIT_2;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 private constant UNISWAP_V3_MIN_SQRT = 4_295_128_740;
    uint256 private constant UNISWAP_V3_MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(uint256 _uniswapV3FactoryAndFF, uint256 _uniswapV3PoolInitCodeHash, address _permit2) {
        UNISWAP_V3_FACTORY_AND_FF = _uniswapV3FactoryAndFF;
        UNISWAP_V3_POOL_INIT_CODE_HASH = _uniswapV3PoolInitCodeHash;
        PERMIT_2 = _permit2;
    }

    /*//////////////////////////////////////////////////////////////
                                EXTERNAL
    //////////////////////////////////////////////////////////////*/

    // @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        uint256 uniswapV3FactoryAndFF = UNISWAP_V3_FACTORY_AND_FF;
        uint256 uniswapV3PoolInitCodeHash = UNISWAP_V3_POOL_INIT_CODE_HASH;
        address permit2Address = PERMIT_2;
        bool isPermit2 = data.length == 512;
        // Check if data length is greater than 160 bytes (1 pool)
        // We pass multiple pools in data when executing a multi-hop swapExactAmountOut
        if (data.length > 160 && !isPermit2) {
            // Initialize recursive variables
            address payer;
            // solhint-disable-next-line no-inline-assembly
            assembly {
                // Copy payer address from calldata
                payer := calldataload(164)
            }

            // Recursive call swapExactAmountOut
            _callUniswapV3PoolsSwapExactAmountOut(amount0Delta > 0 ? -amount0Delta : -amount1Delta, data, payer);
        } else {
            // solhint-disable-next-line no-inline-assembly
            assembly {
                // Token to send to the pool
                let token
                // Amount to send to the pool
                let amount
                // Pool address
                let poolAddress := caller()

                // Get free memory pointer
                let ptr := mload(64)

                // We need make sure the caller is a UniswapV3Pool deployed by the canonical UniswapV3Factory
                // 1. Prepare data for calculating the pool address
                // Store ff+factory address, Load token0, token1, fee from bytes calldata and store pool init code hash

                // Store 0xff + factory address (right padded)
                mstore(ptr, uniswapV3FactoryAndFF)

                // Store data offset + 21 bytes (UNISWAP_V3_FACTORY_AND_FF SIZE)
                let token0Offset := add(ptr, 21)

                // Copy token0, token1, fee to free memory pointer + 21 bytes (UNISWAP_V3_FACTORY_AND_FF SIZE) + 1 byte
                // (direction)
                calldatacopy(add(token0Offset, 1), add(data.offset, 65), 95)

                // 2. Calculate the pool address
                // We can do this by first calling the keccak256 function on the fetched values and then
                // calculating keccak256(abi.encodePacked(hex'ff', address(factory_address),
                // keccak256(abi.encode(token0,
                // token1, fee)), POOL_INIT_CODE_HASH));
                // The first 20 bytes of the computed address are the pool address

                // Calculate keccak256(abi.encode(address(token0), address(token1), fee))
                mstore(token0Offset, keccak256(token0Offset, 96))
                // Store POOL_INIT_CODE_HASH
                mstore(add(token0Offset, 32), uniswapV3PoolInitCodeHash)
                // Calculate keccak256(abi.encodePacked(hex'ff', address(factory_address), keccak256(abi.encode(token0,
                // token1, fee)), POOL_INIT_CODE_HASH));
                mstore(ptr, keccak256(ptr, 85)) // 21 + 32 + 32

                // Get the first 20 bytes of the computed address
                let computedAddress := and(mload(ptr), 0xffffffffffffffffffffffffffffffffffffffff)

                // Check if the caller matches the computed address (and revert if not)
                if xor(poolAddress, computedAddress) {
                    mstore(0, 0x48f5c3ed00000000000000000000000000000000000000000000000000000000) // store the selector
                        // (error InvalidCaller())
                    revert(0, 4) // revert with error selector
                }

                // If the caller is the computed address, then we can safely assume that the caller is a UniswapV3Pool
                // deployed by the canonical UniswapV3Factory

                // 3. Transfer amount to the pool

                // Check if amount0Delta or amount1Delta is positive and which token we need to send to the pool
                if sgt(amount0Delta, 0) {
                    // If amount0Delta is positive, we need to send amount0Delta token0 to the pool
                    token := and(calldataload(add(data.offset, 64)), 0xffffffffffffffffffffffffffffffffffffffff)
                    amount := amount0Delta
                }
                if sgt(amount1Delta, 0) {
                    // If amount1Delta is positive, we need to send amount1Delta token1 to the pool
                    token := calldataload(add(data.offset, 96))
                    amount := amount1Delta
                }

                // Based on the data passed to the callback, we know the fromAddress that will pay for the
                // swap, if it is this contract, we will execute the transfer() function,
                // otherwise, we will execute transferFrom()

                // Check if fromAddress is this contract
                let fromAddress := calldataload(164)

                switch eq(fromAddress, address())
                // If fromAddress is this contract, execute transfer()
                case 1 {
                    // Prepare external call data
                    mstore(ptr, 0xa9059cbb00000000000000000000000000000000000000000000000000000000) // store the
                        // selector
                        // (function transfer(address recipient, uint256 amount))
                    mstore(add(ptr, 4), poolAddress) // store the recipient
                    mstore(add(ptr, 36), amount) // store the amount
                    let success := call(gas(), token, 0, ptr, 68, 0, 32) // call transfer
                    if success {
                        switch returndatasize()
                        // check the return data size
                        case 0 { success := gt(extcodesize(token), 0) }
                        default { success := and(gt(returndatasize(), 31), eq(mload(0), 1)) }
                    }

                    if iszero(success) {
                        mstore(0, 0x1bbb4abe00000000000000000000000000000000000000000000000000000000) // store the
                            // selector
                            // (error CallbackTransferFailed())
                        revert(0, 4) // revert with error selector
                    }
                }
                // If fromAddress is not this contract, execute transferFrom() or permitTransferFrom()
                default {
                    switch isPermit2
                    // If permit2 is not present, execute transferFrom()
                    case 0 {
                        mstore(ptr, 0x23b872dd00000000000000000000000000000000000000000000000000000000) // store the
                            // selector
                            // (function transferFrom(address sender, address recipient,
                            // uint256 amount))
                        mstore(add(ptr, 4), fromAddress) // store the sender
                        mstore(add(ptr, 36), poolAddress) // store the recipient
                        mstore(add(ptr, 68), amount) // store the amount
                        let success := call(gas(), token, 0, ptr, 100, 0, 32) // call transferFrom
                        if success {
                            switch returndatasize()
                            // check the return data size
                            case 0 { success := gt(extcodesize(token), 0) }
                            default { success := and(gt(returndatasize(), 31), eq(mload(0), 1)) }
                        }
                        if iszero(success) {
                            mstore(0, 0x1bbb4abe00000000000000000000000000000000000000000000000000000000) // store the
                                // selector
                                // (error CallbackTransferFailed())
                            revert(0, 4) // revert with error selector
                        }
                    }
                    // If permit2 is present, execute permitTransferFrom()
                    default {
                        // Otherwise Permit2.permitTransferFrom
                        // Store function selector
                        mstore(ptr, 0x30f28b7a00000000000000000000000000000000000000000000000000000000)
                        // permitTransferFrom()
                        calldatacopy(add(ptr, 4), 292, 352) // Copy data to memory
                        mstore(add(ptr, 132), poolAddress) // Store pool address as recipient
                        mstore(add(ptr, 164), amount) // Store amount as amount
                        // Call permit2.permitTransferFrom and revert if call failed
                        if iszero(call(gas(), permit2Address, 0, ptr, 356, 0, 0)) {
                            mstore(0, 0x6b836e6b00000000000000000000000000000000000000000000000000000000) // Store
                                // error selector
                                // error Permit2Failed()
                            revert(0, 4)
                        }
                    }
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Loops through pools and performs swaps
    function _callUniswapV3PoolsSwapExactAmountIn(
        int256 fromAmount,
        bytes calldata pools,
        address fromAddress,
        bytes calldata permit2
    )
        internal
        returns (uint256 receivedAmount)
    {
        uint256 uniswapV3FactoryAndFF = UNISWAP_V3_FACTORY_AND_FF;
        uint256 uniswapV3PoolInitCodeHash = UNISWAP_V3_POOL_INIT_CODE_HASH;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            //---------------------------------//
            // Loop Swap Through Pools
            //---------------------------------//

            // Calculate pool count
            let poolCount := div(pools.length, 96)

            // Initialize variables
            let p := 0
            let poolAddress := 0
            let nextPoolAddress := 0
            let direction := 0
            let isPermit2 := gt(permit2.length, 256)

            // Get free memory pointer
            let ptr := mload(64)

            // Loop through pools
            for { let i := 0 } lt(i, poolCount) { i := add(i, 1) } {
                // Check if it is the first pool
                if iszero(p) {
                    //---------------------------------//
                    // Calculate Pool Address
                    //---------------------------------//

                    // Calculate the pool address
                    // We can do this by first calling the keccak256 function on the passed pool values and then
                    // calculating keccak256(abi.encodePacked(hex'ff', address(factory_address),
                    // keccak256(abi.encode(token0,
                    // token1, fee)), POOL_INIT_CODE_HASH));
                    // The first 20 bytes of the computed address are the pool address

                    // Store 0xff + factory address (right padded)
                    mstore(ptr, uniswapV3FactoryAndFF)

                    // Store pools offset + 21 bytes (UNISWAP_V3_FACTORY_AND_FF SIZE)
                    let token0ptr := add(ptr, 21)

                    // Copy pool data (skip first byte) to free memory pointer + 21 bytes (UNISWAP_V3_FACTORY_AND_FF
                    // SIZE)
                    calldatacopy(add(token0ptr, 1), add(pools.offset, 1), 95)

                    // Calculate keccak256(abi.encode(address(token0), address(token1), fee))
                    mstore(token0ptr, keccak256(token0ptr, 96))

                    // Store POOL_INIT_CODE_HASH
                    mstore(add(token0ptr, 32), uniswapV3PoolInitCodeHash)

                    // Calculate keccak256(abi.encodePacked(hex'ff', address(factory_address),
                    // keccak256(abi.encode(token0,
                    // token1, fee)), POOL_INIT_CODE_HASH));
                    mstore(ptr, keccak256(ptr, 85)) // 21 + 32 + 32

                    // Load pool
                    p := mload(ptr)

                    // Get the first 20 bytes of the computed address
                    poolAddress := and(p, 0xffffffffffffffffffffffffffffffffffffffff)

                    //---------------------------------//
                }

                // Direction is the first bit of the pool data
                direction := shr(255, calldataload(add(pools.offset, mul(i, 96))))

                // Check if it is not the last pool
                if lt(add(i, 1), poolCount) {
                    //---------------------------------//
                    // Calculate Next Pool Address
                    //---------------------------------//

                    // Store 0xff + factory address (right padded)
                    mstore(ptr, uniswapV3FactoryAndFF)

                    // Store pools offset + 21 bytes (UNISWAP_V3_FACTORY_AND_FF SIZE)
                    let token0ptr := add(ptr, 21)

                    // Copy next pool data to free memory pointer + 21 bytes (UNISWAP_V3_FACTORY_AND_FF SIZE)
                    calldatacopy(add(token0ptr, 1), add(add(pools.offset, 1), mul(add(i, 1), 96)), 95)

                    // Calculate keccak256(abi.encode(address(token0), address(token1), fee))
                    mstore(token0ptr, keccak256(token0ptr, 96))

                    // Store POOL_INIT_CODE_HASH
                    mstore(add(token0ptr, 32), uniswapV3PoolInitCodeHash)

                    // Calculate keccak256(abi.encodePacked(hex'ff', address(factory_address),
                    // keccak256(abi.encode(token0,
                    // token1, fee)), POOL_INIT_CODE_HASH));
                    mstore(ptr, keccak256(ptr, 85)) // 21 + 32 + 32

                    // Load pool
                    p := mload(ptr)

                    // Get the first 20 bytes of the computed address
                    nextPoolAddress := and(p, 0xffffffffffffffffffffffffffffffffffffffff)

                    //---------------------------------//
                }

                // Adjust fromAddress and fromAmount if it's not the first pool
                if gt(i, 0) { fromAddress := address() }

                //---------------------------------//
                // Perform Swap
                //---------------------------------//

                //---------------------------------//
                // Return based on direction
                //---------------------------------//

                // Initialize data length
                let dataLength := 0xa0

                // Initialize total data length
                let totalDataLength := 356

                // If permit2 is present include permit2 data length in total data length
                if eq(isPermit2, 1) {
                    totalDataLength := add(totalDataLength, permit2.length)
                    dataLength := add(dataLength, permit2.length)
                }

                // Return amount0 or amount1 depending on direction
                switch direction
                case 0 {
                    // Prepare external call data
                    // Store swap selector (0x128acb08)
                    mstore(ptr, 0x128acb0800000000000000000000000000000000000000000000000000000000)
                    // Store toAddress
                    mstore(add(ptr, 4), address())
                    // Store direction
                    mstore(add(ptr, 36), 0)
                    // Store fromAmount
                    mstore(add(ptr, 68), fromAmount)
                    // Store sqrtPriceLimitX96
                    mstore(add(ptr, 100), UNISWAP_V3_MAX_SQRT)
                    // Store data offset
                    mstore(add(ptr, 132), 0xa0)
                    /// Store data length
                    mstore(add(ptr, 164), dataLength)
                    // Store fromAddress
                    mstore(add(ptr, 228), fromAddress)
                    // Store token0, token1, fee
                    calldatacopy(add(ptr, 260), add(pools.offset, mul(i, 96)), 96)
                    // If permit2 is present, store permit2 data
                    if eq(isPermit2, 1) {
                        // Store permit2 data
                        calldatacopy(add(ptr, 356), permit2.offset, permit2.length)
                    }
                    // Perform the external 'swap' call
                    if iszero(call(gas(), poolAddress, 0, ptr, totalDataLength, ptr, 32)) {
                        // store return value directly to free memory pointer
                        // The call failed; we retrieve the exact error message and revert with it
                        returndatacopy(0, 0, returndatasize()) // Copy the error message to the start of memory
                        revert(0, returndatasize()) // Revert with the error message
                    }
                    // If direction is 0, return amount0
                    fromAmount := mload(ptr)
                }
                default {
                    // Prepare external call data
                    // Store swap selector (0x128acb08)
                    mstore(ptr, 0x128acb0800000000000000000000000000000000000000000000000000000000)
                    // Store toAddress
                    mstore(add(ptr, 4), address())
                    // Store direction
                    mstore(add(ptr, 36), 1)
                    // Store fromAmount
                    mstore(add(ptr, 68), fromAmount)
                    // Store sqrtPriceLimitX96
                    mstore(add(ptr, 100), UNISWAP_V3_MIN_SQRT)
                    // Store data offset
                    mstore(add(ptr, 132), 0xa0)
                    /// Store data length
                    mstore(add(ptr, 164), dataLength)
                    // Store fromAddress
                    mstore(add(ptr, 228), fromAddress)
                    // Store token0, token1, fee
                    calldatacopy(add(ptr, 260), add(pools.offset, mul(i, 96)), 96)
                    // If permit2 is present, store permit2 data
                    if eq(isPermit2, 1) {
                        // Store permit2 data
                        calldatacopy(add(ptr, 356), permit2.offset, permit2.length)
                    }
                    // Perform the external 'swap' call
                    if iszero(call(gas(), poolAddress, 0, ptr, totalDataLength, ptr, 64)) {
                        // store return value directly to free memory pointer
                        // The call failed; we retrieve the exact error message and revert with it
                        returndatacopy(0, 0, returndatasize()) // Copy the error message to the start of memory
                        revert(0, returndatasize()) // Revert with the error message
                    }

                    // If direction is 1, return amount1
                    fromAmount := mload(add(ptr, 32))
                }
                //---------------------------------//

                //---------------------------------//

                // The next pool address was already calculated so we can set it as the current pool address for the
                // next iteration of the loop
                poolAddress := nextPoolAddress

                // fromAmount = -fromAmount
                fromAmount := sub(0, fromAmount)
            }

            //---------------------------------//
        }
        return fromAmount.toUint256();
    }

    function _callUniswapV3PoolsSwapExactAmountOut(
        int256 fromAmount,
        bytes calldata pools,
        address fromAddress
    )
        internal
        returns (uint256 spentAmount, uint256 receivedAmount)
    {
        uint256 uniswapV3FactoryAndFF = UNISWAP_V3_FACTORY_AND_FF;
        uint256 uniswapV3PoolInitCodeHash = UNISWAP_V3_POOL_INIT_CODE_HASH;

        // solhint-disable-next-line no-inline-assembly
        assembly {
            //---------------------------------//
            // Adjust data received from recursive call
            //---------------------------------//

            // Initialize variables
            let poolsStartOffset := pools.offset
            let poolsLength := pools.length
            let previousPoolAddress := 0

            // Check if pools length is not divisible by 96
            if gt(mod(pools.length, 96), 0) {
                // Check if pools length is greater than 128 bytes (1 pool)
                if gt(pools.length, 160) {
                    // Get the previous pool address from the first 20 bytes of pool data
                    previousPoolAddress := and(calldataload(pools.offset), 0xffffffffffffffffffffffffffffffffffffffff)
                    // Relculate the offset to skip data
                    poolsStartOffset := add(pools.offset, 160)
                    // Recalculate the length to skip data
                    poolsLength := sub(pools.length, 160)
                }
            }

            // Get free memory pointer
            let ptr := mload(64)

            //---------------------------------//
            // Calculate Pool Address
            //---------------------------------//

            // Calculate the pool address
            // We can do this by first calling the keccak256 function on the passed pool values and then
            // calculating keccak256(abi.encodePacked(hex'ff', address(factory_address),
            // keccak256(abi.encode(token0,
            // token1, fee)), POOL_INIT_CODE_HASH));
            // The first 20 bytes of the computed address are the pool address

            // Store 0xff + factory address (right padded)
            mstore(ptr, uniswapV3FactoryAndFF)

            // Store pools offset + 21 bytes (UNISWAP_V3_FACTORY_AND_FF SIZE)
            let token0ptr := add(ptr, 21)

            // Copy pool data (skip first byte) to free memory pointer + 21 bytes (UNISWAP_V3_FACTORY_AND_FF
            // SIZE)
            calldatacopy(add(token0ptr, 1), add(poolsStartOffset, 1), 95)

            // Calculate keccak256(abi.encode(address(token0), address(token1), fee))
            mstore(token0ptr, keccak256(token0ptr, 96))

            // Store POOL_INIT_CODE_HASH
            mstore(add(token0ptr, 32), uniswapV3PoolInitCodeHash)

            // Calculate keccak256(abi.encodePacked(hex'ff', address(factory_address),
            // keccak256(abi.encode(token0,
            // token1, fee)), POOL_INIT_CODE_HASH));
            mstore(ptr, keccak256(ptr, 85)) // 21 + 32 + 32

            // Load pool
            let p := mload(ptr)

            // Get the first 20 bytes of the computed address
            let poolAddress := and(p, 0xffffffffffffffffffffffffffffffffffffffff)

            //---------------------------------//

            //---------------------------------//
            // Adjust toAddress
            //---------------------------------//

            let toAddress := address()

            // If it's not the first entry to recursion, we use the pool address from the previous pool as
            // the toAddress
            if xor(previousPoolAddress, 0) { toAddress := previousPoolAddress }

            //---------------------------------//

            // Direction is the first bit of the pool data
            let direction := shr(255, calldataload(poolsStartOffset))

            //---------------------------------//
            // Perform Swap
            //---------------------------------//

            //---------------------------------//
            // Return based on direction
            //---------------------------------//

            // Return amount0 or amount1 depending on direction
            switch direction
            case 0 {
                // Prepare external call data
                // Store swap selector (0x128acb08)
                mstore(ptr, 0x128acb0800000000000000000000000000000000000000000000000000000000)
                // Store toAddress
                mstore(add(ptr, 4), toAddress)
                // Store direction
                mstore(add(ptr, 36), 0)
                // Store fromAmount
                mstore(add(ptr, 68), fromAmount)
                // Store sqrtPriceLimitX96
                mstore(add(ptr, 100), UNISWAP_V3_MAX_SQRT)
                // Store data offset
                mstore(add(ptr, 132), 0xa0)
                /// Store data length
                mstore(add(ptr, 164), add(64, poolsLength))
                // Store poolAddress
                mstore(add(ptr, 196), poolAddress)
                // Store fromAddress
                mstore(add(ptr, 228), fromAddress)
                // Store token0, token1, fee
                calldatacopy(add(ptr, 260), poolsStartOffset, poolsLength)

                // Perform the external 'swap' call
                if iszero(call(gas(), poolAddress, 0, ptr, add(poolsLength, 260), ptr, 64)) {
                    // store return value directly to free memory pointer
                    // The call failed; we retrieve the exact error message and revert with it
                    returndatacopy(0, 0, returndatasize()) // Copy the error message to the start of memory
                    revert(0, returndatasize()) // Revert with the error message
                }
                // If direction is 0, return amount0 as fromAmount
                fromAmount := mload(ptr)
                // return amount1 as spentAmount
                spentAmount := mload(add(ptr, 32))
            }
            default {
                // Prepare external call data
                // Store swap selector (0x128acb08)
                mstore(ptr, 0x128acb0800000000000000000000000000000000000000000000000000000000)
                // Store toAddress
                mstore(add(ptr, 4), toAddress)
                // Store direction
                mstore(add(ptr, 36), 1)
                // Store fromAmount
                mstore(add(ptr, 68), fromAmount)
                // Store sqrtPriceLimitX96
                mstore(add(ptr, 100), UNISWAP_V3_MIN_SQRT)
                // Store data offset
                mstore(add(ptr, 132), 0xa0)
                /// Store data length
                mstore(add(ptr, 164), add(64, poolsLength))
                // Store poolAddress
                mstore(add(ptr, 196), poolAddress)
                // Store fromAddress
                mstore(add(ptr, 228), fromAddress)
                // Store token0, token1, fee
                calldatacopy(add(ptr, 260), poolsStartOffset, poolsLength)

                // Perform the external 'swap' call
                if iszero(call(gas(), poolAddress, 0, ptr, add(poolsLength, 260), ptr, 64)) {
                    // store return value directly to free memory pointer
                    // The call failed; we retrieve the exact error message and revert with it
                    returndatacopy(0, 0, returndatasize()) // Copy the error message to the start of memory
                    revert(0, returndatasize()) // Revert with the error message
                }

                // If direction is 1, return amount1 as fromAmount
                fromAmount := mload(add(ptr, 32))
                // return amount0 as spentAmount
                spentAmount := mload(ptr)
            }
            //---------------------------------//

            //---------------------------------//

            // fromAmount = -fromAmount
            fromAmount := sub(0, fromAmount)
        }
        return (spentAmount, fromAmount.toUint256());
    }
}
