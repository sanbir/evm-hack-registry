// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
    跡 (ato) jp. “a trace — the mark left behind” · a curve that retraces

    https://at0.io
    https://x.com/at0dev

        ato  ·  bonding curve

    21m ┤                                                             ∞  800x
        │                               ┊                    ╭────────╯
        │                               ┊            ╭───────╯      ╭╯
        │                               ┊     ╭──────╯       ╭╮    ╭╯
    15m ┤                              ╭◯─────╯             ╭╯│   ╭╯     600x
        │                        ╭─────╯┊                  ╭╯ │ ╭─╯
        │                   ╭────╯      ┊           ╭╮   ╭─╯  │╭╯
    10m ┤              ╭────╯           ┊         ╭─╯│  ╭╯    ╰╯         400x
        │          ╭───╯                ┊        ╭╯  │╭─╯
        │       ╭──╯                    ┊ ╭─╮  ╭─╯   ╰╯
        │     ╭─╯                  ╭╮   ◯─╯ │╭─╯
     5m ┤   ╭─╯                 ╭──╯│ ╭─╯   ╰╯                           200x
        │ ╭─╯            ╭─╮  ╭─╯   ╰─╯ ┊
        │ │      ╭╮  ╭───╯ ╰──╯         ┊
        │●╯──────╯╰──╯
      0 └──────────────────┴───────────────────┴──────────────────┴───── Ξ
                          500                 1000               1500

        ╭─ mint curve      ╭╮ price (sawtooth)      ┊◯ deprecation

    ato is an ERC-20 minted along a bonding curve embedded in a Uniswap v4 hook.
    The hook is the sole counterparty — every buy mints along a forward curve and
    every sell redeems along its inverse, paid from a reserve the hook holds.
    Supply approaches a hard asymptote of 21,000,000 and never reaches it;
    price rises exponentially with cumulative ETH and retraces ~50% at each halving
    of remaining supply — the trace the curve leaves behind.

    The retrace is not incidental: it is the engine that makes mining yield and
    LP volume work.
*/

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title  BaseHook — minimal production IHooks base (no dependency on v4-periphery)
/// @notice Implements every IHooks entrypoint as a reverting default and validates that
///         the deployed address encodes exactly the declared permissions. Subclasses
///         override only the hooks they enable. (This repo's v4-periphery has no BaseHook;
///         `lib/v4-core/src/test/BaseTestHooks.sol` is test-only, so we ship our own.)
abstract contract BaseHook is IHooks {
    error NotPoolManager();
    error HookNotImplemented();

    IPoolManager public immutable poolManager;

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @notice The permissions this hook declares; must match the deployed address bits.
    function getHookPermissions() public pure virtual returns (Hooks.Permissions memory);

    function beforeInitialize(address, PoolKey calldata, uint160) external virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external virtual returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external virtual returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        virtual
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        virtual
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
