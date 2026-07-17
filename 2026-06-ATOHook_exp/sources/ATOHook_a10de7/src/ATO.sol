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

import {ERC20} from "solady/tokens/ERC20.sol";

/// @title  ato — the trace
/// @notice ERC-20 minted exclusively through the bonding-curve hook. mint/burn are
///         gated to the hook (the sole counterparty); there is no other issuance path,
///         so `totalSupply()` tracks the curve's minted supply exactly.
contract ATO is ERC20 {
    /// @dev The only address allowed to mint/burn. Set once at construction.
    address public immutable hook;

    error NotHook();

    constructor(address hook_) {
        hook = hook_;
    }

    function name() public pure override returns (string memory) {
        return "ato";
    }

    function symbol() public pure override returns (string memory) {
        return "ato";
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    function mint(address to, uint256 amount) external onlyHook {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyHook {
        _burn(from, amount);
    }
}
