// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    DittoETH — Users can lose collateral when exiting a short (Codehawks
    2023-09, reporter hash, finding #27476)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable ExitShortFacet::exitShort "Full Exit" branch is inlined
    VERBATIM (it disburses a STALE, pre-match collateral snapshot). No
    fork, no RPC, no cheatcodes.

    ROOT CAUSE: exitShort places a bid to buy back a ShortRecord's debt. If
    that bid happens to match the SAME user's own still-resting short order
    (a self-match — no exclusion needed, the orderbook doesn't care who the
    counterparty is), the match adds the newly-filled debt AND collateral
    into the SAME ShortRecord via fillShortRecord. But exitShort captured
    `e.ercDebt`/`e.collateral` as SNAPSHOTS taken BEFORE the match. If the
    snapshot debt equals the filled amount, exitShort treats it as a "Full
    Exit", disburses the STALE (pre-match) collateral snapshot, and
    DELETES the ShortRecord entirely — discarding the collateral the
    self-match JUST added, which is now unrecoverable by anyone.

    Numbers kept exact & simple (abstract units, price = 1):
      - Sender deposits 300 and opens a 100-unit short; only 50 units get
        filled immediately (ShortRecord: debt=50, collateral=150), the
        other 50 rests on the book as an open short order.
      - Sender calls exitShort to buy back the 50 debt. The exit bid
        self-matches the sender's OWN resting 50-unit order.
      - The self-match adds 50 more debt + 150 more collateral into the
        SAME ShortRecord (debt -> 100, collateral -> 300).
      - exitShort's stale snapshot (debt=50) equals the filled amount (50),
        so it disburses the STALE collateral (150, not the updated 300) and
        deletes the ShortRecord.
      - Sender recovers only 150 of the 300 they were actually owed — the
        other 150 (the self-match's own contribution) is permanently lost
        (300 deposited total, 150 stuck in the contract forever).
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20 used as the underlying escrowed asset.
contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "ERC20: insufficient balance");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            require(allowance[from][msg.sender] >= amt, "ERC20: insufficient allowance");
            allowance[from][msg.sender] -= amt;
        }
        require(balanceOf[from] >= amt, "ERC20: insufficient balance");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduction of DittoETH's ExitShortFacet::exitShort +
