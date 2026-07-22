// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./41691-h-04-initialization-of-dyadxpv2-is-impossible-pashov-audit-g.sol";

/*//////////////////////////////////////////////////////////////////////////
    Driver for DYAD [H-04]: Initialization of DyadXPv2 is impossible.

    The synthetic Exploit runs initialize() over a measurable 88-note sample
    (exactly the 10% sample the original finding timed), derives the per-note
    gas, and extrapolates to the real mainnet supply of 882 — which exceeds the
    30M block gas limit. This test also measures the FULL 882-note cost directly
    (forge, unlike a real block, can supply that much gas) to prove the real
    on-chain cost. No fork, no cheatcodes.
//////////////////////////////////////////////////////////////////////////*/
contract DyadXPv2InitDoSTest is Test {
    uint256 constant BLOCK_GAS_LIMIT = 30_000_000;

    /// @notice HARM: the per-note cost measured over an 88-note sample,
    ///         extrapolated to the real 882-note supply, exceeds a full mainnet
    ///         block's gas — so the upgrade's initialize() can never be mined and
    ///         DyadXPv2 is permanently un-initializable. (This mirrors the
    ///         Playground reproduction exactly.)
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run(); // reverts unless the extrapolated 882-note cost exceeds the block gas limit

        uint256 sample = e.gasUsed(); // gas for the 88-note sample
        uint256 perNote = e.perNoteGas();
        uint256 extrapolated = e.extrapolatedMainnetGas();
        emit log_named_uint("initialize() gas @ 88-note sample", sample);
        emit log_named_uint("per-note gas                     ", perNote);
        emit log_named_uint("extrapolated to 882 notes        ", extrapolated);
        emit log_named_uint("mainnet block gas limit          ", BLOCK_GAS_LIMIT);

        // The sample itself fits in a block; the extrapolation to 882 does not.
        assertLt(sample, BLOCK_GAS_LIMIT, "the 88-note sample must fit in a block");
        assertGt(extrapolated, BLOCK_GAS_LIMIT, "882-note init must exceed the block gas limit");
        assertTrue(e.xp().initialized(), "sample loop ran to completion");
    }

    /// @notice Direct proof of the REAL full-supply cost: deploy DyadXPv2 wired to
    ///         a DNft reporting the real 882 supply and measure initialize()'s
    ///         actual gas. forge can supply >30M gas (a real block cannot), so the
    ///         call completes and we observe the true cost exceeding the limit.
    function test_fullSupply882_realCostExceedsBlockLimit() public {
        MockDNft dnft = new MockDNft(882);
        MockKeroseneVault kv = new MockKeroseneVault();
        MockDyad dy = new MockDyad();
        DyadXPv2 xp = new DyadXPv2(address(dnft), address(kv), address(dy));

        uint256 g = gasleft();
        xp.initialize(address(this));
        uint256 used = g - gasleft();

        emit log_named_uint("initialize() REAL gas @ 882 notes", used);
        assertGt(used, BLOCK_GAS_LIMIT, "real 882-note init must exceed the block gas limit");
        assertTrue(xp.initialized(), "882-note loop ran to completion under forge's high budget");
    }

    /// @notice Control: with a SMALL supply the very same initialize() fits
    ///         comfortably inside a block — proving the brick is caused by the
    ///         supply-scaling loop, not any fixed overhead.
    function test_smallSupply_initializesFine() public {
        uint256 smallSupply = 50;

        MockDNft dnft = new MockDNft(smallSupply);
        MockKeroseneVault kv = new MockKeroseneVault();
        MockDyad dy = new MockDyad();
        DyadXPv2 xp = new DyadXPv2(address(dnft), address(kv), address(dy));

        uint256 g = gasleft();
        xp.initialize(address(this));
        uint256 used = g - gasleft();

        emit log_named_uint("initialize() gas @ 50 notes", used);
        assertLt(used, BLOCK_GAS_LIMIT, "small supply must fit in a block");
        assertTrue(xp.initialized(), "small-supply init succeeds");

        uint256 extrapolatedTo882 = (used / smallSupply) * 882;
        emit log_named_uint("per-note cost extrapolated to 882", extrapolatedTo882);
        assertGt(extrapolatedTo882, BLOCK_GAS_LIMIT, "882-note init must exceed the block gas limit");
    }

    /// @notice Sanity: initialize() is one-shot (mirrors the OZ initializer),
    ///         so the brick cannot be worked around by re-calling it.
    function test_initialize_isOneShot() public {
        MockDNft dnft = new MockDNft(1);
        MockKeroseneVault kv = new MockKeroseneVault();
        MockDyad dy = new MockDyad();
        DyadXPv2 xp = new DyadXPv2(address(dnft), address(kv), address(dy));

        xp.initialize(address(this));
        vm.expectRevert(bytes("already initialized"));
        xp.initialize(address(this));
    }
}
