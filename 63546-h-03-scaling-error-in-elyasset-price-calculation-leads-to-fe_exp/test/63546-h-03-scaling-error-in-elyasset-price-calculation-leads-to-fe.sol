// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Elytra finding 63546 (H-03):
// "Scaling error in `elyAsset` price calculation leads to fee loss".
//
// ElytraOracleV1::updateElyAssetPrice computes the elyAsset price as
//     tempElyAssetPrice = totalValueInProtocol / elyAssetSupply
// WITHOUT the expected 1e18 scaling factor. Both operands carry 18 decimals
// (e.g. 2000e18 / 1000e18), so the division collapses the price to a bare
// integer (2) instead of the 18-decimal price (2e18). Because the raw ratio
// (2) is always far below the 18-decimal `oldElyAssetPrice` (1e18), the
// `tempElyAssetPrice > oldElyAssetPrice` reward/fee branch NEVER executes and
// `protocolFeeInHYPE` stays 0 forever. The protocol permanently collects zero
// performance fees it is entitled to.
//
// The audited ElytraProtocol/contracts repo is private/404 (dead-repo); the
// verbatim fee-calc block below is taken from the finding's embedded solidity
// and reproduced UNCHANGED. The bug is proven, not asserted.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 double used only to RECORD the foregone-fee magnitude as a
///      marker token to the protocol-treasury SINK. Not on the vulnerable path.
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
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — verbatim buggy fee-calc block inlined from the finding.
// ─────────────────────────────────────────────────────────────────────────────
contract ElytraOracleV1 {
    uint256 public oldElyAssetPrice;   // stored elyAsset price, 18-decimal scale
    uint256 public protocolFeeInBPS;   // performance fee, basis points
    uint256 public lastProtocolFeeInHYPE; // last accrued protocol performance fee

    constructor(uint256 _oldElyAssetPrice, uint256 _protocolFeeInBPS) {
        oldElyAssetPrice = _oldElyAssetPrice;
        protocolFeeInBPS = _protocolFeeInBPS;
    }

    /// @notice Recomputes the elyAsset price and accrues the protocol
    ///         performance fee on any price increase. `totalValueInProtocol`
    ///         and `elyAssetSupply` are both 18-decimal quantities.
    function updateElyAssetPrice(uint256 totalValueInProtocol, uint256 elyAssetSupply) external {
        uint256 protocolFeeInHYPE;
        {
            uint256 tempElyAssetPrice = totalValueInProtocol / elyAssetSupply; // @> missing 1e18 scale: 18-dec/18-dec collapses price to a bare integer, always < oldElyAssetPrice
            if (tempElyAssetPrice > oldElyAssetPrice) {
                uint256 increaseInElyAssetPrice = tempElyAssetPrice - oldElyAssetPrice;
                uint256 rewardInHYPE = (increaseInElyAssetPrice * elyAssetSupply) / 1e18;
                protocolFeeInHYPE = (rewardInHYPE * protocolFeeInBPS) / 10_000;
            }
        }
        lastProtocolFeeInHYPE = protocolFeeInHYPE;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract — identical except the recommended 1e18 scaling factor is
// applied to tempElyAssetPrice. This is the negative control.
// ─────────────────────────────────────────────────────────────────────────────
contract ElytraOracleV1Fixed {
    uint256 public oldElyAssetPrice;
    uint256 public protocolFeeInBPS;
    uint256 public lastProtocolFeeInHYPE;

    constructor(uint256 _oldElyAssetPrice, uint256 _protocolFeeInBPS) {
        oldElyAssetPrice = _oldElyAssetPrice;
        protocolFeeInBPS = _protocolFeeInBPS;
    }

    function updateElyAssetPrice(uint256 totalValueInProtocol, uint256 elyAssetSupply) external {
        uint256 protocolFeeInHYPE;
        {
            uint256 tempElyAssetPrice = (totalValueInProtocol * 1e18) / elyAssetSupply; // FIX: scale to 18 decimals
            if (tempElyAssetPrice > oldElyAssetPrice) {
                uint256 increaseInElyAssetPrice = tempElyAssetPrice - oldElyAssetPrice;
                uint256 rewardInHYPE = (increaseInElyAssetPrice * elyAssetSupply) / 1e18;
                protocolFeeInHYPE = (rewardInHYPE * protocolFeeInBPS) / 10_000;
            }
        }
        lastProtocolFeeInHYPE = protocolFeeInHYPE;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: run the REAL buggy path with realistic 18-decimal inputs and
// prove the protocol accrues ZERO fee where the correct code accrues 100e18.
// The foregone-fee delta is recorded on a MARKER token to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    // Realistic 18-decimal protocol state (from the finding's worked example).
    uint256 internal constant OLD_PRICE = 1e18;              // stored price 1.0
    uint256 internal constant TOTAL_VALUE = 2000e18;         // total value in protocol
    uint256 internal constant ELY_SUPPLY = 1000e18;          // elyAsset supply -> true price 2.0
    uint256 internal constant FEE_BPS = 1000;                // 10% performance fee

    ElytraOracleV1 public vuln;
    ElytraOracleV1Fixed public fixedOracle;
    MiniToken public marker;

    // Exposed results.
    uint256 public vulnFee;      // fee accrued by the buggy code (expect 0)
    uint256 public correctFee;   // fee the correct code accrues (expect 100e18)
    uint256 public foregoneFee;  // permanently uncollected fee
    uint256 public sinkMarkerBalance;
    address public vulnAddr;
    address public markerAddr;

    constructor() {
        marker = new MiniToken("Foregone Protocol Fee", "LOCKED-HYPE"); // deploy index 0
        vuln = new ElytraOracleV1(OLD_PRICE, FEE_BPS);                  // deploy index 1
        fixedOracle = new ElytraOracleV1Fixed(OLD_PRICE, FEE_BPS);      // deploy index 2

        vulnAddr = address(vuln);
        markerAddr = address(marker);
    }

    function run() external payable {
        // --- run the REAL buggy path: price collapses to 2, branch never fires ---
        vuln.updateElyAssetPrice(TOTAL_VALUE, ELY_SUPPLY);
        vulnFee = vuln.lastProtocolFeeInHYPE();

        // --- run the fixed path on identical inputs: branch fires, fee accrues ---
        fixedOracle.updateElyAssetPrice(TOTAL_VALUE, ELY_SUPPLY);
        correctFee = fixedOracle.lastProtocolFeeInHYPE();

        // --- harm: the protocol accrues NOTHING where it is owed 100e18 ---
        require(vulnFee == 0, "vuln should accrue zero fee");
        require(correctFee == 100e18, "fixed should accrue 100e18 fee");

        foregoneFee = correctFee - vulnFee; // 100e18 permanently uncollected

        // record the foregone protocol fee on the marker token to the SINK
        marker.mint(SINK, foregoneFee);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
