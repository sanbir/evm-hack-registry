// SPDX-License-Identifier: MIT

pragma solidity 0.8.12;

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IGymMLM.sol";
import "./interfaces/IPancakeRouter02.sol";
import "./interfaces/IERC20Burnable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "./interfaces/IPancakePair.sol";
import "./interfaces/IPancakeFactory.sol";
import "@quant-finance/solidity-datetime/contracts/DateTime.sol";
/* preserved Line */
/* preserved Line */
/* preserved Line */
/* preserved Line */
/* preserved Line */

/**
 * @notice GymSinglePool contract:
 * - Users can:
 *   # Deposit GYMNET
 *   # Withdraw assets
 */

contract GymSinglePool is ReentrancyGuardUpgradeable, OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

   /**
     * @notice Info of each user
     * One Address can have many Deposits with different periods. Unlimited Amount.
     * Total Depsit Tokens = Total amount of user active stake in all.
     * Total Depsit Dollar Value = Total Dollar Value over all staking single pools. Calculated when user deposits tokens, and dollar value is for that exact moment rate.
     * level = level qualification for this pool. Used internally, for global qualification please check MLM Contract.
     * depositId = incremental ID of deposits, eg. if user has 3 stakings then this value will be 2;
     * totalClaimt = Total amount of tokens user claimt. 
     */
    struct UserInfo {
        uint256 totalDepositTokens;
        uint256 totalDepositDollarValue;
        uint256 level;
        uint256 depositId;
        uint256 totalClaimt;
    }

   /** 
     * @notice Info for each staking by ID
     * One Address can have many Deposits with different periods. Unlimited Amount.
     * depositTokens = amount of tokens for exact deposit.
     * depositDollarValue = Dollar value of deposit.
     * stakePeriod = Locking Period - from 3 months to 30 months. value is integer
     * depositTimestamp = timestamp of deposit
     * withdrawalTimestamp = Timestamp when user can withdraw his locked tokens
     * rewardsGained = amount of rewards user has gained during the process
     * is_finished = checks if user has already withdrawn tokens
     */
    struct UserDeposits {
        uint256 depositTokens;
        uint256 depositDollarValue;
        uint256 stakePeriod;
        uint256 depositTimestamp;
        uint256 withdrawalTimestamp;
        uint256 rewardsGained;
        uint256 rewardsClaimt;
        uint256 rewardDebt;
        bool is_finished;
    }
    /**
     * @notice Info of Pool
     * @param lastRewardBlock: Last block number that reward distribution occurs
     * @param accUTacoPerShare: Accumulated rewardPool per share, times 1e18
     * @param rewardPerBlock: How many reward tokens will user get per block
     */
    struct PoolInfo {
        uint256 lastRewardBlock;
        uint256 accRewardPerShare;
        uint256 rewardPerBlock;
    }

    /// Startblock number
    uint256 public startBlock;
    uint256 public withdrawFee;

     // MLM Contract - RelationShip address
    address public relationship;
    /// Treasury address where will be sent all unused assets
    address public treasuryAddress;
    /// Info of pool.
    PoolInfo public poolInfo;
    /// Info of each user that staked tokens.
    mapping(address => UserInfo) public userInfo;

    /// accepts user address and id of element to select - returns information about selected staking by id
    mapping (address=>UserDeposits[]) public user_deposits;

    uint256 private lastChangeBlock;

    /// GYMNET token contract address
    address public tokenAddress;

    /// address of pancake Router
    address public pancakeRouterAddress;
    /// WBNB and BUSD Token Pair address, element 0 = Address of WBNB Token, element 1= Address of GYMNET 
    address[] public wbnbAndUSDTTokenArray;
    /// GYMNET and WBNB Token Pair address, element 0 = Address of GYMNET, element 1 = Address of WBNB Token, 
    address[] public GymWBNBPair;

    /// Level Qualifications for the pool
    uint256[16] public levels;
    /// Locking Periods 
    uint256[6] public months;

    /// Amount of Total GYMNET Locked in the pool
    uint256 public totalGymnetLocked;

    /// Amount of GYMNET all users has claimt over time.
    uint256 public totalClaimtInPool;

    /// Percent that will be sent to MLM Contract for comission distribution
    uint256 public RELATIONSHIP_REWARD;

    /// 6% comissions
    uint256 public poolRewardsAmount;

    address public holderRewardContractAddress;

    address public runnerScriptAddress;
    uint256 public totalBurntInSinglePool;
    bool public isPoolActive;
    bool public isInMigrationToVTwo;
    uint256 public totalGymnetUnlocked;
    uint256 public unlockedTimestampQualification;
    address public vaultContractAddress;
    address public farmingContractAddress;
    /* ========== EVENTS ========== */

    event Initialized(address indexed executor, uint256 at);
    event Deposit(address indexed user, uint256 amount,uint indexed period);
    event Withdraw(address indexed user, uint256 amount,uint indexed period);
    event RewardPaid(address indexed token, address indexed user, uint256 amount);
    event ClaimUserReward(address indexed user, uint256 amount);


    modifier onlyRunnerScript() {
        require(msg.sender == runnerScriptAddress || msg.sender == owner(), "Only Runner Script");
        _;
    }
    modifier onlyBank() {
        require(msg.sender == vaultContractAddress, "GymFarming:: Only bank");
        _;
    }
    receive() external payable {}

    fallback() external payable {}

