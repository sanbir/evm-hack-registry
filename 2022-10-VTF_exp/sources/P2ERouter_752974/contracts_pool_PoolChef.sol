// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '../token/TokenLocker.sol';
import '../core/SafeOwnable.sol';
import "../token/P2EToken.sol";
import "./P2EBar.sol";

contract PoolChef is SafeOwnable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct UserInfo {
        uint256 amount;     
        uint256 rewardDebt; 
    }

    struct PoolInfo {
        IERC20 token;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. CAKEs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that CAKEs distribution occurs.
        uint256 accP2EPerShare; // Accumulated CAKEs per share, times 1e12. See below.
    }

    P2EToken public rewardToken;
    P2EBar public bar;
    uint256 public rewardPerBlock;
    uint256 public BONUS_MULTIPLIER = 1;

    PoolInfo[] public poolInfo;
    mapping(address => uint256) public pidOfToken;
    mapping(address => bool) public existToken;
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    uint256 public totalAllocPoint = 0;
    uint256 public startBlock;
    TokenLocker public tokenLocker;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event NewRewardPerBlock(uint oldReward, uint newReward);
    event NewMultiplier(uint oldMultiplier, uint newMultiplier);
    event NewTokenLocker(TokenLocker oldTokenLocker, TokenLocker newTokenLocker);

    modifier validatePoolByPid(uint256 _pid) {
        require (_pid < poolInfo.length, "Pool does not exist");
        _;
    }

    function setTokenLocker(TokenLocker _tokenLocker) external onlyOwner {
        //require(_tokenLocker != address(0), "token locker address is zero"); 
        emit NewTokenLocker(tokenLocker, _tokenLocker);
        tokenLocker = _tokenLocker;
    }

    constructor(
        P2EToken _rewardToken,
        P2EBar _bar,
        uint256 _rewardPerBlock,
        uint256 _startBlock
    ) SafeOwnable(msg.sender) {
        rewardToken = _rewardToken;
        bar = _bar;
        rewardPerBlock = _rewardPerBlock;
        startBlock = _startBlock;
    }

    function updateMultiplier(uint256 multiplierNumber, bool withUpdate) external onlyOwner {
        if (withUpdate) {
            massUpdatePools();
        }
        emit NewMultiplier(BONUS_MULTIPLIER, multiplierNumber);
        BONUS_MULTIPLIER = multiplierNumber;
    }

    function updateRewardPerBlock(uint256 _rewardPerBlock, bool _withUpdate) external onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        emit NewRewardPerBlock(rewardPerBlock, _rewardPerBlock);
        rewardPerBlock = _rewardPerBlock;
    }


    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function add(uint256 _allocPoint, IERC20 _token, bool _withUpdate) external onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        require(address(_token) != address(bar), "can not add bar");
        require(!existToken[address(_token)], "token not exist");
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        pidOfToken[address(_token)] = poolInfo.length;
        poolInfo.push(PoolInfo({
            token: _token,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accP2EPerShare: 0
        }));
        existToken[address(_token)] = true;
    }

    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) external validatePoolByPid(_pid) onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
        }
    }

    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    function pendingP2E(uint256 _pid, address _user) external validatePoolByPid(_pid) view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accP2EPerShare = pool.accP2EPerShare;
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && tokenSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 reward = multiplier.mul(rewardPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accP2EPerShare = accP2EPerShare.add(reward.mul(1e12).div(tokenSupply));
        }
        return user.amount.mul(accP2EPerShare).div(1e12).sub(user.rewardDebt);
    }

    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    function updatePool(uint256 _pid) public validatePoolByPid(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (tokenSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 reward = multiplier.mul(rewardPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        reward = rewardToken.mint(address(bar), reward);
        pool.accP2EPerShare = pool.accP2EPerShare.add(reward.mul(1e12).div(tokenSupply));
        pool.lastRewardBlock = block.number;
    }

    function safeP2ETransfer(address _to, uint256 _amount) internal {
        bar.safeP2ETransfer(_to, _amount);
    }

    function deposit(uint256 _pid, uint256 _amount) external validatePoolByPid(_pid) nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accP2EPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                if (address(tokenLocker) == address(0)) {
                    safeP2ETransfer(msg.sender, pending);
                } else {
                    safeP2ETransfer(address(this), pending);
                    rewardToken.approve(address(tokenLocker), pending);
                    tokenLocker.addReceiver(msg.sender, pending);
                }
            }
        }
        if (_amount > 0) {
            uint balanceBefore = pool.token.balanceOf(address(this));
            pool.token.safeTransferFrom(address(msg.sender), address(this), _amount);
            uint balanceAfter = pool.token.balanceOf(address(this));
            _amount = balanceAfter.sub(balanceBefore);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accP2EPerShare).div(1e12);
        if (pool.token == rewardToken) {
            bar.mint(msg.sender, _amount);
        }
        emit Deposit(msg.sender, _pid, _amount);
    }

    function withdraw(uint256 _pid, uint256 _amount) external validatePoolByPid(_pid) nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accP2EPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            if (address(tokenLocker) == address(0)) {
                safeP2ETransfer(msg.sender, pending);
            } else {
                safeP2ETransfer(address(this), pending);
                rewardToken.approve(address(tokenLocker), pending);
                tokenLocker.addReceiver(msg.sender, pending);
            }
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.token.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accP2EPerShare).div(1e12);
        if (pool.token == rewardToken) {
            bar.burn(msg.sender, _amount);
        }
        emit Withdraw(msg.sender, _pid, _amount);
    }

    function emergencyWithdraw(uint256 _pid) external validatePoolByPid(_pid) nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.token.safeTransfer(address(msg.sender), amount);
        if (pool.token == rewardToken) {
            bar.burn(msg.sender, amount);
        }
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }
}
