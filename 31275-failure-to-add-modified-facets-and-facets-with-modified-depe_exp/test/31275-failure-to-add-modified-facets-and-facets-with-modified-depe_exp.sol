// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma experimental ABIEncoderV2;

import "forge-std/Test.sol";
import {Diamond} from "../src/beanstalk/Diamond.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {SetupFacet} from "../src/poc/SetupFacet.sol";
import {SiloViewFacetV1} from "../src/poc/SiloViewFacetV1.sol";
import {SiloViewFacetV2} from "../src/poc/SiloViewFacetV2.sol";
import {WhitelistFacetV1} from "../src/poc/WhitelistFacetV1.sol";
import {WhitelistFacetV2} from "../src/poc/WhitelistFacetV2.sol";

/**
 * Beanstalk BIP-39 (Seed Gauge) upgrade — diamond-cut omission of a modified facet.
 *
 * The BIP-39 upgrade script (bipSeedGauge in protocol/scripts/bips.js) re-cuts the
 * facets whose libraries changed the stem-tip SCALE convention (WhitelistFacet /
 * SeasonFacet, which write `milestoneStem` UNTRUNCATED via LibTokenSilo.
 * stemTipForTokenUntruncated), but OMITS re-cutting SiloFacet — even though SiloFacet
 * inlines the OLD LibTokenSilo.stemTipForToken (which adds `milestoneStem` un-divided).
 *
 * After the upgrade the diamond routes stem/grown-stalk selectors to the STALE V1
 * SiloFacet, which reads the freshly-rescaled (×1e6) `milestoneStem` on the WRONG
 * scale → grown Stalk for pre-upgrade deposits explodes ~1e6×.
 *
 * Real source (deployed here, unmodified logic):
 *   - Diamond / LibDiamond / DiamondCutFacet / DiamondLoupeFacet / OwnershipFacet
 *   - AppStorage / ReentrancyGuard / LibAppStorage  (real storage layout)
 *   - LibTokenSilo.stemTipForToken (V1 at 76066733) vs stemTipForTokenUntruncated+
 *     stemTipForToken (V2 at dfb418d)   [libraries renamed only, bodies verbatim]
 *   - LibSilo.stalkReward / _balanceOfGrownStalk (verbatim)
 *   - LibWhitelist.updateStalkPerBdvPerSeasonForToken (V1 truncated / V2 untruncated)
 *   - SiloExit.stemTipForToken / balanceOfGrownStalk (verbatim bodies)
 */
