// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/Context.sol';
import './interfaces/IPoolExtension.sol';

contract sorraStaking is Context, Ownable, ReentrancyGuard {
  using SafeERC20 for IERC20;

  uint256 constant PRECISION_FACTOR = 1e18;
  uint256 constant MULTIPLIER = 10 ** 36;
  address public rewardToken;
  uint256 public totalParticipants;
  uint256 public totalDeposits;

  IPoolExtension public vaultExtension;

  struct VestingTier {
    uint256 period;     // Duration in seconds
    uint256 rewardBps;  // Reward percentage in basis points (1% = 100)
  }
  
  // Define tiers
  VestingTier[3] public vestingTiers;

  struct Deposit {
    uint256 amount;
    uint256 depositTime;
    uint8 tier;
    uint256 rewardBps;
  }

  struct Position {
    Deposit[] deposits;
    uint256 totalAmount;
  }


  mapping(address => Position) public positions;
  mapping(address => uint256) public userRewardsDistributed;


  uint256 public totalRewardsDistributed;

  bool public depositingEnabled = true;

  uint256 public constant MAX_DEPOSITS_PER_USER = 5;

  uint256 public MAX_POOL_CAP = 10000000 * 1e18;

  event Depositx(address indexed user, uint256 amount);
  event Withdraw(address indexed user, uint256 amount);
  event RewardDistributed(
    address indexed user,
    uint256 amount
  );
  event DepositingStatusChanged(bool enabled);
  event RewardBpsUpdated(uint8 tier, uint256 oldBps, uint256 newBps);
  event ExtensionCallSuccess(address account);
  event ExtensionCallFailed(address account, bytes reason);
  event PoolCapUpdated(uint256 oldCap, uint256 newCap);

  constructor(address _rewardToken) Ownable(msg.sender) {
    require(_rewardToken != address(0), "Zero address");
    IERC20 token = IERC20(_rewardToken);
    require(token.totalSupply() > 0, "Invalid token");
    
    rewardToken = _rewardToken;
    
    // Initialize tiers in constructor with days
    vestingTiers[0].period = 14 days;    // Back to 14 days
    vestingTiers[0].rewardBps = 500;     // 5% APY
    
    vestingTiers[1].period = 30 days;    // Back to 30 days
    vestingTiers[1].rewardBps = 2000;    // 20% APY
    
    vestingTiers[2].period = 60 days;    // Back to 60 days
    vestingTiers[2].rewardBps = 4000;    // 40% APY
  }

  modifier depositsEnabled() {
    require(depositingEnabled, "Deposits are disabled");
    _;
  }

  function setDepositingEnabled(bool _enabled) external onlyOwner {
    depositingEnabled = _enabled;
    emit DepositingStatusChanged(_enabled);
  }
  
function deposit(uint256 _amount, uint8 _tier) external nonReentrant depositsEnabled {
    require(_amount > 0, "Amount must be greater than 0");
    require(_tier < vestingTiers.length, "Invalid tier");
    require(totalDeposits + _amount <= MAX_POOL_CAP, "Pool cap reached");
    
    IERC20(rewardToken).safeTransferFrom(_msgSender(), address(this), _amount);
    _updatePosition(_msgSender(), _amount, false, _tier);
}

function withdraw(uint256 _amount) external nonReentrant {
    require(_amount > 0, "Amount must be greater than 0");
    Position storage position = positions[_msgSender()];
    require(_amount <= position.totalAmount, "Insufficient balance");
    
    uint256 withdrawableAmount = 0;
    for(uint256 i = 0; i < position.deposits.length; i++) {
        Deposit memory dep = position.deposits[i];
        if(block.timestamp > dep.depositTime + vestingTiers[dep.tier].period) {
            withdrawableAmount += dep.amount;
        }
    }
    require(withdrawableAmount >= _amount, "Lock period not finished");
    
    uint256 rewardAmount = getPendingRewards(_msgSender());
    
    _updatePosition(_msgSender(), _amount, true, position.deposits[0].tier);
    
    if (rewardAmount > 0) {
        userRewardsDistributed[_msgSender()] += rewardAmount;
        totalRewardsDistributed += rewardAmount;
        IERC20(rewardToken).safeTransfer(_msgSender(), _amount + rewardAmount);
        emit RewardDistributed(_msgSender(), rewardAmount);
    } else {
        IERC20(rewardToken).safeTransfer(_msgSender(), _amount);
    }
}

  function _updatePosition(
    address account,
    uint256 amount,
    bool isWithdraw,
    uint8 tier
  ) internal {
    if (address(vaultExtension) != address(0)) {
      try vaultExtension.setShare(account, amount, isWithdraw) {
        emit ExtensionCallSuccess(account);
      } catch (bytes memory reason) {
        emit ExtensionCallFailed(account, reason);
      }
    }
    if (isWithdraw) {
      _decreasePosition(account, amount);
      emit Withdraw(account, amount);
    } else {
      _increasePosition(account, amount, tier);
      emit Depositx(account, amount);
    }
  }

function _increasePosition(address wallet, uint256 amount, uint8 tier) private {
    require(wallet != address(0), "Zero address");
    Position storage position = positions[wallet];
    
    // Create new deposit instead of merging
    require(position.deposits.length < MAX_DEPOSITS_PER_USER, "Too many deposits");
    position.deposits.push(Deposit({
        amount: amount,
        depositTime: block.timestamp,
        tier: tier,
        rewardBps: vestingTiers[tier].rewardBps
    }));
    
    position.totalAmount += amount;
    totalDeposits += amount;
    
    if (position.totalAmount == amount) {
        totalParticipants++;
    }
}

function _decreasePosition(address wallet, uint256 amount) private {
    Position storage position = positions[wallet];
    require(position.totalAmount >= amount, "Insufficient balance");
    
    uint256 remaining = amount;
    // Process deposits from oldest to newest
    for (uint256 i = 0; i < position.deposits.length;) {
        Deposit storage dep = position.deposits[i];
        if (block.timestamp > dep.depositTime + vestingTiers[dep.tier].period) {
            uint256 withdrawAmount = remaining > dep.amount ? dep.amount : remaining;
            remaining -= withdrawAmount;
            dep.amount -= withdrawAmount;
            position.totalAmount -= withdrawAmount;
            
            if (dep.amount == 0) {
                // Move the last element to current position
                uint256 lastIndex = position.deposits.length - 1;
                if (i != lastIndex) {
                    position.deposits[i] = position.deposits[lastIndex];
                }
                position.deposits.pop();
                // Don't increment i since we need to check the swapped element
            } else {
                i++;
            }
        } else {
            i++;
        }
    }
    
    require(remaining == 0, "Lock period not finished for requested amount");
    
    if (position.totalAmount == 0) {
        totalParticipants--;
    }
    totalDeposits -= amount;
}

function getPendingRewards(address wallet) public view returns (uint256) {
    if (positions[wallet].totalAmount == 0) {
        return 0;
    }
    return _calculateRewards(positions[wallet].totalAmount, wallet);
}

  function _calculateRewards(uint256 /* unusedParam */, address wallet) internal view returns (uint256) {
    Position storage pos = positions[wallet];  // Use storage instead of memory
    uint256 length = pos.deposits.length;     // Cache array length
    if (length == 0) return 0;

    uint256 totalRewards = 0;
    uint256 currentTime = block.timestamp;    // Cache timestamp
    
    for (uint256 i = 0; i < length; i++) {
        Deposit storage dep = pos.deposits[i]; // Direct storage access
        uint256 timeElapsed = currentTime - dep.depositTime;
        uint256 vestingTime = vestingTiers[dep.tier].period;

        if (timeElapsed >= vestingTime) {
            uint256 rewardAmount = (dep.amount * dep.rewardBps) / 10000;
            totalRewards += rewardAmount;
        }
    }

    return totalRewards;
  }

  function setVaultExtension(IPoolExtension _extension) external onlyOwner {
    vaultExtension = _extension;
  }

  function emergencyWithdraw(uint256 _amount) external onlyOwner {
    require(_amount > 0 || _amount == 0, "Invalid amount");
    IERC20 _token = IERC20(rewardToken);
    uint256 withdrawAmount = _amount == 0 ? _token.balanceOf(address(this)) : _amount;
    require(withdrawAmount > 0, "Nothing to withdraw");
    _token.safeTransfer(_msgSender(), withdrawAmount);
  }

  function setTierReward(uint8 _tier, uint256 _newRewardBps) external onlyOwner {
    require(_tier < vestingTiers.length, "Invalid tier");
    require(_newRewardBps <= 10000, "Reward too high"); // Max 100%
    
    uint256 oldBps = vestingTiers[_tier].rewardBps;
    vestingTiers[_tier].rewardBps = _newRewardBps;
    
    emit RewardBpsUpdated(_tier, oldBps, _newRewardBps);
  }

  function getUserDeposits(address _user) external view returns (Deposit[] memory) {
    return positions[_user].deposits;
  }

  function getRemainingPoolSpace() external view returns (uint256) {
    if (totalDeposits >= MAX_POOL_CAP) return 0;
    return MAX_POOL_CAP - totalDeposits;
  }

  function setPoolCap(uint256 _newCap) external onlyOwner {
    require(_newCap >= totalDeposits, "New cap below current deposits");
    uint256 oldCap = MAX_POOL_CAP;
    MAX_POOL_CAP = _newCap;
    emit PoolCapUpdated(oldCap, _newCap);
  }
}
