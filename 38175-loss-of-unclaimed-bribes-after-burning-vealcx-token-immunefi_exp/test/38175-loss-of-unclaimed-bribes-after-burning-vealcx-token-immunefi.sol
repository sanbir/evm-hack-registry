// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Alchemix — Loss of unclaimed bribes after burning a veALCX token
    (Immunefi, Limbooo, finding #38175)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: VotingEscrow::withdraw() claims the token's unclaimed ALCX
    rewards + FLUX before burning the tokenId, but it does NOT claim the
    bribe rewards the token earned by voting. Once the token is burned,
    `idToOwner[tokenId]` becomes address(0), so Voter::claimBribes()'s
    ownership check (`isApprovedOrOwner`) can never succeed for that tokenId
    again — the bribe reward is frozen in the Bribe contract forever, with
    no path for the former owner (or anyone else) to retrieve it.

    The vulnerable withdraw() body is reduced but the burn + ownership-gate
    interaction is preserved verbatim in spirit: burn happens unconditionally
    on withdraw, with no check for outstanding bribe claims.
//////////////////////////////////////////////////////////////////////////*/

contract MockBAL {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "insufficient balance");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced VotingEscrow. Tracks ownership of a single tokenId and
///         burns it on withdraw() — exactly as in the real contract, minus
///         unrelated lock-accounting fields.
contract VotingEscrow {
    mapping(uint256 => address) public idToOwner;

    constructor(uint256 tokenId, address owner) {
        idToOwner[tokenId] = owner;
    }

    function isApprovedOrOwner(address who, uint256 tokenId) external view returns (bool) {
        return idToOwner[tokenId] == who;
    }

    /// @notice src/VotingEscrow.sol::withdraw (reduced)
    function withdraw(uint256 tokenId) external {
        require(idToOwner[tokenId] == msg.sender, "not owner");

        // Real withdraw() claims unclaimed ALCX rewards + FLUX here:
        //   IRewardsDistributor(distributor).claim(_tokenId, false);
        //   IFluxToken(FLUX).claimFlux(_tokenId, IFluxToken(FLUX).getUnclaimedFlux(_tokenId));
        // (omitted here — unrelated to the bribe-loss root cause; the ALCX/FLUX
        //  claim paths are unaffected by this bug and are not part of the harm.)

        // @> VULN: the token is burned unconditionally, with no check for
        //          outstanding bribe rewards earned via Voter voting. Once
        //          idToOwner[tokenId] becomes address(0), Voter::claimBribes's
        //          ownership check can never pass again for this tokenId.
        idToOwner[tokenId] = address(0);
        // FIX: require bribes are claimed first (or force-claim them here),
        //      e.g. `voter.claimBribes(allBribesFor(tokenId), tokenId);` before burn.
    }
}

/// @notice Reduced third-party Bribe contract. Holds BAL bribe tokens earned
///         by a tokenId for voting, releasable only to the token's owner.
contract Bribe {
    VotingEscrow public immutable ve;
    MockBAL public immutable bal;
    mapping(uint256 => uint256) public earned;

    constructor(VotingEscrow _ve, MockBAL _bal) {
        ve = _ve;
        bal = _bal;
    }

    function notifyBribe(uint256 tokenId, uint256 amount) external {
        earned[tokenId] += amount;
    }

    function balanceHeld() external view returns (uint256) {
        return bal.balanceOf(address(this));
    }

    /// @notice src/Voter.sol::claimBribes ownership gate, inlined here for
    ///         the reduced single-bribe model.
    function getRewardForOwner(uint256 tokenId, address caller) external {
        require(ve.isApprovedOrOwner(caller, tokenId), "not approved or owner");
        uint256 amt = earned[tokenId];
        earned[tokenId] = 0;
        bal.transfer(caller, amt);
    }
}

contract Exploit {
    uint256 public constant TOKEN_ID = 1;
    uint256 public constant BRIBE_AMOUNT = 100_000 ether;

    MockBAL public bal;
    VotingEscrow public ve;
    Bribe public bribe;

    constructor() {
        bal = new MockBAL();
        // Exploit contract itself holds the veALCX position (stands in for "Alice").
        ve = new VotingEscrow(TOKEN_ID, address(this));
        bribe = new Bribe(ve, bal);

        // Fund the bribe with 100k BAL earned by Alice's vote in a prior epoch.
        bal.mint(address(bribe), BRIBE_AMOUNT);
        bribe.notifyBribe(TOKEN_ID, BRIBE_AMOUNT);
    }

    function run() external {
        // Sanity: Alice's bribe reward is claimable right now (she is still owner).
        require(ve.isApprovedOrOwner(address(this), TOKEN_ID), "sanity: should own token before withdraw");
        require(bribe.earned(TOKEN_ID) == BRIBE_AMOUNT, "sanity: bribe should be earned");

        // Alice withdraws her expired lock. This claims her ALCX+FLUX (not
        // modeled here) and burns the tokenId -- but does NOT claim her bribes.
        ve.withdraw(TOKEN_ID);

        // The token is now owned by address(0); Alice can never satisfy the
        // ownership check again.
        require(!ve.isApprovedOrOwner(address(this), TOKEN_ID), "sanity: token should be burned (owner = 0)");

        // HARM: Alice attempts to claim her 100k BAL bribe -- it reverts, and
        // will revert forever, because isApprovedOrOwner(alice, tokenId) can
        // never be true again for a burned token.
        (bool ok, ) = address(bribe).call(
            abi.encodeWithSelector(Bribe.getRewardForOwner.selector, TOKEN_ID, address(this))
        );
        require(!ok, "harm not demonstrated: bribe claim should revert after withdraw burns the token");

        // HARM confirmed: the 100k BAL bribe remains stuck in the Bribe
        // contract, permanently unreachable by anyone.
        require(bribe.balanceHeld() == BRIBE_AMOUNT, "harm not demonstrated: bribe funds should be frozen, not lost/moved");
        require(bribe.earned(TOKEN_ID) == BRIBE_AMOUNT, "harm not demonstrated: earned() should still show the frozen amount");
    }
}