///         BidOrdersFacet::matchlowestSell + LibShortRecord for a single
///         market. Multi-asset accounting, real oracle-driven collateral
///         ratios, and partial-buyback bookkeeping are out of scope and
///         omitted; the exact stale-snapshot-on-self-match mechanism this
///         finding blames is preserved.
contract ShortExitManager {
    struct ShortRecord {
        address owner;
        uint256 ercDebt;
        uint256 collateral;
        bool exists;
    }

    struct Order {
        address addr;
        uint256 ercAmount; // remaining unfilled amount
        uint256 price;
        uint256 shortRecordId; // links this resting order to a ShortRecord (0 = none)
        bool active;
    }

    // Same multiplier for both the upfront full-order margin reservation AND
    // each fill's ShortRecord collateral contribution, so a position that is
    // 100% filled and then fully closed reconciles to exactly its original
    // margin (no unrelated modeling gap to confuse the finding's own loss).
    uint256 public constant COLLATERAL_MULTIPLIER = 3;

    MockToken public token;
    mapping(address => uint256) public ethEscrowed;
    mapping(uint256 => ShortRecord) public shortRecords;
    mapping(uint256 => Order) public shorts;
    uint256 public nextShortId = 1;
    uint256 public nextOrderId = 1;

    constructor(MockToken _token) {
        token = _token;
    }

    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        ethEscrowed[msg.sender] += amount;
    }

    /// @notice Reduction of createLimitShort + the immediate-partial-fill
    ///         step. `filledAmount` is matched immediately (modeling a
    ///         resting bid already on the book); the remainder rests as an
    ///         open short order still owned by the caller.
    function createLimitShort(uint256 fullAmount, uint256 filledAmount, uint256 price)
        external
        returns (uint256 shortId, uint256 restingOrderId)
    {
        require(filledAmount <= fullAmount, "filled > full");
        uint256 marginNeeded = fullAmount * price * COLLATERAL_MULTIPLIER;
        require(ethEscrowed[msg.sender] >= marginNeeded, "insufficient margin");
        ethEscrowed[msg.sender] -= marginNeeded; // full margin reserved upfront for the WHOLE order

        shortId = nextShortId++;
        uint256 filledCollateral = filledAmount * price * COLLATERAL_MULTIPLIER;
        shortRecords[shortId] = ShortRecord(msg.sender, filledAmount, filledCollateral, true);

        uint256 remaining = fullAmount - filledAmount;
        if (remaining > 0) {
            restingOrderId = nextOrderId++;
            shorts[restingOrderId] = Order(msg.sender, remaining, price, shortId, true);
        }
    }

    /// @notice Reduction of ExitShortFacet::exitShort. Snapshots the
    ///         ShortRecord's debt/collateral BEFORE matching the exit bid,
    ///         then compares the snapshot (not the post-match state) to
    ///         decide whether this is a "Full Exit".
    function exitShort(uint256 shortRecordId, uint256 buyBackAmount, uint256 price, uint256 hintOrderId) external {
        ShortRecord storage short = shortRecords[shortRecordId];
        require(short.owner == msg.sender, "not owner");
        require(short.exists, "no such short");

        uint256 snapshotDebt = short.ercDebt; // taken BEFORE the match
        uint256 snapshotCollateral = short.collateral; // taken BEFORE the match

        uint256 ercFilled = _matchBid(hintOrderId, buyBackAmount, price);

        // @audit if the debt is fully filled, the short record is deleted
        if (snapshotDebt == ercFilled) {
            // Full Exit
            ethEscrowed[msg.sender] += snapshotCollateral; // @> VULN: disburses the STALE pre-match collateral snapshot, not short.collateral's post-match (possibly self-match-inflated) value
            delete shortRecords[shortRecordId]; // deletes the ShortRecord entirely - any collateral a self-match just added is now unrecoverable
        } else {
            short.ercDebt -= ercFilled;
        }
    }

    /// @dev Reduction of BidOrdersFacet::matchlowestSell. If the matched
    ///      resting order is linked to a ShortRecord, the fill's debt and
    ///      collateral are added into that SAME ShortRecord — with no
    ///      exclusion for the case where the ShortRecord being filled is
    ///      the very one the caller is simultaneously exiting.
    function _matchBid(uint256 orderId, uint256 buyBackAmount, uint256 price) private returns (uint256 filled) {
        Order storage o = shorts[orderId];
        require(o.active, "order not active");
        require(o.price == price, "price mismatch");
        filled = buyBackAmount <= o.ercAmount ? buyBackAmount : o.ercAmount;

        if (o.shortRecordId != 0) {
            ShortRecord storage sr = shortRecords[o.shortRecordId];
            sr.ercDebt += filled;
            sr.collateral += filled * price * COLLATERAL_MULTIPLIER;
        }

        o.ercAmount -= filled;
        if (o.ercAmount == 0) o.active = false;
    }

    function withdraw(uint256 amount) external {
        require(ethEscrowed[msg.sender] >= amount, "insufficient escrowed balance");
        ethEscrowed[msg.sender] -= amount;
        token.transfer(msg.sender, amount);
    }
}

