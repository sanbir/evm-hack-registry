// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of KittenSwap finding 58153 (H-02):
// "Loss of claimable rewards upon gauge deactivation".
//
// Real audited source (Solidly/Velodrome-style `Voter`). The vulnerable
// statements are reproduced VERBATIM from the finding's embedded snippets; the
// vulnerable line is marked @>:
//   protocol KittenSwap (2025-05-07)
//   contract Voter  (killGauge / _updateFor / notifyRewardAmount)
//   report   github.com/pashov/audits/blob/master/team/md/KittenSwap-security-review_2025-05-07.md
//
// Root cause: `killGauge` sets `claimable[_gauge] = 0`, permanently discarding
// every reward the gauge already accrued via `_updateFor`. Because `_updateFor`
// advances `supplyIndex[_gauge]` to the global `index` when it accrues, reviving
// the gauge afterwards accrues NOTHING for the elapsed period (delta == 0), so
// the zeroed rewards are gone forever. The base tokens that funded those rewards
// (pulled into the Voter by `notifyRewardAmount`) are stranded in the Voter and
// can never reach the gauge's stakers.
//
// The vulnerable statements (`claimable[_gauge] = 0;`, the `_updateFor` accrual
// block, and `notifyRewardAmount`'s index update) are byte-for-byte the audited
// source. Non-vulnerable dependencies (ERC20 base token, gauge recipient, the
// createGauge+vote setup, and reward delivery in `distribute`) are faithful
// minimal doubles with real transfers and real accounting.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @dev Faithful minimal ERC20 double for the `base` reward token.
contract BaseToken {
    string public name = "KittenSwap Reward";
    string public symbol = "KITTEN";
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

/// @dev Faithful minimal gauge double: it only needs to be a distinct address
///      that can hold `base` tokens delivered by `Voter.distribute`. Its balance
///      of `base` is the reward its stakers can actually claim.
contract Gauge {
    address public immutable pool;
    constructor(address _pool) {
        pool = _pool;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — KittenSwap `Voter`. `killGauge`, the `_updateFor`
// accrual block, and `notifyRewardAmount` are reproduced VERBATIM.
// ─────────────────────────────────────────────────────────────────────────────
contract Voter {
    address public base;              // reward token distributed to gauges
    address public governor;          // may create gauges / cast setup votes
    address public emergencyCouncil;  // may kill / revive gauges

    uint256 public totalWeight;                      // total vote weight
    uint256 public index;                            // global reward index
    mapping(address => uint256) public weights;      // pool => vote weight
    mapping(address => address) public gauges;       // pool => gauge
    mapping(address => address) public poolForGauge; // gauge => pool
    mapping(address => bool) public isAlive;         // gauge => alive
    mapping(address => uint256) public supplyIndex;  // gauge => last seen index
    mapping(address => uint256) public claimable;    // gauge => accrued rewards

    event GaugeKilled(address indexed gauge);
    event GaugeRevived(address indexed gauge);
    event NotifyReward(address indexed sender, address indexed reward, uint256 amount);
    event DistributeReward(address indexed sender, address indexed gauge, uint256 amount);

    constructor(address _base) {
        base = _base;
        governor = msg.sender;
        emergencyCouncil = msg.sender;
    }

    // ── faithful minimal double of createGauge + vote (registers a gauge for a
    //    pool with a given vote weight, mirroring the state createGauge+vote set:
    //    gauges/poolForGauge/isAlive/weights/totalWeight). Not the vulnerable path. ──
    function setupGauge(address _pool, uint256 _weight) external returns (address) {
        require(msg.sender == governor, "not governor");
        Gauge g = new Gauge(_pool);
        address _gauge = address(g);
        gauges[_pool] = _gauge;
        poolForGauge[_gauge] = _pool;
        isAlive[_gauge] = true;
        weights[_pool] += _weight;
        totalWeight += _weight;
        supplyIndex[_gauge] = index; // new gauge starts at the current global index
        return _gauge;
    }

    // ── VERBATIM: reward distribution entrypoint. Pulls the reward in and bumps
    //    the global index by amount/totalWeight (scaled by 1e18). ──
    function notifyRewardAmount(uint amount) external {
        _safeTransferFrom(base, msg.sender, address(this), amount); // transfer the distro in
        uint256 _ratio = (amount * 1e18) / totalWeight; // 1e18 adjustment is removed during claim
        if (_ratio > 0) {
            index += _ratio;
        }
        emit NotifyReward(msg.sender, base, amount);
    }

    function updateFor(address[] memory _gauges) external {
        for (uint256 i = 0; i < _gauges.length; i++) {
            _updateFor(_gauges[i]);
        }
    }

    // ── VERBATIM accrual: the `_delta`/`_share`/`if (isAlive[_gauge])` block is
    //    byte-for-byte the audited source (finding snippet). ──
    function _updateFor(address _gauge) internal {
        address _pool = poolForGauge[_gauge];
        uint256 _supplied = weights[_pool];
        if (_supplied > 0) {
            uint _supplyIndex = supplyIndex[_gauge];
            uint _index = index; // get global index0 for accumulated distro
            supplyIndex[_gauge] = _index; // update _gauge current position to global position
            uint _delta = _index - _supplyIndex; // see if there is any difference that need to be accrued
            if (_delta > 0) {
                uint _share = (uint(_supplied) * _delta) / 1e18; // add accrued difference for each supplied token
                if (isAlive[_gauge]) {
                    claimable[_gauge] += _share;
                }
            }
        } else {
            supplyIndex[_gauge] = index; // new users are set to the default global state
        }
    }

    // ── faithful minimal double of distribute: accrue, then deliver the accrued
    //    `claimable` balance to the gauge (real base-token transfer). The real
    //    Voter's minter/DURATION/left() guards are non-vulnerable and omitted. ──
    function distribute(address _gauge) public {
        _updateFor(_gauge); // should set claimable to 0 if killed
        uint _claimable = claimable[_gauge];
        if (_claimable > 0) {
            claimable[_gauge] = 0;
            _safeTransfer(base, _gauge, _claimable);
            emit DistributeReward(msg.sender, _gauge, _claimable);
        }
    }

    // ── VERBATIM: the vulnerable deactivation function. ──
    function killGauge(address _gauge) external {
        require(msg.sender == emergencyCouncil, "not emergency council");
        require(isAlive[_gauge], "gauge already dead");
        isAlive[_gauge] = false;
        claimable[_gauge] = 0; // @> VULN: accrued rewards permanently zeroed; unrecoverable even after reviveGauge (supplyIndex already advanced, so no re-accrual)
        emit GaugeKilled(_gauge);
    }

    // ── VERBATIM: reactivation only flips the flag; it cannot restore claimable. ──
    function reviveGauge(address _gauge) external {
        require(msg.sender == emergencyCouncil, "not emergency council");
        require(!isAlive[_gauge], "gauge already alive");
        isAlive[_gauge] = true;
        emit GaugeRevived(_gauge);
    }

    // ── faithful safe-transfer doubles (real transfers, return-value checked). ──
    function _safeTransfer(address token, address to, uint256 value) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: two equally-weighted gauges accrue equal rewards; the
// emergencyCouncil kills gauge A (zeroing its accrued rewards) then revives it.
// Prove gauge A's accrued rewards are permanently lost — A receives 0 on
// distribution while the identical gauge B receives its full share, and the lost
// base tokens are stranded in the Voter. The permanently-lost magnitude is
// minted to SINK 0x…D00d as the marker of the destroyed rewards.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    BaseToken public base;   // child nonce 1 (profit / marker token)
    Voter public voter;      // child nonce 2 (VULN)
    address public gaugeA;
    address public gaugeB;

    uint256 public accruedBeforeKill; // rewards gauge A had accrued before kill
    uint256 public gaugeAReceived;    // base delivered to gauge A after kill+revive
    uint256 public gaugeBReceived;    // base delivered to identical gauge B
    uint256 public lostRewards;       // permanently destroyed reward magnitude
    uint256 public strandedInVoter;   // base stuck in the Voter, unclaimable

    uint256 internal constant WEIGHT = 100e18;        // each pool's vote weight
    uint256 internal constant REWARD = 200e18;        // total reward distributed

    address internal constant POOL_A = address(0xA0);
    address internal constant POOL_B = address(0xB0);

    constructor() {
        base = new BaseToken();          // child nonce 1
        voter = new Voter(address(base)); // child nonce 2 (VULN); deployer=council=governor
        gaugeA = voter.setupGauge(POOL_A, WEIGHT);
        gaugeB = voter.setupGauge(POOL_B, WEIGHT);
    }

    function run() external {
        // fund the reward distributor (this Exploit acts as the distributor)
        base.mint(address(this), REWARD);
        base.approve(address(voter), type(uint256).max);

        // 1) distribute rewards -> global index rises; base pulled into the Voter
        voter.notifyRewardAmount(REWARD); // index += 200e18*1e18/200e18 = 1e18

        // 2) accrue: each gauge earns weight*delta/1e18 = 100e18 of claimable
        address[] memory gs = new address[](2);
        gs[0] = gaugeA;
        gs[1] = gaugeB;
        voter.updateFor(gs);

        accruedBeforeKill = voter.claimable(gaugeA); // 100e18, rightfully gauge A's

        // 3) emergencyCouncil deactivates gauge A -> claimable[A] = 0 (rewards lost)
        voter.killGauge(gaugeA);

        // 4) reviving does NOT restore the zeroed rewards (supplyIndex already at index)
        voter.reviveGauge(gaugeA);

        // 5) settle both gauges: A gets nothing, identical B gets its full share
        voter.distribute(gaugeA);
        voter.distribute(gaugeB);

        gaugeAReceived = base.balanceOf(gaugeA); // 0
        gaugeBReceived = base.balanceOf(gaugeB); // 100e18
        strandedInVoter = base.balanceOf(address(voter)); // 100e18 stuck, unclaimable
        lostRewards = accruedBeforeKill;

        // mark the permanently-destroyed reward magnitude at SINK
        base.mint(SINK, lostRewards);

        // harm: gauge A had accrued a full share, yet killGauge destroyed it —
        // A receives 0 after revival while identical gauge B receives 100e18, and
        // the equivalent base tokens are stranded in the Voter forever.
        require(accruedBeforeKill == WEIGHT, "no rewards accrued to gauge A");
        require(gaugeAReceived == 0, "gauge A unexpectedly received rewards");
        require(gaugeBReceived == accruedBeforeKill, "control gauge B did not receive its share");
        require(strandedInVoter == accruedBeforeKill, "lost rewards not stranded in Voter");
        require(base.balanceOf(SINK) == accruedBeforeKill, "loss marker mismatch");
    }
}