contract Test31275 is Test {
    // Opaque token identity (BEAN mainnet address) — treated only as a key.
    address constant BEAN = 0xBEA0000029AD1c77D3d5D23Ba2D8893dB9d1Efab;
    address constant DEPOSITOR = 0xd2905170720000000000000000000000000d0001;

    uint32 constant SEASON_START = 100;
    uint32 constant SEASON_NOW = 200;
    uint32 constant RATE = 2_000_000; // stalkEarnedPerSeason (1e6-scaled)
    uint128 constant BDV = 1_000_000_000; // 1000 BEAN of BDV (bdv is 1e6-scaled)

    function _sel1(bytes4 s) internal pure returns (bytes4[] memory a) {
        a = new bytes4[](1);
        a[0] = s;
    }

    function _sel2(bytes4 s0, bytes4 s1) internal pure returns (bytes4[] memory a) {
        a = new bytes4[](2);
        a[0] = s0;
        a[1] = s1;
    }

    function _cut(
        address facet,
        IDiamondCut.FacetCutAction action,
        bytes4[] memory sels
    ) internal pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({facetAddress: facet, action: action, functionSelectors: sels});
    }

    /// Deploy the real diamond and cut in Setup + V1 Silo view + V1 Whitelist,
    /// establish the pre-upgrade Silo state (whitelist + pre-upgrade deposit).
    function _deployPreUpgrade()
        internal
        returns (address diamond, address siloV1, address whitelistV1)
    {
        diamond = address(new Diamond(address(this)));

        SetupFacet setup = new SetupFacet();
        SiloViewFacetV1 sv1 = new SiloViewFacetV1();
        WhitelistFacetV1 w1 = new WhitelistFacetV1();
        siloV1 = address(sv1);
        whitelistV1 = address(w1);

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](3);
        bytes4[] memory setupSel = new bytes4[](6);
        setupSel[0] = SetupFacet.setSeason.selector;
        setupSel[1] = SetupFacet.whitelistToken.selector;
        setupSel[2] = SetupFacet.simulateDeposit.selector;
        setupSel[3] = SetupFacet.milestoneStem.selector;
        setupSel[4] = SetupFacet.milestoneSeason.selector;
        setupSel[5] = SetupFacet.currentSeason.selector;
        cuts[0] = _cut(address(setup), IDiamondCut.FacetCutAction.Add, setupSel);
        cuts[1] = _cut(
            siloV1,
            IDiamondCut.FacetCutAction.Add,
            _sel2(SiloViewFacetV1.stemTipForToken.selector, SiloViewFacetV1.balanceOfGrownStalk.selector)
        );
        cuts[2] = _cut(
            whitelistV1,
            IDiamondCut.FacetCutAction.Add,
            _sel1(WhitelistFacetV1.updateStalkPerBdvPerSeasonForToken.selector)
        );
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");

        // --- Establish pre-upgrade state (whitelist @ season 100, milestoneStem = 0) ---
        SetupFacet(diamond).setSeason(SEASON_START);
        SetupFacet(diamond).whitelistToken(BEAN, RATE, SEASON_START, int96(0));
        // Pre-upgrade deposit+mow leaves lastStem = stemTip@deposit = 0.
        SetupFacet(diamond).simulateDeposit(DEPOSITOR, BEAN, int96(0), BDV);

        // Time passes: advance to season 200 (grown stalk accrues linearly, truncated scale).
        SetupFacet(diamond).setSeason(SEASON_NOW);
    }

    function test_31275_facet_omission_inflates_grown_stalk() public {
        // ================= 1. Pre-upgrade (correct V1 accounting) =================
        (address diamond, , ) = _deployPreUpgrade();

        uint256 grownStalkBefore = SiloViewFacetV1(diamond).balanceOfGrownStalk(DEPOSITOR, BEAN);
        emit log_named_uint("grownStalk BEFORE upgrade (correct)", grownStalkBefore);
        // stemTip@200 (v1) = 0 + (2e6 * 100)/1e6 = 200 ; grownStalk = 200 * 1e9 = 2e11
        assertEq(grownStalkBefore, 2e11, "pre-upgrade grown stalk baseline");

        // ================= 2. BIP-39 BUGGY upgrade: re-cut WhitelistFacet -> V2,
        //                     but OMIT re-cutting SiloFacet (stays V1). =============
        WhitelistFacetV2 w2 = new WhitelistFacetV2();
        IDiamondCut.FacetCut[] memory upgrade = new IDiamondCut.FacetCut[](1);
        upgrade[0] = _cut(
            address(w2),
            IDiamondCut.FacetCutAction.Replace,
            _sel1(WhitelistFacetV2.updateStalkPerBdvPerSeasonForToken.selector)
        );
        IDiamondCut(diamond).diamondCut(upgrade, address(0), "");

        // Post-upgrade season/gauge step writes milestoneStem via the NEW V2 code
        // (UNTRUNCATED). This is exactly what sunrise/LibGauge does after the upgrade.
        WhitelistFacetV2(diamond).updateStalkPerBdvPerSeasonForToken(BEAN, RATE);

        // milestoneStem is now stored on the new (untruncated) scale: 2e6 * 100 = 2e8.
        int96 storedMilestone = SetupFacet(diamond).milestoneStem(BEAN);
        emit log_named_int("milestoneStem after V2 write (untruncated)", storedMilestone);
        assertEq(storedMilestone, int96(200_000_000), "milestoneStem rescaled untruncated");

        // ================= 3. HARM: stale V1 SiloFacet misreads the rescaled slot =====
        uint256 grownStalkAfterBuggy = SiloViewFacetV1(diamond).balanceOfGrownStalk(DEPOSITOR, BEAN);
        emit log_named_uint("grownStalk AFTER buggy upgrade (stale SiloFacet)", grownStalkAfterBuggy);
        // v1 stemTip@200 = milestoneStem(2e8) + (2e6*0)/1e6 = 2e8 ; grownStalk = 2e8 * 1e9 = 2e17
        assertEq(grownStalkAfterBuggy, 2e17, "buggy grown stalk value");

        // Backward-compatibility invariant (grown stalk of an existing deposit must not
        // change because of the upgrade) is BROKEN by exactly 1e6x.
        assertEq(
            grownStalkAfterBuggy,
            grownStalkBefore * 1_000_000,
            "over-issuance factor is exactly 1e6"
        );
        assertGt(grownStalkAfterBuggy, grownStalkBefore, "grown stalk inflated");

        // ================= 4. CONTROL: correct upgrade that ALSO re-cuts SiloFacet ====
        (address diamond2, , ) = _deployPreUpgrade();

        WhitelistFacetV2 w2b = new WhitelistFacetV2();
        SiloViewFacetV2 sv2 = new SiloViewFacetV2();
        IDiamondCut.FacetCut[] memory upgrade2 = new IDiamondCut.FacetCut[](2);
        upgrade2[0] = _cut(
            address(w2b),
            IDiamondCut.FacetCutAction.Replace,
            _sel1(WhitelistFacetV2.updateStalkPerBdvPerSeasonForToken.selector)
        );
        upgrade2[1] = _cut(
            address(sv2),
            IDiamondCut.FacetCutAction.Replace,
            _sel2(SiloViewFacetV2.stemTipForToken.selector, SiloViewFacetV2.balanceOfGrownStalk.selector)
        );
        IDiamondCut(diamond2).diamondCut(upgrade2, address(0), "");
        WhitelistFacetV2(diamond2).updateStalkPerBdvPerSeasonForToken(BEAN, RATE);

        uint256 grownStalkAfterCorrect = SiloViewFacetV2(diamond2).balanceOfGrownStalk(DEPOSITOR, BEAN);
        emit log_named_uint("grownStalk AFTER correct upgrade (SiloFacet re-cut)", grownStalkAfterCorrect);
        // v2 stemTip@200 = (2e8)/1e6 = 200 ; grownStalk = 200 * 1e9 = 2e11 == baseline.
        assertEq(grownStalkAfterCorrect, grownStalkBefore, "correct upgrade is backward-compatible");
        assertEq(grownStalkAfterCorrect, 2e11, "correct grown stalk value");

        // The omission is the sole cause of the divergence.
        assertTrue(
            grownStalkAfterBuggy != grownStalkAfterCorrect,
            "facet omission causes the over-issuance"
        );

        emit log_named_uint(
            "EXCESS Stalk over-issued (units, 1e10=1 Stalk)",
            grownStalkAfterBuggy - grownStalkAfterCorrect
        );
    }
}
