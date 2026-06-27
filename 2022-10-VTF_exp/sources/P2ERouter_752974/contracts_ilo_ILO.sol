// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '../token/TokenLocker.sol';
import '../core/SafeOwnable.sol';
import 'hardhat/console.sol';

contract ILO is SafeOwnable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct UserInfo {
        uint256 amount;     
        uint256 lastTime;
    }
    struct PoolInfo {
        IERC20 lpToken;           
        uint256 allocPoint;       
        uint256 totalAmount;
    }

    event NewStartSeconds(uint oldSeconds, uint newSeconds);
    event NewEndSeconds(uint oldSeconds, uint newSeconds);
    event OwnerDeposit(address user, uint256 amount, uint totalAmount);
    event OwnerWithdraw(address user, uint256 amount);
    event NewPool(IERC20 lpToken, uint allocPoint, uint totalAllocPoint);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Claim(address indexed user, uint256 indexed pid, uint256 amount);
    event NewTokenLocker(TokenLocker oldTokenLocker, TokenLocker newTokenLocker);


    PoolInfo[] public poolInfo;
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    uint256 public totalAllocPoint = 0;

    IERC20 immutable public rewardToken;
    uint256 public rewardAmount;
    uint256 public startSeconds;
    uint256 public endSeconds;
    uint256 constant public FINISH_WAIT = 7 days;
    TokenLocker public tokenLocker;

    modifier notBegin() {
        require(block.timestamp < startSeconds, "ILO already begin");
        _;
    }

    modifier alreadyFinish() {
        require(block.timestamp > endSeconds + FINISH_WAIT, "ILO not finish");
        _;
    }

    modifier notProcessing() {
        require(block.timestamp < startSeconds || block.timestamp > endSeconds + FINISH_WAIT, "ILO in processing");
        _;
    }

    function setTokenLocker(TokenLocker _tokenLocker) external onlyOwner {
        //require(_tokenLocker != address(0), "token locker address is zero"); 
        emit NewTokenLocker(tokenLocker, _tokenLocker);
        tokenLocker = _tokenLocker;
    }
    /*
    function setStartSeconds(uint256 _startSeconds) external onlyOwner notProcessing {
        emit NewStartSeconds(startSeconds, _startSeconds);
        startSeconds = _startSeconds;
    }

    function setEndSeconds(uint256 _endSeconds) external onlyOwner notProcessing {
        emit NewEndSeconds(endSeconds, _endSeconds);
        endSeconds = _endSeconds;
    }
    */
    constructor(
        IERC20 _rewardToken,
        uint256 _startSeconds,
        uint256 _endSeconds
    ) SafeOwnable(msg.sender) {
        rewardToken = _rewardToken;
        startSeconds = _startSeconds;
        emit NewStartSeconds(0, _startSeconds);
        endSeconds = _endSeconds;
        emit NewEndSeconds(0, _endSeconds);
    }

    function ownerDeposit(uint amount) external notProcessing {
        rewardAmount = rewardAmount.add(amount);     
        SafeERC20.safeTransferFrom(rewardToken, msg.sender, address(this), amount);
        emit OwnerDeposit(msg.sender, amount, rewardAmount);
    }

    function ownerWithdraw(uint amount) external notProcessing onlyOwner {
        uint balance = rewardToken.balanceOf(address(this));
        if (amount > balance) {
            amount = balance;
        }
        rewardAmount = rewardAmount.sub(amount);     
        SafeERC20.safeTransfer(rewardToken, owner(), amount);
        emit OwnerWithdraw(owner(), amount);
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function add(uint256 _allocPoint, IERC20 _lpToken) external notBegin onlyOwner {
        _lpToken.balanceOf(address(this)); //ensure this is a token
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            totalAmount: 0
        }));
        emit NewPool(_lpToken, _allocPoint, totalAllocPoint);
    }

    function deposit(uint256 _pid, uint256 _amount) external {
        require(_pid < poolInfo.length, "illegal pid");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(block.timestamp >= startSeconds && block.timestamp <= endSeconds, "ILO not in processing");
        require(_amount > 0, "illegal amount");

        user.amount = user.amount.add(_amount);
        user.lastTime = block.timestamp;
        pool.totalAmount = pool.totalAmount.add(_amount);
        pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);

        emit Deposit(msg.sender, _pid, _amount);
    }

    function pending(uint256 _pid, address _user) public view returns (uint256) {
        require(_pid < poolInfo.length, "illegal pid");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 poolBalance = rewardAmount.mul(pool.allocPoint).div(totalAllocPoint);
        if (pool.totalAmount == 0) {
            return 0;
        }
        return poolBalance.mul(user.amount).div(pool.totalAmount);
    }

    function safeRewardTransfer(address _to, uint256 _amount) internal {
        uint256 balance = rewardToken.balanceOf(address(this));
        if (_amount > balance) {
            _amount = balance;
        }
        rewardToken.safeTransfer(_to, _amount);
    }


    function withdraw(uint256 _pid) external {
        require(block.timestamp > endSeconds, "Can not withdraw now");
        require(_pid < poolInfo.length, "illegal pid");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 pendingAmount = pending(_pid, msg.sender);
        if (pendingAmount > 0) {
            if (address(tokenLocker) == address(0)) {
                safeRewardTransfer(msg.sender, pendingAmount);
            } else {
                rewardToken.approve(address(tokenLocker), pendingAmount);
                tokenLocker.addReceiver(msg.sender, pendingAmount);
            }
            emit Claim(msg.sender, _pid, pendingAmount);
        }
        if (user.amount > 0) {
            uint _amount = user.amount;
            user.amount = 0;
            user.lastTime = block.timestamp;
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
            emit Withdraw(msg.sender, _pid, _amount);
        }
    }
}