// all initialize parameters are mandatory
    function initialize(
        uint256 _startBlock,
        address _gym,
        address _mlm,
        uint256 _gymRewardRate,
        address _pancakeRouterAddress,
        address[] memory _wbnbAndUSDTTokenArray,
        address[] memory _GymWBNBPair
    ) external initializer {
        require(block.number < _startBlock, "SinglePool: Start block must have a bigger value");

        startBlock = _startBlock; // Number of Upcoming Block
        relationship = _mlm;  // address of MLM contract
        tokenAddress = _gym; // address of GYMNET Contract
        pancakeRouterAddress = _pancakeRouterAddress; // Address of Pancake Router
        wbnbAndUSDTTokenArray = _wbnbAndUSDTTokenArray; // WBNB And USDT Token Addresses [WBNB,USDT]
        GymWBNBPair = _GymWBNBPair; // GYMNET And WBNB Token Addresses [GYMNET,WBNB]
        runnerScriptAddress = msg.sender;
        isPoolActive = false;
        isInMigrationToVTwo = false;
        RELATIONSHIP_REWARD = 39; // Relationship commission amount
        levels = [0, 0, 200, 200, 2000, 4000, 10000, 20000, 40000, 45000, 50000, 60000, 65000, 70000, 75000, 80000]; // Internal Pool Levels
        months = [3, 6, 12, 18, 24, 30]; // Locking Periods

        poolInfo = PoolInfo({
                lastRewardBlock: _startBlock,
                rewardPerBlock: _gymRewardRate,
                accRewardPerShare: 0
            });

        lastChangeBlock = _startBlock;

        __Ownable_init();
        __ReentrancyGuard_init();
        
        emit Initialized(msg.sender, block.number);
    }


    function setPoolInfo(uint256 lastRewardBlock,uint256 accRewardPerShare, uint256 rewardPerBlock) external onlyOwner {
        poolInfo = PoolInfo({
                lastRewardBlock: lastRewardBlock,
                accRewardPerShare: accRewardPerShare,
                rewardPerBlock: rewardPerBlock
            });
    }

    function updateStartBlock(uint256 _startBlock) external onlyOwner {
        startBlock = _startBlock;
    }

    function setMLMAddress(address _relationship) external onlyOwner {
        relationship = _relationship;
    }

    function setTokenAddress(address _tokenAddress) external onlyOwner {
        tokenAddress = _tokenAddress;
    }
    function setVaultContractAddress(address _vaultContractAddress) external onlyOwner {
        vaultContractAddress = _vaultContractAddress;
    }
    function setFarmingContractAddress(address _farmingContractAddress) external onlyOwner {
        farmingContractAddress = _farmingContractAddress;
    }

    function setRelationshipReward(uint256 _amount) external onlyOwner {
        RELATIONSHIP_REWARD = _amount;
    }
    function setOnlyRunnerScript(address _onlyRunnerScript) external onlyOwner {
        runnerScriptAddress = _onlyRunnerScript;
    }

    function setGymWBNBPair(address[] memory  _GymWBNBPair) external onlyOwner {
        GymWBNBPair = _GymWBNBPair;
    }
    function setPancakeRouterAddress(address _pancakeRouterAddress) external onlyOwner {
        pancakeRouterAddress = _pancakeRouterAddress;
    }

    function setIsPoolActive(bool _isPoolActive) external onlyOwner {
        isPoolActive = _isPoolActive;
    }
    function setIsInMigrationToVTwo(bool _isInMigrationToVTwo) external onlyOwner {
        isInMigrationToVTwo = _isInMigrationToVTwo;
    }

    function setHolderRewardContractAddress(address _holderRewardContractAddress) external onlyOwner {
        holderRewardContractAddress = _holderRewardContractAddress;
    }


    function setWbnbAndUSDTTokenArray(address[] memory _wbnbAndUSDTTokenArray) external onlyOwner {
        wbnbAndUSDTTokenArray = _wbnbAndUSDTTokenArray;
    }
    function setUnlockedTimestampQualification(uint256 _unlockedTimestampQualification) external onlyOwner {
        unlockedTimestampQualification = _unlockedTimestampQualification;
    }
    function setLevels(uint256[16] calldata _levels) external onlyOwner {
        levels = _levels;
    }

     /**
     * @notice  Function to set Treasury address
     * @param _treasuryAddress Address of treasury address
     */
    function setTreasuryAddress(address _treasuryAddress) external nonReentrant onlyOwner {
        treasuryAddress = _treasuryAddress;
    }

    /**
     * @notice Deposit in given pool
     * @param _depositAmount: Amount of want token that user wants to deposit
     */
    function deposit(
        uint256 _depositAmount,
        uint8 _periodId,
        uint256 _referrerId,
        bool isUnlocked
    ) external  {
        require(isPoolActive,'Contract is not running yet');
        IGymMLM(relationship).addGymMLM(msg.sender, _referrerId);
        _deposit(_depositAmount,_periodId,isUnlocked);
    }
    /**
     * @notice Deposit in given pool
     * @param _depositAmount: Amount of want token that user wants to deposit
     */
    function depositFromOtherContract(
        uint256 _depositAmount,
        uint8 _periodId,
        bool isUnlocked,
        address _from
    ) external  {
        require(isPoolActive,'Contract is not running yet');
        _autoDeposit(_depositAmount,_periodId,isUnlocked,_from);
    }

    /**
     * @notice To get User level in other contract for single pool.
     * @param _user: User address
     */
    function getUserLevelInSinglePool(address _user) external view returns (uint32) {
        uint256 _totalDepositDollarValue = userInfo[_user].totalDepositDollarValue;
        uint32 level = 0;
        for (uint32 i = 0; i<levels.length ; i++) {
            if(_totalDepositDollarValue >= levels[i]) {
                level=i;
            }
        }
        return level;
    }

    /**
    Should approve allowance before initiating
    accepts depositAmount in WEI
    periodID - id of months array accordingly
    */
    function _deposit(
        uint256 _depositAmount,
        uint8 _periodId,
        bool _isUnlocked
    ) private {
        UserInfo storage user = userInfo[msg.sender];
        IERC20Upgradeable token = IERC20Upgradeable(tokenAddress);
        PoolInfo storage pool = poolInfo;
        updatePool();

        uint256 period = months[_periodId];
        uint256 lockTimesamp = DateTime.addMonths(block.timestamp,months[_periodId]);
        uint256 burnTokensAmount = 0;

        if(!_isUnlocked) {
            burnTokensAmount = (_depositAmount * 4) / 100;
            totalBurntInSinglePool += burnTokensAmount;
            IERC20Burnable(tokenAddress).burnFrom(msg.sender,burnTokensAmount);
        }

        
        uint256 amountToDeposit = _depositAmount - burnTokensAmount;

        token.safeTransferFrom(msg.sender, address(this), amountToDeposit);
        uint256 UsdValueOfGym = ((amountToDeposit * getPrice())/1e18) / 1e18;

        user.totalDepositTokens += amountToDeposit;
        user.totalDepositDollarValue += UsdValueOfGym;
        totalGymnetLocked += amountToDeposit;
        if(_isUnlocked) {
            totalGymnetUnlocked += amountToDeposit;
            period = 0; 
            lockTimesamp = DateTime.addSeconds(block.timestamp,months[_periodId]);
        }

        uint256 rewardDebt = (amountToDeposit * (pool.accRewardPerShare)) / (1e18);
        UserDeposits memory depositDetails = UserDeposits(
            {
                depositTokens: amountToDeposit, 
                depositDollarValue: UsdValueOfGym,
                stakePeriod: period,
                depositTimestamp: block.timestamp,
                withdrawalTimestamp: lockTimesamp,
                rewardsGained: 0,
                is_finished: false,
                rewardsClaimt: 0,
                rewardDebt: rewardDebt
            }
        );

        user_deposits[msg.sender].push(depositDetails);
        user.depositId = user_deposits[msg.sender].length;
        

       for (uint i = 0; i<levels.length ; i++) {
            if(user.totalDepositDollarValue >= levels[i]) {
                user.level=i;
            }
        }

        emit Deposit(msg.sender, _depositAmount,_periodId);
    }

     /**
    Should approve allowance before initiating
    accepts depositAmount in WEI
    periodID - id of months array accordingly
    */
    function _autoDeposit(
        uint256 _depositAmount,
        uint8 _periodId,
        bool _isUnlocked,
        address _from
    ) private {
        UserInfo storage user = userInfo[_from];
        IERC20Upgradeable token = IERC20Upgradeable(tokenAddress);
        PoolInfo storage pool = poolInfo;
        token.approve(address(this), _depositAmount);
        updatePool();
        uint256 period = months[_periodId];
        uint256 lockTimesamp = DateTime.addMonths(block.timestamp,months[_periodId]);
        uint256 burnTokensAmount = 0;
        // if(!_isUnlocked) {
        //     uint256 burnTokensAmount = (_depositAmount * 4) / 100;
        //     totalBurntInSinglePool += burnTokensAmount;
        //     IERC20Burnable(tokenAddress).burnFrom(msg.sender,burnTokensAmount);
        // }
        uint256 amountToDeposit = _depositAmount - burnTokensAmount;
        uint256 UsdValueOfGym = ((amountToDeposit * getPrice())/1e18) / 1e18;

        user.totalDepositTokens += amountToDeposit;
        user.totalDepositDollarValue += UsdValueOfGym;
        totalGymnetLocked += amountToDeposit;
        if(_isUnlocked) {
            totalGymnetUnlocked += amountToDeposit;
            period = 0; 
            lockTimesamp = DateTime.addSeconds(block.timestamp,months[_periodId]);
        }

        uint256 rewardDebt = (amountToDeposit * (pool.accRewardPerShare)) / (1e18);
        UserDeposits memory depositDetails = UserDeposits(
            {
                depositTokens: amountToDeposit, 
                depositDollarValue: UsdValueOfGym,
                stakePeriod: period,
                depositTimestamp: block.timestamp,
                withdrawalTimestamp: lockTimesamp,
                rewardsGained: 0,
                is_finished: false,
                rewardsClaimt: 0,
                rewardDebt: rewardDebt
            }
        );
        user_deposits[_from].push(depositDetails);
        user.depositId = user_deposits[_from].length;
 
        emit Deposit(_from, amountToDeposit,_periodId);
    }

     /**
     * Returns the latest price
     */
    function getPrice () public view returns (uint) {
        uint256[] memory gymPriceInUSD = IPancakeRouter02(pancakeRouterAddress).getAmountsOut(1000000000000000000,GymWBNBPair);
        uint256[] memory BNBPriceInUSD = IPancakeRouter02(pancakeRouterAddress).getAmountsOut(1, wbnbAndUSDTTokenArray);
        return gymPriceInUSD[1] * BNBPriceInUSD[1];
    }


    /**
     * @notice withdraw one claim
     * @param _depositId: is the id of user element. 
     */
    function withdraw(
        uint256 _depositId
    ) external  {
        require(_depositId >= 0, "Value is not specified");
        updatePool();
        _withdraw(_depositId);
    }

    /**
    Should approve allowance before initiating
    accepts _depositId - is the id of user element. 
    */
    function _withdraw(
            uint256 _depositId
        ) private {
            UserInfo storage user = userInfo[msg.sender];
            IERC20Upgradeable token = IERC20Upgradeable(tokenAddress);
            PoolInfo storage pool = poolInfo;
            UserDeposits storage depositDetails = user_deposits[msg.sender][_depositId];
            if(!isInMigrationToVTwo) {
                require(block.timestamp > depositDetails.withdrawalTimestamp,"Locking Period isn't over yet.");
            }
            require(!depositDetails.is_finished,"You already withdrawn your deposit.");

            _claim(_depositId,1);
            depositDetails.rewardDebt = (depositDetails.depositTokens * (pool.accRewardPerShare)) / (1e18);

            user.totalDepositTokens -=  depositDetails.depositTokens;
            user.totalDepositDollarValue -=  depositDetails.depositDollarValue;
            totalGymnetLocked -= depositDetails.depositTokens;
            if(depositDetails.stakePeriod == 0) {
                totalGymnetUnlocked -= depositDetails.depositTokens;
            }
            
            token.safeTransferFrom(address(this),msg.sender, depositDetails.depositTokens);

            for (uint i = 0; i<levels.length ; i++) {
                if(user.totalDepositDollarValue >= levels[i]) {
                    user.level=i;
                }
            }
            depositDetails.is_finished = true;
            emit Withdraw(msg.sender,  depositDetails.depositTokens,depositDetails.stakePeriod);


        }


    /**
     * @notice Claim rewards you gained over period
     * @param _depositId: is the id of user element. 
     */
    function claim(
        uint256 _depositId
    ) external  {
        require(_depositId >= 0, "Value is not specified");
        updatePool();
        refreshMyLevel(msg.sender);
        _claim(_depositId,0);
    }

   /*
    Should approve allowance before initiating
    accepts _depositId - is the id of user element. 
    */
    function _claim(
            uint256 _depositId,
            uint256 fromWithdraw
        ) private {
            UserInfo storage user = userInfo[msg.sender];
            IERC20Upgradeable token = IERC20Upgradeable(tokenAddress);
            UserDeposits storage depositDetails = user_deposits[msg.sender][_depositId];
            PoolInfo storage pool = poolInfo;

            uint256 pending = pendingReward(_depositId,msg.sender);

            if(fromWithdraw == 0) {
                require(pending > 0 ,"No rewards to claim.");
            }


            if (pending > 0) {
                uint256 distributeRewardTokenAmt = (pending * RELATIONSHIP_REWARD) / 100;
                token.safeTransfer(relationship, distributeRewardTokenAmt);
                IGymMLM(relationship).distributeRewards(pending, address(tokenAddress), msg.sender, 3);

                // 6% distribution 
                uint256 calculateDistrubutionReward = (pending * 6) / 100;
                poolRewardsAmount += calculateDistrubutionReward; 
                
                uint256 calcUserRewards = (pending-distributeRewardTokenAmt-calculateDistrubutionReward);
                safeRewardTransfer(tokenAddress, msg.sender, calcUserRewards);

                user.totalClaimt += calcUserRewards;
                totalClaimtInPool += pending;
                depositDetails.rewardsClaimt += pending;
                depositDetails.rewardDebt = (depositDetails.depositTokens * (pool.accRewardPerShare)) / (1e18);
                emit ClaimUserReward(msg.sender,  calcUserRewards);
                 depositDetails.rewardsGained = 0;
            }
            
            // token.safeTransferFrom(address(this),msg.sender, depositDetails.rewardsGained);

        }


      
   /*
    transfers pool commisions to management
    */
    function transferPoolRewards() public onlyRunnerScript {
            require(address(holderRewardContractAddress) != address(0x0),"Holder Reward Address::SET_ZERO_ADDRESS");
            IERC20Upgradeable token = IERC20Upgradeable(tokenAddress);
            token.safeTransfer(holderRewardContractAddress, poolRewardsAmount);
            // token.safeTransfer(relationship, poolRewardsAmount/2);
            poolRewardsAmount = 0;
        }  


    /**
     * @notice  Safe transfer function for reward tokens
     * @param _rewardToken Address of reward token contract
     * @param _to Address of reciever
     * @param _amount Amount of reward tokens to transfer
     */
    function safeRewardTransfer(
        address _rewardToken,
        address _to,
        uint256 _amount
    ) internal {
        uint256 _bal = IERC20Upgradeable(_rewardToken).balanceOf(address(this));
        if (_amount > _bal) {
            require(IERC20Upgradeable(_rewardToken).transfer(_to, _bal), "GymSinglePool:: Transfer failed");
        } else {
            require(IERC20Upgradeable(_rewardToken).transfer(_to, _amount), "GymSinglePool:: Transfer failed");
        }
    }
    /**
     * @notice To get User Info in other contract.
     */
    function getUserInfo(address _user) external view returns (UserInfo memory) {
        return userInfo[_user];
    }

        /**
     * @notice View function to see pending reward on frontend.
     * @param _depositId: Staking pool id
     * @param _user: User address
     */
    function pendingReward(uint256 _depositId, address _user) public view returns (uint256) {
        UserDeposits storage depositDetails = user_deposits[_user][_depositId];
        UserInfo storage user = userInfo[_user];
        PoolInfo storage pool = poolInfo;
        if(depositDetails.is_finished == true || depositDetails.stakePeriod == 0){
            return 0;
        }
      
        uint256 _accRewardPerShare = pool.accRewardPerShare;
        uint256 sharesTotal = totalGymnetLocked-totalGymnetUnlocked;

        if (block.number > pool.lastRewardBlock && sharesTotal != 0) {
            uint256 _multiplier = block.number - pool.lastRewardBlock;
            uint256 _reward = (_multiplier * pool.rewardPerBlock);
             _accRewardPerShare = _accRewardPerShare + ((_reward * 1e18) / sharesTotal);
        }

        return (depositDetails.depositTokens * _accRewardPerShare) / (1e18) - (depositDetails.rewardDebt);
    }


    /**
     * @notice Update reward variables of the given pool to be up-to-date.
     */
    function updatePool() public {
        PoolInfo storage pool = poolInfo;
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 sharesTotal = totalGymnetLocked-totalGymnetUnlocked;
        if (sharesTotal == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = block.number - pool.lastRewardBlock;
        if (multiplier <= 0) {
            return;
        }
        uint256 _rewardPerBlock = pool.rewardPerBlock;
        uint256 _reward = (multiplier * _rewardPerBlock);
        pool.accRewardPerShare = pool.accRewardPerShare + ((_reward * 1e18) / sharesTotal);
        pool.lastRewardBlock = block.number;
    }
    /**
     * @notice Claim All Rewards in one Transaction Internat Function.
     * If reinvest = true, Rewards will be reinvested as a new Staking
     * Reinvest Period Id is the id of months element
     */
    function _claimAll(bool reinvest,uint8 reinvestPeriodId) private {
        UserInfo storage user = userInfo[msg.sender];
        IERC20Upgradeable token = IERC20Upgradeable(tokenAddress);
        PoolInfo storage pool = poolInfo;
         updatePool();
         uint256 distributeRewardTokenAmtTotal = 0;
         uint256 calcUserRewardsTotal = 0;
         uint256 totalDistribute = 0;
        for (uint256 i = 0; i<user.depositId ; i++) {
            UserDeposits storage depositDetails = user_deposits[msg.sender][i];
            uint256 pending = pendingReward(i,msg.sender);
            totalDistribute += pending;
            if (pending > 0) {
                uint256 distributeRewardTokenAmt = (pending * RELATIONSHIP_REWARD) / 100;
                 distributeRewardTokenAmtTotal += distributeRewardTokenAmt;
                // 6% distribution 
                uint256 calculateDistrubutionReward = (pending * 6) / 100;
                poolRewardsAmount += calculateDistrubutionReward; 
                
                uint256 calcUserRewards = (pending-distributeRewardTokenAmt-calculateDistrubutionReward);
                calcUserRewardsTotal += calcUserRewards;

                user.totalClaimt += calcUserRewards;
                totalClaimtInPool += pending;
                depositDetails.rewardsClaimt += pending;
                depositDetails.rewardDebt = (depositDetails.depositTokens * (pool.accRewardPerShare)) / (1e18);
                emit ClaimUserReward(msg.sender,  calcUserRewards);
                 depositDetails.rewardsGained = 0;
            }
            
        }
        token.safeTransfer(relationship, distributeRewardTokenAmtTotal);
        IGymMLM(relationship).distributeRewards(totalDistribute, address(tokenAddress), msg.sender, 3);
        safeRewardTransfer(tokenAddress, msg.sender, calcUserRewardsTotal);
        if(reinvest == true) {
          _deposit(calcUserRewardsTotal,reinvestPeriodId,false);
        }
    }
    /**
     * @notice Claim All Rewards in one Transaction.
     */
    function claimAll() public {
         refreshMyLevel(msg.sender);
        _claimAll(false,0);
    }
    /**
     * @notice Claim and Reinvest all rewards public function to trigger internal _claimAll function.
     */
    function claimAndReinvest(bool reinvest,uint8 periodId) public {
        require(isPoolActive,'Contract is not running yet');
        _claimAll(reinvest,periodId);
    }

    function refreshMyLevel(address _user) public {
        UserInfo storage user = userInfo[_user];
        for (uint i = 0; i<levels.length ; i++) {
            if(user.totalDepositDollarValue >= levels[i]) {
                user.level=i;
            }
        }
    }
    function totalLockedTokens(address _user) public view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        uint256 totalDepositLocked = 0;
        for (uint256 i = 0; i<user.depositId ; i++) {
            UserDeposits storage depositDetails = user_deposits[_user][i];
            if(depositDetails.stakePeriod != 0 && !depositDetails.is_finished) {
                totalDepositLocked += depositDetails.depositTokens;
            } 
        }
        return totalDepositLocked;
    }

    function switchToUnlocked(uint256 _depositId) public {
        UserInfo storage user = userInfo[msg.sender];
        UserDeposits storage depositDetails = user_deposits[msg.sender][_depositId];
        require(depositDetails.depositTimestamp <= unlockedTimestampQualification,'Function is only for Users that deposited before Unlocked Staking Upgrade');
        _claim(_depositId,1);
        uint256 lockTimesamp = DateTime.addSeconds(block.timestamp,1);

        depositDetails.stakePeriod = 0;
        depositDetails.withdrawalTimestamp = lockTimesamp;
        totalGymnetUnlocked += depositDetails.depositTokens;

    }

    

}