/// @notice Thin actor contract so the user has its own address and its own
///         token/escrow balances.
contract Actor {
    MockToken public token;
    ShortExitManager public sm;

    constructor(MockToken _token, ShortExitManager _sm) {
        token = _token;
        sm = _sm;
    }

    function deposit(uint256 amount) external {
        token.mint(address(this), amount);
        token.approve(address(sm), amount);
        sm.deposit(amount);
    }

    function createLimitShort(uint256 fullAmount, uint256 filledAmount, uint256 price)
        external
        returns (uint256 shortId, uint256 restingOrderId)
    {
        (shortId, restingOrderId) = sm.createLimitShort(fullAmount, filledAmount, price);
    }

    function exitShort(uint256 shortRecordId, uint256 buyBackAmount, uint256 price, uint256 hintOrderId) external {
        sm.exitShort(shortRecordId, buyBackAmount, price, hintOrderId);
    }

    function withdraw(uint256 amount) external {
        sm.withdraw(amount);
    }
}

/// @notice Attack orchestrator / deployer. Deploys the whole scene and runs
///         the self-match stale-snapshot loss end-to-end, asserting the
///         finding's HARM with require(). No adversary is required — this
///         is an honest user losing their own funds to a logic bug while
///         exiting normally.
contract Exploit {
    uint256 public constant PRICE = 1;
    uint256 public constant FULL_AMOUNT = 100;
    uint256 public constant FILLED_AMOUNT = 50;
    uint256 public constant DEPOSIT = 300; // == FULL_AMOUNT * PRICE * COLLATERAL_MULTIPLIER

    MockToken public token; // CREATE nonce 1
    ShortExitManager public sm; // CREATE nonce 2 (vulnerable)
    Actor public sender; // CREATE nonce 3 (honest user, victim of their own exit)

    uint256 public shortId;
    uint256 public restingOrderId;
    uint256 public ethEscrowedAfterExit;
    uint256 public correctCollateralWouldHaveBeen;
    uint256 public withdrawnAfterExit;

    constructor() {
        token = new MockToken();
        sm = new ShortExitManager(token);
        sender = new Actor(token, sm);
    }

    function run() external {
        // 1. Sender deposits 500 and opens a 100-unit short; only 50 fills
        //    immediately (ShortRecord: debt=50, collateral=150), the other
        //    50 rests on the book as sender's own open short order.
        sender.deposit(DEPOSIT);
        (shortId, restingOrderId) = sender.createLimitShort(FULL_AMOUNT, FILLED_AMOUNT, PRICE);
        (, uint256 debtBefore, uint256 collateralBefore,) = sm.shortRecords(shortId);
        require(debtBefore == FILLED_AMOUNT, "unexpected initial debt");
        require(collateralBefore == FILLED_AMOUNT * PRICE * sm.COLLATERAL_MULTIPLIER(), "unexpected initial collateral");

        // 2. Sender exits, buying back the 50 debt. The exit bid
        //    self-matches sender's OWN resting 50-unit order.
        sender.exitShort(shortId, FILLED_AMOUNT, PRICE, restingOrderId);

        // ---- HARM: the ShortRecord is gone, but sender only recovered the STALE collateral ----
        ethEscrowedAfterExit = sm.ethEscrowed(address(sender));
        (,,, bool exists) = sm.shortRecords(shortId);
        require(!exists, "shortRecord not deleted");

        // What sender SHOULD have recovered: the FULL post-self-match
        // collateral (both fills), i.e. FULL_AMOUNT * PRICE * COLLATERAL_MULTIPLIER.
        correctCollateralWouldHaveBeen = FULL_AMOUNT * PRICE * sm.COLLATERAL_MULTIPLIER();
        require(ethEscrowedAfterExit < correctCollateralWouldHaveBeen, "sender recovered the correct amount - bug not triggered");
        require(
            correctCollateralWouldHaveBeen - ethEscrowedAfterExit == FILLED_AMOUNT * PRICE * sm.COLLATERAL_MULTIPLIER(),
            "shortfall != the self-match's own collateral contribution"
        );

        // 3. Sender withdraws everything they have left - permanently
        //    short by exactly the self-match's discarded collateral.
        sender.withdraw(ethEscrowedAfterExit);
        withdrawnAfterExit = token.balanceOf(address(sender));
        require(withdrawnAfterExit == ethEscrowedAfterExit, "withdraw mismatch");
    }
}
