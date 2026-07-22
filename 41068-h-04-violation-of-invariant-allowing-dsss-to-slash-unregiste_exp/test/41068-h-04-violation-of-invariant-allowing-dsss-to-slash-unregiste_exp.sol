// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./41068-h-04-violation-of-invariant-allowing-dsss-to-slash-unregiste.sol";

/*//////////////////////////////////////////////////////////////
    Karak — [H-04] Violation of Invariant Allowing DSSs to Slash
    Unregistered Operators. Finding #41068 (Code4rena, 20centclub)
    — HIGH.

    Drives the synthetic Exploit and re-asserts the harm directly,
    contrasted against a control where the operator does NOT try
    to unregister early and the slash finalizes as expected while
    still registered (the normal, invariant-respecting flow).
//////////////////////////////////////////////////////////////*/
contract Karak41068Test is Test {
    Exploit exploit;

    function setUp() public {
        // Match the Playground's fixed anvil block timestamp so the
        // registry test and the Playground synthetic behave identically,
        // and so backdated request timestamps never underflow.
        vm.warp(0x65b0a380);
        exploit = new Exploit();
    }

    /// @notice Control: when the operator stays registered (does not
    ///         unregister while a slash is pending), the slash finalizes
    ///         normally against a still-registered operator — the intended,
    ///         invariant-respecting flow.
    function test_control_stillRegistered_slashFinalizesNormally() public {
        CoreLike core = new CoreLike();
        address operator = address(new Operator());
        address dss = address(new DSS());

        core.registerAndStake(operator, dss);
        uint256 slashId = core.requestSlashing(dss, operator, 2 days);

        // Operator never unregisters here.
        assertTrue(core.isOperatorRegisteredToDSS(operator, dss));

        core.finalizeSlashing(slashId);

        assertEq(core.slashedCount(operator), 1);
        assertTrue(core.isOperatorRegisteredToDSS(operator, dss), "still registered, as expected");
    }

    /// @notice HARM: the operator unregisters from the DSS the moment their
    ///         unstake delay matures, WHILE a slash request against them is
    ///         still pending. unregisterOperatorFromDSS() never checks for
    ///         that pending slash, and finalizeSlashing() never re-checks
    ///         the operator's registration — so the slash finalizes anyway,
    ///         against an operator who is no longer registered with the DSS
    ///         at all. This breaks the invariant "only DSSs an operator is
    ///         registered with can slash said operator."
    function test_run_unregisterBeforeSlashFinalizes_violatesInvariant() public {
        exploit.run();

        CoreLike core = exploit.core();
        address operator = exploit.operator();
        address dss = exploit.dss();

        // The operator is fully unregistered from the DSS...
        assertFalse(core.isOperatorRegisteredToDSS(operator, dss));

        // ...yet the DSS successfully slashed them anyway.
        assertEq(core.slashedCount(operator), 1);

        // Re-confirm directly: finalizing a NEW slash request against this
        // same (now-unregistered) operator is blocked by requestSlashing's
        // registration check — showing the invariant violation is
        // specifically that an ALREADY-PENDING slash survives unregister,
        // not that the DSS can slash freely at any time.
        vm.expectRevert(bytes("not registered"));
        core.requestSlashing(dss, operator, 0);
    }
}
