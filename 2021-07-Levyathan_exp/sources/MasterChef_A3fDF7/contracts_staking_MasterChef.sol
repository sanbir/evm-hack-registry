// SPDX-License-Identifier: UNLICENSE
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import '@openzeppelin/contracts/access/Ownable.sol';
// import "hardhat/console.sol";

import "../tokens/LEVToken.sol";
import "./SushiBar.sol";

// Forked from Pancakeswap. Expect names based on Sushiswap and Pancakeswap code

// MasterChef is the master of Cake. He can make Cake and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once CAKE is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable {

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of CAKEs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accCakePerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accCakePerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. CAKEs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that CAKEs distribution occurs.
        uint256 accCakePerShare; // Accumulated CAKEs per share, times 1e12. See below.
    }

    // The CAKE TOKEN!
    LEVToken public lev;
    // BUSD token
    IERC20 public busd;
    // pool for LEV rewards
    RewardBar immutable public syrup;
    // Dev address.
    address public immutable devaddr;
    // CAKE tokens created per block.
    uint256 public cakePerBlock;
    // Bonus muliplier for early cake makers.
    uint256 public bonusMultiplier = 1;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Mapping of LP tokens addresses to pools
    mapping (address => uint256) public poolFromLpToken;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when CAKE mining starts.
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event UpdateMultiplier(uint256 multiplierNumber);

    constructor(
        LEVToken _lev,
        IERC20 _busd,
        RewardBar _syrup,
        address _devaddr,
        uint256 _cakePerBlock,
        uint256 _startBlock
    ) {
        lev = _lev;
        busd = _busd;
        syrup = _syrup;
        devaddr = _devaddr;
        cakePerBlock = _cakePerBlock;
        startBlock = _startBlock;

        // staking pool LEV
        poolInfo.push(PoolInfo({
            lpToken: _lev,
            allocPoint: 1000,
            lastRewardBlock: startBlock,
            accCakePerShare: 0
        }));

        totalAllocPoint = 1000;
    }

    modifier poolExists(uint256 _pid) {
        require(_pid < poolInfo.length, "MasterChef: INVALID_PID");
        _;
    }

    function updateMultiplier(uint256 multiplierNumber) public onlyOwner {
        bonusMultiplier = multiplierNumber;
        emit UpdateMultiplier(multiplierNumber);
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add any deflationary token 
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) public onlyOwner {
        require(poolFromLpToken[address(_lpToken)] == 0 && _lpToken != lev, "MasterChef: POOL_ALREADY_EXISTS");

        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint + _allocPoint;
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accCakePerShare: 0
        }));
        poolFromLpToken[address(_lpToken)] = poolInfo.length - 1;
        updateStakingPool();
    }

    // Update the given pool's CAKE allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner poolExists(_pid) {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint - prevAllocPoint + _allocPoint;
            updateStakingPool();
        }
    }

    function updateStakingPool() internal {
        uint256 length = poolInfo.length;
        uint256 points = 0;
        for (uint256 pid = 1; pid < length; ++pid) {
            points = points + poolInfo[pid].allocPoint;
        }
        if (points != 0) {
            points = points / 3;
            totalAllocPoint = totalAllocPoint - poolInfo[0].allocPoint + points;
            poolInfo[0].allocPoint = points;
        }
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        return (_to - _from) * bonusMultiplier;
    }

    // pending total lev reward to be minted for a pool
    function pendingTotalCakeReward(uint256 _pid) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number > pool.lastRewardBlock) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            // reward is 80% of cake per block
            return multiplier * (cakePerBlock * 8 / 10) * pool.allocPoint / totalAllocPoint;
        }
        return 0;
    }

    // View function to see pending CAKEs on frontend.
    function pendingCake(uint256 _pid, address _user) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accCakePerShare = pool.accCakePerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 cakeReward = pendingTotalCakeReward(_pid);
            accCakePerShare = accCakePerShare + (cakeReward * 1e12 / lpSupply);
        }
        return user.amount * accCakePerShare / 1e12 - user.rewardDebt;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }


    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) poolExists(_pid) public {

        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 cakeToMint = multiplier * cakePerBlock * pool.allocPoint / totalAllocPoint;
        uint256 cakeReward = cakeToMint * 8 / 10;
        // send 80% to stakers
        lev.mint(address(syrup), cakeReward);
        // send 20% to dev team sharing
        lev.mint(address(devaddr), cakeToMint / 5);
        pool.accCakePerShare = pool.accCakePerShare + (cakeReward * 1e12 / lpSupply);
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for CAKE allocation.
    function deposit(uint256 _pid, uint256 _amount) poolExists(_pid) public {

        require (_pid != 0, 'deposit CAKE by staking');

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            withdrawPendingRewards(_pid);
        }
        if (_amount > 0) {
            pool.lpToken.transferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount + _amount;
        }
        user.rewardDebt = user.amount * pool.accCakePerShare / 1e12;
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) poolExists(_pid) public {

        require (_pid != 0, 'withdraw CAKE by unstaking');
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);
        withdrawPendingRewards(_pid);
        if(_amount > 0) {
            user.amount = user.amount - _amount;
            pool.lpToken.transfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount * pool.accCakePerShare / 1e12;
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Stake CAKE tokens to MasterChef
    function enterStaking(uint256 _amount) public {

        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        updatePool(0);
        if (user.amount > 0) {
            withdrawPendingRewards(0);
        }
        if(_amount > 0) {
            pool.lpToken.transferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount + _amount;
        }
        user.rewardDebt = user.amount * pool.accCakePerShare / 1e12;

        syrup.mint(msg.sender, _amount);
        emit Deposit(msg.sender, 0, _amount);
    }

    // Withdraw CAKE and BUSD tokens from STAKING.
    function leaveStaking(uint256 _amount) public {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(0);
        withdrawPendingRewards(0);
        if(_amount > 0) {
            user.amount = user.amount - _amount;
            pool.lpToken.transfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount * pool.accCakePerShare / 1e12;

        syrup.burn(msg.sender, _amount);
        emit Withdraw(msg.sender, 0, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        // if LEV pool burn syrup tokens
        if (_pid == 0)
            syrup.burn(msg.sender, user.amount);
        user.amount = 0;
        uint256 rewardDebt = user.rewardDebt;
        user.rewardDebt = 0;
        pool.lpToken.transfer(address(msg.sender), rewardDebt);
        emit EmergencyWithdraw(msg.sender, _pid, rewardDebt);
    }

    // Safe cake transfer function, just in case if rounding error causes pool to not have enough CAKEs.
    function safeCakeTransfer(address _to, uint256 _amount) internal {
        syrup.safeCakeTransfer(_to, _amount);
    }

    function withdrawPendingRewards(uint poolId) poolExists(poolId) internal {
        PoolInfo storage pool = poolInfo[poolId];
        UserInfo storage user = userInfo[poolId][msg.sender];
        uint256 pendingLEV = user.amount * pool.accCakePerShare / 1e12 - user.rewardDebt;

        // Only pool 0 (stake LEV) has BUSD rewards
        if (poolId == 0) {
            uint pendingBUSD = getRewardsBUSD();
            syrup.safeTokenTransfer(msg.sender, pendingBUSD, busd);
        }

        if(pendingLEV > 0) {
            safeCakeTransfer(msg.sender, pendingLEV);
        }
    }

    function getRewardsBUSD() public view returns (uint256) {
        PoolInfo storage pool = poolInfo[0];
        uint256 pendingLEV = pendingCake(0, msg.sender);
        uint256 poolBUSDBalance = busd.balanceOf(address(syrup));
        uint256 pendingLevReward = pendingTotalCakeReward(0);
        uint256 totalPendingLEV = (lev.balanceOf(address(syrup)) + pendingLevReward) * (totalAllocPoint / pool.allocPoint);

        if (totalPendingLEV == 0)
            return 0;
        return pendingLEV * poolBUSDBalance / totalPendingLEV;
    }

    // owner of masterchef can recover ownership in order to change how LEV is minted
    function recoverLevOwnership() external onlyOwner {
        lev.transferOwnership(msg.sender);
    }
}