// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "../interfaces/IORT.sol";

contract StakingPool is
    Initializable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    //Model  Array for staking
    struct staking {
        address owner;
        uint256 balances;
        uint256 end_staking;
        uint256 duration;
        bool changeClaimed;
        uint256 check_claim;
    }

    //ERC20PresetMinterPauser variable
    IORT private rewardToken;
    //variables
    mapping(address => uint256) private duration;
    //variables
    mapping(address => uint256) private end_staking;
    //IERC20Upgradeable variable
    IERC20Upgradeable private stakeToken;
    address public admin;
    //variables
    uint256 private total_percent;
    uint256 private total_percent2;
    //new variables
    staking[] public tokens_staking;
    mapping(address => uint256[]) public userStake;

    event Invest(
        address indexed user,
        uint256 indexed lockId,
        uint256 endDate,
        uint256 duration,
        uint256 amountStaked,
        uint256 reward
    );
    event Withdraw(
        address indexed user,
        uint256 indexed lockId,
        uint256 amountWithdrawn
    );
    event Claim(
        address indexed user,
        uint256 indexed lockId,
        uint256 amountclaimed
    );

    //initialize function
    function initialize(IORT _rewardToken, IERC20Upgradeable _stakeToken)
        public
        initializer
    {
        admin = msg.sender;
        rewardToken = _rewardToken;
        stakeToken = _stakeToken;

        __Ownable_init();
        __ReentrancyGuard_init_unchained();
        __Pausable_init_unchained();
    }

    //Only stakeOwner Modifyer
    modifier onlyStakeOwner(uint256 stakeId) {
        require(tokens_staking.length > stakeId, "STACK DOES_NOT_EXIST");
        require(
            tokens_staking[stakeId].owner == msg.sender,
            "STACKINGPOOL: UNAUTHORIZED USER"
        );
        _;
    }

    // ivesting function for staking
    function invest(uint256 end_date, uint256 qty_ort) external whenNotPaused {
        require(qty_ort > 0, "amount cannot be 0");
        //transfer token to this smart contract
        stakeToken.approve(address(this), qty_ort);
        stakeToken.safeTransferFrom(msg.sender, address(this), qty_ort);
        //save their staking duration for further use
        if (end_date == 3) {
            end_staking[msg.sender] = block.timestamp + 90 days;
            duration[msg.sender] = 3;
        } else if (end_date == 6) {
            end_staking[msg.sender] = block.timestamp + 180 days;
            duration[msg.sender] = 6;
        } else if (end_date == 12) {
            end_staking[msg.sender] = block.timestamp + 365 days;
            duration[msg.sender] = 12;
        } else if (end_date == 24) {
            end_staking[msg.sender] = block.timestamp + 730 days;
            duration[msg.sender] = 24;
        }
        //calculate reward tokens  for further use
        uint256 check_reward = _Check_reward(duration[msg.sender], qty_ort) /
            1 ether;
        //save values in array
        tokens_staking.push(
            staking(
                msg.sender,
                qty_ort,
                end_staking[msg.sender],
                duration[msg.sender],
                true,
                check_reward
            )
        );
        //save array index in map
        uint256 lockId = tokens_staking.length - 1;
        userStake[msg.sender].push(lockId);

        emit Invest(
            msg.sender,
            lockId,
            end_staking[msg.sender],
            duration[msg.sender],
            qty_ort,
            check_reward
        );
    }

    //get all stake ids  of user
    function getUserStaking(address user)
        external
        view
        returns (uint256[] memory)
    {
        return userStake[user];
    }

    //withdraw and claim at once
    function withdrawAndClaim(uint256 lockId)
        external
        nonReentrant
        whenNotPaused
        onlyStakeOwner(lockId)
    {
        _withdraw(lockId);
        _claim(lockId);
    }

    //withdraw function
    function withdraw_amount(uint256 lockId)
        external
        nonReentrant
        whenNotPaused
        onlyStakeOwner(lockId)
    {
        _withdraw(lockId);
    }

    function _withdraw(uint256 lockId) internal {
        require(tokens_staking[lockId].balances > 0, "not an investor");
        require(
            block.timestamp >= tokens_staking[lockId].end_staking,
            "too early"
        );
        //Change status of invester for reward
        uint256 invested_balance = 0;
        invested_balance = tokens_staking[lockId].balances;
        tokens_staking[lockId].changeClaimed = false;
        tokens_staking[lockId].balances = 0;
        tokens_staking[lockId].duration = 0;
        tokens_staking[lockId].end_staking = 0;
        //transfer back amount to user
        stakeToken.safeTransfer(msg.sender, invested_balance);

        emit Withdraw(msg.sender, lockId, invested_balance);
    }

    //Claim rewards
    function Claim_reward(uint256 lockId)
        external
        nonReentrant
        whenNotPaused
        onlyStakeOwner(lockId)
    {
        _claim(lockId);
    }

    function _claim(uint256 lockId) internal {
        require(tokens_staking[lockId].check_claim > 0, "No Reward Available");
        require(
            tokens_staking[lockId].changeClaimed == false,
            "Already claimed"
        );
        //change status of invested user
        tokens_staking[lockId].changeClaimed = true;
        uint256 claimed_amount = 0;
        claimed_amount = tokens_staking[lockId].check_claim;
        tokens_staking[lockId].check_claim = 0;
        //mint new ort token
        rewardToken.mint(msg.sender, claimed_amount);

        emit Claim(msg.sender, lockId, claimed_amount);
    }

    //Total percent function
    function _Percentage(uint256 _value, uint256 _percentage)
        internal
        pure
        returns (uint256)
    {
        uint256 basePercent = 100;
        uint256 Percent = (_value * _percentage) / basePercent;
        return Percent;
    }

    //Reward Calculation
    function _Check_reward(uint256 durations, uint256 balance)
        internal
        returns (uint256)
    {
        total_percent2 = balance / 1 ether;
        //if user stakes token for 3 months
        if (durations == 3) {
            if (total_percent2 >= 10000 && total_percent2 < 40000) {
                total_percent = _Percentage(balance, 600000000000000000);
            } else if (total_percent2 >= 40000 && total_percent2 < 60000) {
                total_percent = _Percentage(balance, 1200000000000000000);
            } else if (total_percent2 >= 60000 && total_percent2 < 80000) {
                total_percent = _Percentage(balance, 1800000000000000000);
            } else if (total_percent2 >= 80000 && total_percent2 < 100000) {
                total_percent = _Percentage(balance, 2400000000000000000);
            } else if (total_percent2 >= 100000) {
                total_percent = _Percentage(balance, 3000000000000000000);
            }
        } else if (durations == 6) {
            if (total_percent2 >= 10000 && total_percent2 < 40000) {
                total_percent = _Percentage(balance, 1600000000000000000);
            } else if (total_percent2 >= 40000 && total_percent2 < 60000) {
                total_percent = _Percentage(balance, 3200000000000000000);
            } else if (total_percent2 >= 60000 && total_percent2 < 80000) {
                total_percent = _Percentage(balance, 4800000000000000000);
            } else if (total_percent2 >= 80000 && total_percent2 < 100000) {
                total_percent = _Percentage(balance, 6400000000000000000);
            } else if (total_percent2 >= 100000) {
                total_percent = _Percentage(balance, 8000000000000000000);
            }
        } else if (durations == 12) {
            if (total_percent2 >= 10000 && total_percent2 < 40000) {
                total_percent = _Percentage(balance, 4000000000000000000);
            } else if (total_percent2 >= 40000 && total_percent2 < 60000) {
                total_percent = _Percentage(balance, 8000000000000000000);
            } else if (total_percent2 >= 60000 && total_percent2 < 80000) {
                total_percent = _Percentage(balance, 12000000000000000000);
            } else if (total_percent2 >= 80000 && total_percent2 < 100000) {
                total_percent = _Percentage(balance, 16000000000000000000);
            } else if (total_percent2 >= 100000) {
                total_percent = _Percentage(balance, 20000000000000000000);
            }
        } else if (durations == 24) {
            if (total_percent2 >= 10000 && total_percent2 < 40000) {
                total_percent = _Percentage(balance, 11200000000000000000);
            } else if (total_percent2 >= 40000 && total_percent2 < 60000) {
                total_percent = _Percentage(balance, 22400000000000000000);
            } else if (total_percent2 >= 60000 && total_percent2 < 80000) {
                total_percent = _Percentage(balance, 33600000000000000000);
            } else if (total_percent2 >= 80000 && total_percent2 < 100000) {
                total_percent = _Percentage(balance, 44800000000000000000);
            } else if (total_percent2 >= 100000) {
                total_percent = _Percentage(balance, 56000000000000000000);
            }
        }
        return total_percent;
    }

    //Emergency withdraw function
    function Withdraw_Emergency(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be non zero");
        stakeToken.safeTransfer(admin, amount);
    }

    //Emergency pause function
    function setPaused(bool _paused) external onlyOwner {
        if (_paused) _pause();
        else _unpause();
    }
}
