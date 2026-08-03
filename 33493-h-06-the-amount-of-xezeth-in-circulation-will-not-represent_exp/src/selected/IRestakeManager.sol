// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

// Minimal projection of the real Renzo IRestakeManager for the L1<->L2 bridge
// accounting PoC. xRenzoBridge.xReceive() only ever calls depositETH(); the full
// IRestakeManager pulls in the EigenLayer restaking interfaces (IOperatorDelegator,
// IStrategyManager, IDelegationManager, IEigenPod, IDepositQueue, IWithdrawQueue)
// which are the opaque restaking plumbing that computes protocol TVL and are NOT
// part of this finding's accounting. The ezETH mint-rate math itself is preserved
// verbatim from the audited RenzoOracle.calculateMintAmount in the test harness's
// RestakeManagerStub, so the L1 valuation the bug depends on is the REAL formula.
interface IRestakeManager {
    function depositETH() external payable;
}
