// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/*//////////////////////////////////////////////////////////////////////////
    Zaros — Incorrect logic for checking isFillPriceValid
    (cryptedOji, Codehawks 2024-07-zaros, finding #37984)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable `isFillPriceValid` computation from
    SettlementBranch.fillOffchainOrders is inlined VERBATIM (comparison
    operators swapped for buy/sell orders). The Exploit opens a long
    position, places a take-profit (sell) offchain order at a target price,
    reports a fill price that clears the target, and shows the take-profit
    is silently skipped — then the market reverses and the position's
    unrealized profit turns into a loss the trader could never lock in (no
    fork, no cheatcodes).
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Root cause: isFillPriceValid is meant to gate offchain
    (take-profit / stop-loss style) orders so they only execute once the
    reported fill price crosses the trader's chosen target in the
    direction that makes economic sense: a BUY order should fill once
    fillPrice <= targetPrice (don't pay more than intended); a SELL order
    should fill once fillPrice >= targetPrice (don't sell for less than
    intended / lock in a target profit). The deployed code instead wrote:

        isFillPriceValid = (isBuy && target <= fill) || (!isBuy && target >= fill)

    — both comparisons are backwards. Any order whose target/fill relationship
    matches how a rational trader would actually set it is rejected and the
    keeper silently `continue`s past it (no revert, by design, so it keeps
    processing the rest of the batch) — the order simply never fills, ever.
//////////////////////////////////////////////////////////////*/

/// @notice Reduced SettlementBranch. Tracks one trading account's long
///         position and a queue of offchain (take-profit/stop-loss style)
///         orders, gated by the broken isFillPriceValid check.
contract SettlementBranch {
    struct TradingAccount {
        int256 positionSize; // 1e18 fixed point, positive = long
        uint256 entryPrice; // 1e18 fixed point
    }

    struct OffchainOrder {
        int128 sizeDelta; // sign selects buy/sell semantics
        uint256 targetPrice; // 1e18 fixed point
        bool filled;
    }

    mapping(uint256 => TradingAccount) public accounts;
    mapping(uint256 => OffchainOrder) public orders;
    uint256 public orderCount;

    function openPosition(uint256 accountId, int256 size, uint256 entryPrice) external {
        accounts[accountId] = TradingAccount({positionSize: size, entryPrice: entryPrice});
    }

    function createOffchainOrder(int128 sizeDelta, uint256 targetPrice) external returns (uint256 id) {
        id = ++orderCount;
        orders[id] = OffchainOrder({sizeDelta: sizeDelta, targetPrice: targetPrice, filled: false});
    }

    function unrealizedPnl(uint256 accountId, uint256 markPriceX18) public view returns (int256) {
        TradingAccount memory a = accounts[accountId];
        return (a.positionSize * (int256(markPriceX18) - int256(a.entryPrice))) / 1e18;
    }

    /// @notice Attempts to fill a batch of offchain orders at the reported
    ///         fill price. Orders whose price condition is not "valid" are
    ///         silently skipped (never reverted) so the rest of the batch
    ///         can still process.
    function fillOffchainOrders(uint256[] calldata orderIds, uint256 fillPriceX18) external {
        for (uint256 i = 0; i < orderIds.length; i++) {
            OffchainOrder storage offchainOrder = orders[orderIds[i]];
            if (offchainOrder.filled) continue;

            bool isBuyOrder = offchainOrder.sizeDelta > 0;

            // @> VULN: comparison operators are swapped for both branches
            bool isFillPriceValid = (isBuyOrder && offchainOrder.targetPrice <= fillPriceX18)
                || (!isBuyOrder && offchainOrder.targetPrice >= fillPriceX18);
            // FIX: (isBuyOrder && offchainOrder.targetPrice >= fillPriceX18)
            //      || (!isBuyOrder && offchainOrder.targetPrice <= fillPriceX18);

            // we don't revert here because we want to continue filling other orders.
            if (!isFillPriceValid) {
                continue;
            }

            offchainOrder.filled = true;
        }
    }
}

contract Exploit {
    SettlementBranch public branch; // CREATE nonce 1
    uint256 public constant ACCOUNT_ID = 1;

    constructor() {
        branch = new SettlementBranch(); // nonce 1
    }

    /// @notice A trader opens a long position, places a take-profit SELL
    ///         order at a sensible target above the entry price, and the
    ///         market obligingly rises past that target — a fill the
    ///         trader clearly wanted. The broken isFillPriceValid rejects
    ///         it anyway, and the trader's paper profit evaporates when
    ///         the market later reverses.
    function run() external {
        uint256 entryPrice = 100e18;
        int256 size = 1000e18; // long 1000 units

        branch.openPosition(ACCOUNT_ID, size, entryPrice);

        // Take-profit: sell (close) order, target price 130 (30% above entry).
        int128 sellSizeDelta = -1; // sign only — magnitude irrelevant to the bug
        uint256 targetPrice = 130e18;
        uint256 orderId = branch.createOffchainOrder(sellSizeDelta, targetPrice);

        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;

        // Market rises to 140 — well past the trader's 130 take-profit target.
        // Correct semantics: a sell take-profit should fill once fill >= target
        // (140 >= 130) -> should fill.
        branch.fillOffchainOrders(ids, 140e18);

        (, uint256 storedTarget, bool filledAtPeak) = branch.orders(orderId);
        require(storedTarget == targetPrice, "sanity: target mismatch");

        // HARM STEP 1: despite the fill price clearing the trader's own
        // take-profit target, the order was silently skipped.
        require(!filledAtPeak, "expected take-profit to be wrongly skipped (bug)");

        int256 pnlAtPeak = branch.unrealizedPnl(ACCOUNT_ID, 140e18);
        require(pnlAtPeak == 40_000e18, "unexpected pnl at peak"); // the profit that should have been locked in

        // The position size is unchanged (the sell never executed) — the
        // trader is still fully exposed to the market.
        (int256 sizeAfter,) = branch.accounts(ACCOUNT_ID);
        require(sizeAfter == size, "position should be unchanged (order never filled)");

        // Market reverses to 90 (below entry) — with the take-profit never
        // having fired, the trader's paper profit is gone and they are now
        // underwater instead.
        int256 pnlAfterCrash = branch.unrealizedPnl(ACCOUNT_ID, 90e18);
        require(pnlAfterCrash == -10_000e18, "unexpected pnl after crash");

        // HARM STEP 2: a 50,000-unit swing (from +40,000 profit that should
        // have been locked in, to a -10,000 realized-on-paper loss) directly
        // caused by the take-profit order that could never execute.
        int256 swing = pnlAtPeak - pnlAfterCrash;
        require(swing == 50_000e18, "unexpected pnl swing caused by stuck take-profit order");
    }
}
