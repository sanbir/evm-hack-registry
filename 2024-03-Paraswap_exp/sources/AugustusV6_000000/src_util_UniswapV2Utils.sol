// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Contracts
import { AugustusFees } from "../fees/AugustusFees.sol";

// Interfaces
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";

/// @title UniswapV2Utils
/// @notice A contract containing common utilities for UniswapV2 swaps
abstract contract UniswapV2Utils is AugustusFees {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Used to caluclate pool address
    uint256 public immutable UNISWAP_V2_POOL_INIT_CODE_HASH;

    /// @dev Right padded FF + UniswapV2Factory address
    uint256 public immutable UNISWAP_V2_FACTORY_AND_FF;

    /// @dev Permit2 address
    address private immutable PERMIT2;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(uint256 _uniswapV2FactoryAndFF, uint256 _uniswapV2PoolInitCodeHash, address _permit2) {
        UNISWAP_V2_FACTORY_AND_FF = _uniswapV2FactoryAndFF;
        UNISWAP_V2_POOL_INIT_CODE_HASH = _uniswapV2PoolInitCodeHash;
        PERMIT2 = _permit2;
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _callUniswapV2PoolsSwapExactOut(uint256 amountOut, IERC20 srcToken, bytes calldata pools) internal {
        uint256 uniswapV2FactoryAndFF = UNISWAP_V2_FACTORY_AND_FF;
        uint256 uniswapV2PoolInitCodeHash = UNISWAP_V2_POOL_INIT_CODE_HASH;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            function calculatePoolAddress(
                poolMemoryPtr, poolCalldataPtr, _uniswapV2FactoryAndFF, _uniswapV2PoolInitCodeHash
            ) {
                // Calculate the pool address
                // We can do this by first calling the keccak256 function on the passed pool values and then
                // calculating keccak256(abi.encodePacked(hex'ff', address(factory_address),
                // keccak256(abi.encodePacked(token0, token1)), POOL_INIT_CODE_HASH));
                // The first 20 bytes of the computed address are the pool address

                // Store 0xff + factory address (right padded)
                mstore(poolMemoryPtr, _uniswapV2FactoryAndFF)

                // Store pools offset + 21 bytes (UNISWAP_V2_FACTORY_AND_FF SIZE)
                let token0ptr := add(poolMemoryPtr, 21)

                // Copy pool data (skip last bit) to free memory pointer + 21 bytes (UNISWAP_V2_FACTORY_AND_FF SIZE)
                calldatacopy(token0ptr, poolCalldataPtr, 40)

                // Calculate keccak256(abi.encode(address(token0), address(token1))
                mstore(token0ptr, keccak256(token0ptr, 40))

                // Store POOL_INIT_CODE_HASH
                mstore(add(token0ptr, 32), _uniswapV2PoolInitCodeHash)

                // Calculate address(keccak256(abi.encodePacked(hex'ff', address(factory_address),
                // keccak256(abi.encode(token0, token1, fee)), POOL_INIT_CODE_HASH)));
                mstore(poolMemoryPtr, and(keccak256(poolMemoryPtr, 85), 0xffffffffffffffffffffffffffffffffffffffff)) // 21
                    // + 32 + 32
            }

            // Calculate pool count
            let poolCount := div(pools.length, 64)

            // Initilize memory pointers
            let amounts := mload(64) // pointer for amounts array
            let poolAddresses := add(amounts, add(mul(poolCount, 32), 32)) // pointer for pools array
            let emptyPtr := add(poolAddresses, mul(poolCount, 32)) // pointer for empty memory

            // Initialize fromAmount
            let fromAmount := 0

            // Set the final amount in the amounts array to amountOut
            mstore(add(amounts, mul(poolCount, 0x20)), amountOut)

            //---------------------------------//
            // Calculate Pool Addresses and Amounts
            //---------------------------------//

            // Calculate pool addresses
            for { let i := 0 } lt(i, poolCount) { i := add(i, 1) } {
                calculatePoolAddress(
                    add(poolAddresses, mul(i, 32)),
                    add(pools.offset, mul(i, 64)),
                    uniswapV2FactoryAndFF,
                    uniswapV2PoolInitCodeHash
                )
            }

            // Rerverse loop through pools and calculate amounts
            for { let i := poolCount } gt(i, 0) { i := sub(i, 1) } {
                // Use previous pool data to calculate amount in
                let indexSub1 := sub(i, 1)

                // Get pool address
                let poolAddress := mload(add(poolAddresses, mul(indexSub1, 32)))

                // Get direction
                let direction := and(1, calldataload(add(add(pools.offset, mul(indexSub1, 64)), 32)))

                // Get amount
                let amount := mload(add(amounts, mul(i, 32)))

                //---------------------------------//
                // Calculate Amount In
                //---------------------------------//

                //---------------------------------//
                // Get Reserves
                //---------------------------------//

                // Store the selector
                mstore(emptyPtr, 0x0902f1ac00000000000000000000000000000000000000000000000000000000) // 'getReserves()'
                // selector

                // Perform the external 'getReserves' call - outputs directly to ptr
                if iszero(staticcall(gas(), poolAddress, emptyPtr, 4, emptyPtr, 64)) {
                    returndatacopy(0, 0, returndatasize()) // Copy the error message to the start of memory
                    revert(0, returndatasize()) // Revert with the error message
                }

                // If direction is true, getReserves returns (reserve0, reserve1)
                // If direction is false, getReserves returns (reserve1, reserve0) -> swap the values

                // Load the reserve0 value returned by the 'getReserves' call.
                let reserve1 := mload(emptyPtr)

                // Load the reserve1 value returned by the 'getReserves' call.
                let reserve0 := mload(add(emptyPtr, 32))

                // Check if direction is true
                if direction {
                    // swap reserve0 and reserve1
                    let temp := reserve0
                    reserve0 := reserve1
                    reserve1 := temp
                }

                //---------------------------------//

                // Calculate numerator = reserve0 * amountOut * 10000
                let numerator := mul(mul(reserve0, amount), 10000)

                // Calculate denominator = (reserve1 - amountOut) * 9970
                let denominator := mul(sub(reserve1, amount), 9970)

                // Calculate amountIn = numerator / denominator + 1
                fromAmount := add(div(numerator, denominator), 1)

                // Store amountIn for the previous pool
                mstore(add(amounts, mul(indexSub1, 32)), fromAmount)
            }

            //---------------------------------//

            // Initialize variables
            let poolAddress := 0
            let nextPoolAddress := 0

            //---------------------------------//
            // Loop Swap Through Pools
            //---------------------------------//

            // Loop for each pool
            for { let i := 0 } lt(i, poolCount) { i := add(i, 1) } {
                // Check if it is the first pool
                if iszero(poolAddress) {
                    // If it is the first pool, we need to transfer amount of srcToken to poolAddress
                    // Load first pool address
                    poolAddress := mload(poolAddresses)

                    //---------------------------------//
                    // Transfer amount of srcToken to poolAddress
                    //---------------------------------//

                    // Transfer fromAmount of srcToken to poolAddress
                    mstore(emptyPtr, 0xa9059cbb00000000000000000000000000000000000000000000000000000000) // store the
                        // selector
                        // (function transfer(address recipient, uint256 amount))
                    mstore(add(emptyPtr, 4), poolAddress) // store the recipient
                    mstore(add(emptyPtr, 36), fromAmount) // store the amount
                    pop(call(gas(), srcToken, 0, emptyPtr, 68, 0, 32)) // call transfer

                    //---------------------------------//
                }

                // Adjust toAddress depending on if it is the last pool in the array
                let toAddress := address()

                // Check if it is not the last pool
                if lt(add(i, 1), poolCount) {
                    // Load next pool address
                    nextPoolAddress := mload(add(poolAddresses, mul(add(i, 1), 32)))

                    // Adjust toAddress to next pool address
                    toAddress := nextPoolAddress
                }

                // Check direction
                let direction := and(1, calldataload(add(add(pools.offset, mul(i, 64)), 32)))

                // if direction is 1, amount0out is 0 and amount1out is amount[i+1]
                // if direction is 0, amount0out is amount[i+1] and amount1out is 0

                // Load amount[i+1]
                let amount := mload(add(amounts, mul(add(i, 1), 32)))

                // Initialize amount0Out and amount1Out
                let amount0Out := amount
                let amount1Out := 0

                // Check if direction is true
                if direction {
                    // swap amount0Out and amount1Out
                    let temp := amount0Out
                    amount0Out := amount1Out
                    amount1Out := temp
                }

                //---------------------------------//
                // Perform Swap
                //---------------------------------//

                // Load the 'swap' selector, amount0Out, amount1Out, toAddress and data("") into memory.
                mstore(emptyPtr, 0x022c0d9f00000000000000000000000000000000000000000000000000000000)
                // 'swap()' selector
                mstore(add(emptyPtr, 4), amount0Out) // amount0Out
                mstore(add(emptyPtr, 36), amount1Out) // amount1Out
                mstore(add(emptyPtr, 68), toAddress) // toAddress
                mstore(add(emptyPtr, 100), 0x80) // data length
                mstore(add(emptyPtr, 132), 0) // data

                // Perform the external 'swap' call
                if iszero(call(gas(), poolAddress, 0, emptyPtr, 164, 0, 64)) {
                    // The call failed; we retrieve the exact error message and revert with it
                    returndatacopy(0, 0, returndatasize()) // Copy the error message to the start of memory
                    revert(0, returndatasize()) // Revert with the error message
                }

                //---------------------------------//

                // Set poolAddress to nextPoolAddress
                poolAddress := nextPoolAddress
            }

            //---------------------------------//
        }
    }

    function _callUniswapV2PoolsSwapExactIn(
        uint256 fromAmount,
        IERC20 srcToken,
        bytes calldata pools,
        address payer,
        bytes calldata permit2
    )
        internal
    {
        uint256 uniswapV2FactoryAndFF = UNISWAP_V2_FACTORY_AND_FF;
        uint256 uniswapV2PoolInitCodeHash = UNISWAP_V2_POOL_INIT_CODE_HASH;
        address permit2Address = PERMIT2;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            //---------------------------------//
            // Loop Swap Through Pools
            //---------------------------------//

            // Calculate pool count
            let poolCount := div(pools.length, 64)

            // Initialize variables
            let p := 0
            let poolAddress := 0
            let nextPoolAddress := 0
            let direction := 0

            // Loop for each pool
            for { let i := 0 } lt(i, poolCount) { i := add(i, 1) } {
                // Check if it is the first pool
                if iszero(p) {
                    //---------------------------------//
                    // Calculate Pool Address
                    //---------------------------------//

                    // Calculate the pool address
                    // We can do this by first calling the keccak256 function on the passed pool values and then
                    // calculating keccak256(abi.encodePacked(hex'ff', address(factory_address),
                    // keccak256(abi.encodePacked(token0,token1)), POOL_INIT_CODE_HASH));
                    // The first 20 bytes of the computed address are the pool address

                    // Get free memory pointer
                    let ptr := mload(64)

                    // Store 0xff + factory address (right padded)
                    mstore(ptr, uniswapV2FactoryAndFF)

                    // Store pools offset + 21 bytes (UNISWAP_V2_FACTORY_AND_FF SIZE)
                    let token0ptr := add(ptr, 21)

                    // Copy pool data (skip last bit) to free memory pointer + 21 bytes (UNISWAP_V2_FACTORY_AND_FF
                    // SIZE)
                    calldatacopy(token0ptr, pools.offset, 40)

                    // Calculate keccak256(abi.encodePacked(address(token0), address(token1))
                    mstore(token0ptr, keccak256(token0ptr, 40))

                    // Store POOL_INIT_CODE_HASH
                    mstore(add(token0ptr, 32), uniswapV2PoolInitCodeHash)

                    // Calculate keccak256(abi.encodePacked(hex'ff', address(factory_address),
                    // keccak256(abi.encode(token0,
                    // token1, fee)), POOL_INIT_CODE_HASH));
                    mstore(ptr, keccak256(ptr, 85)) // 21 + 32 + 32

                    // Load pool
                    p := mload(ptr)

                    // Get the first 20 bytes of the computed address
                    poolAddress := and(p, 0xffffffffffffffffffffffffffffffffffffffff)

                    //---------------------------------//

                    //---------------------------------//
                    // Transfer fromAmount of srcToken to poolAddress
                    //---------------------------------//

                    switch eq(payer, address())
                    // if payer is this contract, transfer fromAmount of srcToken to poolAddress
                    case 1 {
                        // Transfer fromAmount of srcToken to poolAddress
                        mstore(ptr, 0xa9059cbb00000000000000000000000000000000000000000000000000000000) // store the
                            // selector
                            // (function transfer(address recipient, uint256 amount))
                        mstore(add(ptr, 4), poolAddress) // store the recipient
                        mstore(add(ptr, 36), fromAmount) // store the amount
                        pop(call(gas(), srcToken, 0, ptr, 68, 0, 32)) // call transfer
                    }
                    // othwerwise transferFrom fromAmount of srcToken to poolAddress from payer
                    default {
                        switch gt(permit2.length, 256)
                        case 0 {
                            // Transfer fromAmount of srcToken to poolAddress
                            mstore(ptr, 0x23b872dd00000000000000000000000000000000000000000000000000000000) // store
                                // the selector
                            // (function transferFrom(address sender, address recipient,
                            // uint256 amount))
                            mstore(add(ptr, 4), payer) // store the sender
                            mstore(add(ptr, 36), poolAddress) // store the recipient
                            mstore(add(ptr, 68), fromAmount) // store the amount
                            pop(call(gas(), srcToken, 0, ptr, 100, 0, 32)) // call transferFrom
                        }
                        default {
                            // Otherwise Permit2.permitTransferFrom
                            // Store function selector
                            mstore(ptr, 0x30f28b7a00000000000000000000000000000000000000000000000000000000)
                            // permitTransferFrom()
                            calldatacopy(add(ptr, 4), permit2.offset, permit2.length) // Copy data to memory
                            mstore(add(ptr, 132), poolAddress) // Store recipient
                            mstore(add(ptr, 164), fromAmount) // Store amount
                            // Call permit2.permitTransferFrom and revert if call failed
                            if iszero(call(gas(), permit2Address, 0, ptr, add(permit2.length, 4), 0, 0)) {
                                mstore(0, 0x6b836e6b00000000000000000000000000000000000000000000000000000000) // Store
                                    // error selector
                                    // error Permit2Failed()
                                revert(0, 4)
                            }
                        }
                    }

                    //---------------------------------//
                }

                // Direction is the first bit of the pool data
                direction := and(1, calldataload(add(add(pools.offset, mul(i, 64)), 32)))

                //---------------------------------//
                // Calculate Amount Out
                //---------------------------------//

                //---------------------------------//
                // Get Reserves
                //---------------------------------//

                // Get free memory pointer
                let ptr := mload(64)

                // Store the selector
                mstore(ptr, 0x0902f1ac00000000000000000000000000000000000000000000000000000000) // 'getReserves()'
                // selector

                // Perform the external 'getReserves' call - outputs directly to ptr
                if iszero(staticcall(gas(), poolAddress, ptr, 4, ptr, 64)) {
                    returndatacopy(0, 0, returndatasize()) // Copy the error message to the start of memory
                    revert(0, returndatasize()) // Revert with the error message
                }

                // If direction is true, getReserves returns (reserve0, reserve1)
                // If direction is false, getReserves returns (reserve1, reserve0) -> swap the values

                // Load the reserve0 value returned by the 'getReserves' call.
                let reserve1 := mload(ptr)

                // Load the reserve1 value returned by the 'getReserves' call.
                let reserve0 := mload(add(ptr, 32))

                // Check if direction is true
                if direction {
                    // swap reserve0 and reserve1
                    let temp := reserve0
                    reserve0 := reserve1
                    reserve1 := temp
                }

                //---------------------------------//

                // Calculate amount based on fee
                let amountWithFee := mul(fromAmount, 9970)

                // Calculate numerator = amountWithFee * reserve1
                let numerator := mul(amountWithFee, reserve1)

                // Calculate denominator = reserve0 * 10000 + amountWithFee
                let denominator := add(mul(reserve0, 10000), amountWithFee)

                // Calculate amountOut = numerator / denominator
                let amountOut := div(numerator, denominator)

                fromAmount := amountOut

                // if direction is true, amount0Out is 0 and amount1Out is fromAmount,
                // otherwise amount0Out is fromAmount and amount1Out is 0

                let amount0Out := fromAmount
                let amount1Out := 0

                // swap amount0Out and amount1Out if direction is false
                if direction {
                    amount0Out := 0
                    amount1Out := fromAmount
                }

                //---------------------------------//

                // Adjust toAddress depending on if it is the last pool in the array
                let toAddress := address()

                // Check if it is not the last pool
                if lt(add(i, 1), poolCount) {
                    //---------------------------------//
                    // Calculate Next Pool Address
                    //---------------------------------//

                    // Store 0xff + factory address (right padded)
                    mstore(ptr, uniswapV2FactoryAndFF)

                    // Store pools offset + 21 bytes (UNISWAP_V2_FACTORY_AND_FF SIZE)
                    let token0ptr := add(ptr, 21)

                    // Copy next pool data to free memory pointer + 21 bytes (UNISWAP_V2_FACTORY_AND_FF SIZE)
                    calldatacopy(token0ptr, add(pools.offset, mul(add(i, 1), 64)), 40)

                    // Calculate keccak256(abi.encodePacked(address(token0), address(token1))
                    mstore(token0ptr, keccak256(token0ptr, 40))

                    // Store POOL_INIT_CODE_HASH
                    mstore(add(token0ptr, 32), uniswapV2PoolInitCodeHash)

                    // Calculate keccak256(abi.encodePacked(hex'ff', address(factory_address),
                    // keccak256(abi.encode(token0,
                    // token1, fee)), POOL_INIT_CODE_HASH));
                    mstore(ptr, keccak256(ptr, 85)) // 21 + 32 + 32

                    // Load pool
                    p := mload(ptr)

                    // Get the first 20 bytes of the computed address
                    nextPoolAddress := and(p, 0xffffffffffffffffffffffffffffffffffffffff)

                    // Adjust toAddress to next pool address
                    toAddress := nextPoolAddress

                    //---------------------------------//
                }

                //---------------------------------//
                // Perform Swap
                //---------------------------------//

                // Load the 'swap' selector, amount0Out, amount1Out, toAddress and data("") into memory.
                mstore(ptr, 0x022c0d9f00000000000000000000000000000000000000000000000000000000)
                // 'swap()' selector
                mstore(add(ptr, 4), amount0Out) // amount0Out
                mstore(add(ptr, 36), amount1Out) // amount1Out
                mstore(add(ptr, 68), toAddress) // toAddress
                mstore(add(ptr, 100), 0x80) // data length
                mstore(add(ptr, 132), 0) // data

                // Perform the external 'swap' call
                if iszero(call(gas(), poolAddress, 0, ptr, 164, 0, 64)) {
                    // The call failed; we retrieve the exact error message and revert with it
                    returndatacopy(0, 0, returndatasize()) // Copy the error message to the start of memory
                    revert(0, returndatasize()) // Revert with the error message
                }

                //---------------------------------//

                // Set poolAddress to nextPoolAddress
                poolAddress := nextPoolAddress
            }

            //---------------------------------//
        }
    }
}
