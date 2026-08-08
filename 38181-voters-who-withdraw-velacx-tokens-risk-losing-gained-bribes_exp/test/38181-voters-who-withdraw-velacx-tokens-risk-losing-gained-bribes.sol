// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Alchemix — Voters who withdraw veALCX tokens risk losing gained bribes
    (Immunefi, xBentley, finding #38181)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause (same underlying defect as finding #38175, reported
    independently by a different researcher): the standard withdrawal
    sequence — reset() -> startCooldown() -> withdraw() — ends by burning the
    veALCX tokenId. Voter::claimBribes() gates on
    IVotingEscrow(veALCX).isApprovedOrOwner(msg.sender, tokenId), which can
    never succeed again once the token is burned. This reduction walks the
    FULL 3-step sequence (reset, startCooldown, withdraw) that this finding's
    own PoC exercises, rather than a bare withdraw() call, to keep the two
    findings' write-ups and PoCs distinct even though they share a root cause.
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

/// @notice Reduced VotingEscrow modeling the full withdrawal sequence used by
///         this finding's own PoC: reset() clears the vote, startCooldown()
///         marks the position as unlocking, withdraw() burns it.
contract VotingEscrow {
    mapping(uint256 => address) public idToOwner;
    mapping(uint256 => bool) public voted;
    mapping(uint256 => bool) public cooldownStarted;

    constructor(uint256 tokenId, address owner) {
        idToOwner[tokenId] = owner;
        voted[tokenId] = true; // the position has an active vote before reset()
    }

    function isApprovedOrOwner(address who, uint256 tokenId) external view returns (bool) {
        return idToOwner[tokenId] == who;
    }

    /// @notice src/Voter.sol::reset (reduced) -- clears the vote flag only.
    function reset(uint256 tokenId) external {
        require(idToOwner[tokenId] == msg.sender, "not owner");
        voted[tokenId] = false;
    }

    /// @notice src/VotingEscrow.sol::startCooldown (reduced)
    function startCooldown(uint256 tokenId) external {
        require(idToOwner[tokenId] == msg.sender, "not owner");
        require(!voted[tokenId], "must reset before cooldown");
        cooldownStarted[tokenId] = true;
    }

    /// @notice src/VotingEscrow.sol::withdraw (reduced)
    function withdraw(uint256 tokenId) external {
        require(idToOwner[tokenId] == msg.sender, "not owner");
        require(cooldownStarted[tokenId], "cooldown not started");

        // @> VULN: the token is burned unconditionally at the end of the
        //          standard reset -> startCooldown -> withdraw sequence, with
        //          no check for outstanding bribe rewards earned via voting.
        //          Once idToOwner[tokenId] becomes address(0), Voter's
        //          isApprovedOrOwner-gated claimBribes can never pass again.
        idToOwner[tokenId] = address(0);
        // FIX: require all outstanding bribes are claimed (or force-claim
        //      them) as part of this withdrawal sequence, before the burn.
    }
}

/// @notice Reduced third-party Bribe contract, gated on current veALCX
///         ownership exactly like the real Voter::claimBribes.
contract Bribe {
    VotingEscrow public immutable VE_CONTRACT;
    MockBAL public immutable BAL_TOKEN;
    mapping(uint256 => uint256) public earned;

    constructor(VotingEscrow ve, MockBAL bal) {
        VE_CONTRACT = ve;
        BAL_TOKEN = bal;
    }

    function notifyBribe(uint256 tokenId, uint256 amount) external {
        earned[tokenId] += amount;
    }

    function balanceHeld() external view returns (uint256) {
        return BAL_TOKEN.balanceOf(address(this));
    }

    /// @notice src/Voter.sol::claimBribes ownership gate, inlined for the
    ///         reduced single-bribe model.
    function getRewardForOwner(uint256 tokenId, address caller) external {
        require(VE_CONTRACT.isApprovedOrOwner(caller, tokenId), "not approved or owner");
        uint256 amt = earned[tokenId];
        earned[tokenId] = 0;
        BAL_TOKEN.transfer(caller, amt);
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
        // Exploit contract itself holds the veALCX position (a voter who
        // earned bribes and now wants to withdraw their expired lock).
        ve = new VotingEscrow(TOKEN_ID, address(this));
        bribe = new Bribe(ve, bal);

        // Fund the bribe with 100k BAL earned from this epoch's vote.
        bal.mint(address(bribe), BRIBE_AMOUNT);
        bribe.notifyBribe(TOKEN_ID, BRIBE_AMOUNT);
    }

    function run() external {
        // Sanity: bribe is earned and claimable right now.
        require(bribe.earned(TOKEN_ID) == BRIBE_AMOUNT, "sanity: bribe should be earned");
        require(ve.isApprovedOrOwner(address(this), TOKEN_ID), "sanity: should own token before withdraw sequence");

        // Standard withdrawal sequence, exactly as this finding's own PoC
        // walks it: (i) reset the vote, (ii) start cooldown, (iii) withdraw.
        ve.reset(TOKEN_ID);
        ve.startCooldown(TOKEN_ID);
        ve.withdraw(TOKEN_ID);

        // The token is now owned by address(0).
        require(!ve.isApprovedOrOwner(address(this), TOKEN_ID), "sanity: token should be burned (owner = 0)");

        // HARM: attempting to claim the 100k BAL bribe now reverts, and will
        // revert forever -- isApprovedOrOwner can never be true again.
        (bool ok, ) = address(bribe).call(
            abi.encodeWithSelector(Bribe.getRewardForOwner.selector, TOKEN_ID, address(this))
        );
        require(!ok, "harm not demonstrated: bribe claim should revert after the withdraw sequence burns the token");

        // HARM confirmed: the 100k BAL bribe remains stuck in the Bribe
        // contract, permanently unreachable by anyone.
        require(bribe.balanceHeld() == BRIBE_AMOUNT, "harm not demonstrated: bribe funds should be frozen, not lost/moved");
        require(bribe.earned(TOKEN_ID) == BRIBE_AMOUNT, "harm not demonstrated: earned() should still show the frozen amount");
    }
}
