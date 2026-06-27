// SPDX-License-Identifier: None
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "./interface/IBurnableERC20.sol";

contract TlnSwap is Context {
    using SafeERC20 for IBurnableERC20;
    using Counters for Counters.Counter;
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;
    Counters.Counter internal _loanId;
    IUniswapV2Pair internal _vowUsdtPair;

    uint256 public constant BURN_PERCENTAGE = 70;
    uint256 public constant REWARD_PERCENTAGE = 20;
    uint256 public constant EXCHANGE_PERCENTAGE = 10;
    uint256 private constant RATE_MULTIPLIER = 10000;
    uint256 private constant VUSD_BURN_PERCENTAGE = 16;

    struct Loan {
        address borrower;
        uint256 borrowedOn;
        uint256 vusd;
        uint256 vow;
        bool active;
    }

    struct Lending {
        uint256 vusd;
        uint256 tln;
        uint256 vusd_paid_back_deposit_pool;
        uint256 vusd_paid_back_repayment_pool;
    }

    IBurnableERC20 private _tlnToken;
    IBurnableERC20 private _vowToken;
    IBurnableERC20 private _vusdToken;
    
    address private _exchange;
    uint256 private _depositPool;
    uint256 private _repaymentPool;
    uint256 private _totalBorrowed;

    mapping(uint256 => Loan) private _loans;
    mapping(address => Lending) private _lendings;
    mapping(address => DoubleEndedQueue.Bytes32Deque) private _userLoans;

    event Lock(address indexed src, uint256 id, uint256 amount, uint256 vow);
    event Release(address indexed src, uint256 id, uint256 amount, uint256 vow);
    event AdvanceVow(address indexed src, uint256 id, uint256 vow);
    event Deposit(address indexed src, uint256 amount);
    event Reward(address indexed src, uint256 amount);
    event Withdraw(address indexed src, uint256 amount);

    constructor(
        IBurnableERC20 tlnToken_,
        IBurnableERC20 vowToken_,
        IBurnableERC20 vusdToken_,
        address vowUsdtPair_,
        address exchange_
    ) {
        _tlnToken = tlnToken_;
        _vowToken = vowToken_;
        _vusdToken = vusdToken_;
        _vowUsdtPair = IUniswapV2Pair(vowUsdtPair_);
        _exchange = exchange_;
    }

    function lock(uint256 amount) external {
        require(amount > 0, "TlnSwap: Zero lock amount");

        _tlnToken.safeTransferFrom(_msgSender(), address(this), amount);
        _tlnToken.burn((amount * BURN_PERCENTAGE) / 100);
        _tlnToken.safeTransfer(_exchange, (amount * EXCHANGE_PERCENTAGE) / 100);

        uint256 lockedVow = _vowToLock(amount);
        _vowToken.safeTransferFrom(_msgSender(), address(this), lockedVow);
        _loanId.increment();
        _loans[_loanId.current()] = Loan(
            _msgSender(),
            block.timestamp,
            amount,
            lockedVow,
            true
        );

        _userLoans[_msgSender()].pushBack(bytes32(_loanId.current()));
        uint256 borrowAmount = (amount * 1000) / 984;
        _vusdToken.safeTransfer(_msgSender(), borrowAmount);
        _depositPool -= borrowAmount;
        _totalBorrowed += borrowAmount;
        emit Lock(_msgSender(), _loanId.current(), amount, lockedVow);
    }

    function release() external {
        _release();
    }

    function multiRelease(uint256 releaseCount) external {
        require(releaseCount > 0, "TlnSwap: Zero release count");
        require(
            _userLoanCount(_msgSender()) >= releaseCount,
            "TlnSwap: Invalid release count"
        );
        for (uint256 i = 0; i < releaseCount; i++) {
            _release();
        }
    }

    function advanceVow(uint256 id, uint256 vow) external {
        require(vow > 0, "TlnSwap: Zero advance amount");
        require(_loans[id].active, "TlnSwap: Inactive loan");
        _vowToken.safeTransferFrom(_msgSender(), address(this), vow);
        _loans[id].vow += vow;
        emit AdvanceVow(_msgSender(), id, vow);
    }

    function claimReward() external {
        uint256 rewardAmount = _claimbleReward(_msgSender());
        require(rewardAmount > 0, "TlnSwap: Zero reward amount");
        _tlnToken.safeTransfer(_msgSender(), rewardAmount);
        _lendings[_msgSender()].tln += rewardAmount;
        emit Reward(_msgSender(), rewardAmount);
    }

    function depositVusd(uint256 amount) external {
        require(amount > 0, "TlnSwap: Zero deposit amount");
        _vusdToken.safeTransferFrom(_msgSender(), address(this), amount);
        amount = _vusdAmountAfterBurn(amount);
        _lendings[_msgSender()].vusd += amount;
        _depositPool += amount;
        emit Deposit(_msgSender(), amount);
    }

    function withdrawVusd() external {
        (
            uint256 depositPoolAmount,
            uint256 repaymentPoolAmount
        ) = _withdrawableVusd(_msgSender());

        uint256 vUSD = depositPoolAmount + repaymentPoolAmount;
        require(vUSD > 0, "TlnSwap: Invalid Claimable vUSD");

        if (depositPoolAmount > 0) {
            _depositPool -= depositPoolAmount;
            _lendings[_msgSender()].vusd_paid_back_deposit_pool += depositPoolAmount;
        }

        if (repaymentPoolAmount > 0) {
            _repaymentPool -= repaymentPoolAmount;
            _lendings[_msgSender()].vusd_paid_back_repayment_pool += repaymentPoolAmount;
        }

        _vusdToken.safeTransfer(_msgSender(), vUSD);

        emit Withdraw(_msgSender(), vUSD);
    }

    function _vusdAmountAfterBurn(uint256 amount) internal pure returns (uint256) {
        uint256 burnAmount = (amount * VUSD_BURN_PERCENTAGE) / 1000;
        return amount - burnAmount;
    }

    function version() internal pure returns (uint256) {
        return 1;
    }

    function withdrawableVusd(
        address account
    ) 
        public 
        view 
        returns (
            uint256 depositPoolAmount,
            uint256 repaymentPoolAmount
        )
    {
        return _withdrawableVusd(account);
    }

    function treasuryInfo()
        public
        view
        returns (
            address tlnToken,
            address vowToken,
            address vusdToken,
            address vowUsdtPair,
            address exchange
        )
    {
        return (
            address(_tlnToken),
            address(_vowToken),
            address(_vusdToken),
            address(_vowUsdtPair),
            _exchange
        );
    }

    function poolInfo()
        public
        view
        returns (
            uint256 depositPool_,
            uint256 repaymentPool_,
            uint256 totalBorrowed_
        )
    {
        return (_depositPool, _repaymentPool, _totalBorrowed);
    }

    function loanCount() public view returns (uint256 count) {
        return _loanId.current();
    }

    function loanOf(
        uint256 id
    )
        public
        view
        returns (
            address borrower,
            uint256 borrowedOn,
            uint256 vusd,
            uint256 vow,
            bool active
        )
    {
        return _loanOf(id);
    }

    function _loanOf(
        uint256 id
    ) public view returns (address, uint256, uint256, uint256, bool) {
        return (
            _loans[id].borrower,
            _loans[id].borrowedOn,
            _loans[id].vusd,
            _loans[id].vow,
            _loans[id].active
        );
    }

    function userLoanOf(address account) public view returns (uint256 id) {
        return _userLoanOf(account);
    }

    function userLoanIdByPosition(
        address account,
        uint256 position
    ) public view returns (uint256 id) {
        return _userLoanIdByPosition(account, position);
    }

    function userLoanByPosition(
        address account,
        uint256 position
    )
        public
        view
        returns (
            address borrower,
            uint256 borrowedOn,
            uint256 vusd,
            uint256 vow,
            bool active
        )
    {
        uint256 id = _userLoanIdByPosition(account, position);
        return _loanOf(id);
    }

    function userLoanCount(
        address account
    ) public view returns (uint256 count) {
        return _userLoanCount(account);
    }

    function getVowRate() public view returns (uint vowRate) {
        (uint112 reserveIn, uint112 reserveOut, ) = _vowUsdtPair
            .getReserves();
        require(reserveIn > 0 && reserveOut > 0, 'TlnSwap: INSUFFICIENT_LIQUIDITY');
        vowRate = reserveIn * RATE_MULTIPLIER / reserveOut;
    }

    function vowToLock(uint256 amount) public view returns (uint256 vowAmount) {
        return _vowToLock(amount);
    }

    function lendingOf(address account) public view returns (
        uint256 vusd, 
        uint256 tln, 
        uint256 vusd_paid_back_deposit_pool,
        uint256 vusd_paid_back_repayment_pool
    ) {
        return (
            _lendings[account].vusd,
            _lendings[account].tln,
            _lendings[account].vusd_paid_back_deposit_pool,
            _lendings[account].vusd_paid_back_repayment_pool
        );
    }

    function claimbleReward(
        address account
    ) public view returns (uint256 rewardAmount) {
        return _claimbleReward(account);
    }

    function _release() internal {
        uint256 id = _userLoanOf(_msgSender());
        require(_loans[id].active, "TlnSwap: Loan inactive");
        require(
            _loans[id].borrower == _msgSender(),
            "TlnSwap: Invalid borrower"
        );

        _vusdToken.safeTransferFrom(
            _msgSender(),
            address(this),
            _loans[id].vusd
        );

        _vowToken.safeTransfer(_msgSender(), _loans[id].vow);
        _loans[id].active = false;
        _userLoans[_msgSender()].popFront();
        _repaymentPool += _vusdAmountAfterBurn(_loans[id].vusd);

        emit Release(_msgSender(), id, _loans[id].vusd, _loans[id].vow);
    }

    function remainingLending(
        address account
    ) public view returns (uint256) {
        return _remainingLending(account);
    }

    function _remainingLending(
        address account
    ) internal view returns (uint256) {
        return _lendings[account].vusd - (_lendings[account].vusd_paid_back_deposit_pool + _lendings[account].vusd_paid_back_repayment_pool);
    }

    function _claimbleReward(
        address account
    ) internal view returns (uint256 rewardAmount) {
        rewardAmount = (_remainingLending(account) * REWARD_PERCENTAGE) / 100;
        rewardAmount = rewardAmount > _lendings[account].tln ? rewardAmount - _lendings[account].tln : 0;

        uint256 maxRewardAmount = _tlnToken.balanceOf(address(this));
        rewardAmount = rewardAmount > maxRewardAmount
            ? maxRewardAmount
            : rewardAmount;
    }

    function _userLoanIdByPosition(
        address account,
        uint256 position
    ) internal view returns (uint256 id) {
        if (_userLoans[account].empty()) {
            return 0;
        }
        return uint256(_userLoans[account].at(position));
    }

    function _vowToLock(
        uint256 amountIn
    ) internal view returns (uint256 vowAmount) {

        (uint112 reserveIn, uint112 reserveOut, ) = _vowUsdtPair
            .getReserves();

        vowAmount = _getAmountOut(amountIn / 5, reserveIn, reserveOut);
    }

    function _userLoanCount(address account) internal view returns (uint256) {
        if (_userLoans[account].empty()) {
            return 0;
        }
        return _userLoans[account].length();
    }

    function _userLoanOf(address account) internal view returns (uint256) {
        if (_userLoans[account].empty()) {
            return 0;
        }
        return uint256(_userLoans[account].front());
    }

    function _withdrawableVusd(
        address account
    )
        internal
        view
        returns (
            uint256 depositPoolAmount,
            uint256 repaymentPoolAmount
        )
    {

        repaymentPoolAmount = _lendings[account].tln * 5;

        repaymentPoolAmount -= _lendings[account].vusd_paid_back_repayment_pool;

        depositPoolAmount = _lendings[account].vusd - _lendings[account].vusd_paid_back_deposit_pool;

        depositPoolAmount = depositPoolAmount - repaymentPoolAmount;

        depositPoolAmount = depositPoolAmount > _depositPool ? _depositPool: depositPoolAmount;

        repaymentPoolAmount = repaymentPoolAmount > _repaymentPool ? _repaymentPool: repaymentPoolAmount;
    }

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) 
        internal 
        pure 
        returns (uint amountOut) 
    {
        require(amountIn > 0, 'TlnSwap: INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'TlnSwap: INSUFFICIENT_LIQUIDITY');
        uint256 rate = reserveIn * RATE_MULTIPLIER / reserveOut;
        amountOut = amountIn * RATE_MULTIPLIER / rate;
    }
}
