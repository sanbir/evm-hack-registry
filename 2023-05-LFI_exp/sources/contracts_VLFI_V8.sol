// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/draft-ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";
import "contracts/interfaces/ILFIToken.sol";

contract VLFI_8 is
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    AccessControlUpgradeable,
    ERC20VotesUpgradeable
{
    // DO NOT CHANGE THE NAME, TYPE OR ORDER OF EXISITING VARIABLES BELOW

    uint256 constant MAX_PRECISION = 18;
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    uint256 private constant ACC_REWARD_PRECISION = 1e18;
    ILFIToken public STAKED_TOKEN;
    uint256 public liquidity;
    uint256 public lpTokenPrice;
    uint256 COOLDOWN_SECONDS;
    uint256 UNSTAKE_WINDOW;
    uint256 private rewardPerSecond;

    struct FarmInfo {
        uint256 accRewardsPerShare;
        uint256 lastRewardTime;
    }

    struct UserInfo {
        uint256 amount;
        int256 rewardDebt;
    }

    FarmInfo farmInfo;

    mapping(address => uint256) private cooldownStartTimes;
    mapping(address => uint256) private userDeposits;
    mapping(address => UserInfo) private userInfo;

    // DO NOT CHANGE THE NAME, TYPE OR ORDER OF EXISITING VARIABLES ABOVE

    event Staked(
        address indexed from,
        address indexed onBehalfOf,
        uint256 amount
    );
    event UnStaked(address indexed from, address indexed to, uint256 amount);
    event CooldownActivated(address indexed user);
    event RewardsClaimed(
        address indexed from,
        address indexed to,
        uint256 amount
    );

    // Variables related to VLFI V2.

    bytes32 public constant DATA_PROVIDER_ORACLE =
        keccak256("DATA_PROVIDER_ORACLE");
    bytes32 public constant HOUSE_POOL_DATA_PROVIDER =
        keccak256("HOUSE_POOL_DATA_PROVIDER");

    bytes32 public constant STAKING_MANAGER = keccak256("STAKING_MANAGER");
    int256 private constant INT_ACC_REWARD_PRECISION = 1e18;
    struct ValuesOfInterest {
        int256 expectedValue;
        int256 maxExposure;
        uint256 deadline;
        address signer;
    }

    struct BetInfo {
        bool parlay;
        address user;
        uint256 Id;
        uint256 amount;
        uint256 result;
        uint256 payout;
        uint256 commission;
    }

    bool private cooldownActive;
    uint8 pool_decimals;
    uint256 private runningTotalDeposits;
    string public poolName;
    int256 public pendingStakes;
    int256 public totalValueLocked;
    uint256 initlpTokenPrice;
    address private sportsBookContract;

    ValuesOfInterest private voi;
    mapping(address => int256) private userEVTracker;
    mapping(address => uint256[]) private userBets;
    mapping(uint256 => BetInfo) private betInfoWithId;

    address treasury;

    event BetSettled(uint256 betID, uint256 result);
    event PoolAttributesUpdated(
        uint256 timeStamp,
        uint256 runningTotalDeposits,
        string poolName,
        uint256 liquidity,
        int256 tvl,
        uint256 lpTokenPrice,
        int256 pendingStakes,
        int256 ev,
        int256 me
    );
    event SetRewards(uint256 rewardsPerSecond);

    event TreasuryWithdrawal(uint256 amount);
    // DO NOT CHANGE THE NAME, TYPE OR ORDER OF EXISITING VARIABLES BELOW
    mapping(address => uint256) public pendingRewards;
    mapping(address => bool) public userCleanMapping;

    // DO NOT CHANGE THE NAME, TYPE OR ORDER OF EXISITING VARIABLES ABOVE

    modifier onlyValid(ValuesOfInterest memory data, bytes memory signature) {
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    keccak256(
                        "VoI(address signer,int256 expectedValue,int256 maxExposure,uint256 nonce,uint256 deadline)"
                    ),
                    data.signer,
                    data.expectedValue,
                    data.maxExposure,
                    0,
                    data.deadline
                )
            )
        );
        require(
            SignatureChecker.isValidSignatureNow(
                data.signer,
                digest,
                signature
            ),
            "invalid signature"
        );
        require(data.signer != address(0), "invalid signer");
        require(
            hasRole(DATA_PROVIDER_ORACLE, data.signer),
            "unauthorised signer"
        );
        require(block.number < data.deadline, "signed transaction expired");
        _;
    }

    /// @notice initialize function called by Openzeppelin Hardhat upgradeable plugin
    function initialize(
        string memory name,
        string memory symbol,
        ILFIToken stakedToken,
        uint256 cooldownSeconds,
        uint256 unstakeWindow,
        uint256 rewardsPerSecond
    ) external initializer {
        __ERC20_init(name, symbol);
        __ERC20Permit_init(name);
        STAKED_TOKEN = stakedToken;
        COOLDOWN_SECONDS = cooldownSeconds;
        UNSTAKE_WINDOW = unstakeWindow;
        lpTokenPrice = 1000 * 10 ** MAX_PRECISION;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
        _grantRole(STAKING_MANAGER, msg.sender);
        setRewardPerSecond(rewardsPerSecond);
        createFarm();
    }

    /*** Functions to call after upgradation */
    ///@notice Set the poolName for the upgraded VLFI
    ///@param _poolName Name of the pool
    function setPoolName(
        string memory _poolName
    ) external onlyRole(MANAGER_ROLE) {
        poolName = _poolName;
    }

    ///@notice Set the pool decimals for the upgraded VLFI
    ///@param _decimals decimals of the pool
    function setDecimals(uint8 _decimals) external onlyRole(MANAGER_ROLE) {
        pool_decimals = _decimals;
    }

    ///@notice Set the initial pool token price
    ///@param _initLpTokenPrice decimals of the pool
    function initLpTokenPrice(
        uint256 _initLpTokenPrice
    ) external onlyRole(MANAGER_ROLE) {
        initlpTokenPrice = _initLpTokenPrice;
    }

    ///@notice Set treasury address
    ///@param _treasuryAddress decimals of the pool
    function setTreasuryAddress(
        address _treasuryAddress
    ) external onlyRole(MANAGER_ROLE) {
        treasury = _treasuryAddress;
    }

    ///@notice get treasury address
    function getTreasuryAddress() external view returns (address) {
        return treasury;
    }

    /*** Functions to call after upgradation */

    ///@notice Get the Cooldown seconds of the user
    ///@param _staker Address of the Staker
    ///@return returns cooldown time of the staker
    function getUserCooldown(address _staker) external view returns (uint256) {
        return cooldownStartTimes[_staker];
    }

    ///@notice Get User reward Debt
    ///@param _benefiter Address of the _benefiter who get the reward
    ///@return Returns the reward debt of the user
    function getUserRewardDebt(
        address _benefiter
    ) external view returns (int256) {
        return userInfo[_benefiter].rewardDebt;
    }

    /// @notice Function to get Cool down Seconds
    /// @return Returns the cooldown seconds value
    function getCooldownSeconds() external view returns (uint256) {
        return COOLDOWN_SECONDS;
    }

    /// @notice Function to get unstake Window time
    /// @return return the untake window time in seconds
    function getUnstakeWindowTime() external view returns (uint256) {
        return UNSTAKE_WINDOW;
    }

    ///@notice get Accumulated reward per Share
    ///@return returns Accumulated reward per share
    function getAccRewardPerShare() external view returns (uint256) {
        return farmInfo.accRewardsPerShare;
    }

    ///@notice get the last reward time
    ///@return returns the last reward time
    function getLastRewardTime() external view returns (uint256) {
        return farmInfo.lastRewardTime;
    }

    ///@notice get rewards of the user
    ///@param _benefiter address of the _benefiter
    ///@return  pending returns  for the given _benefiter
    function getRewards(
        address _benefiter
    ) external view returns (uint256 pending) {
        FarmInfo memory farm = farmInfo;
        UserInfo storage user = userInfo[_benefiter];
        uint256 accRewardPerShare = farm.accRewardsPerShare; //0
        uint256 supply = totalSupply();
        if (block.timestamp > farm.lastRewardTime && supply != 0) {
            uint256 time = block.timestamp - farm.lastRewardTime;
            uint256 rewardAmount = time * rewardPerSecond;
            accRewardPerShare += (rewardAmount * ACC_REWARD_PRECISION) / supply;
        }

        int256 accumulatedReward = int256(
            (balanceOf(_benefiter) * accRewardPerShare) / ACC_REWARD_PRECISION
        );
        int256 rewardDebt = user.rewardDebt;
        if (userCleanMapping[_benefiter] != true) {
            rewardDebt = 0;
        }
        pending =
            uint256(accumulatedReward - rewardDebt) +
            pendingRewards[_benefiter];
    }

    /// @notice Function to get rewards per second
    /// @return returns the amount of rewardsPerSecond
    function getRewardPerSecond() external view returns (uint256) {
        return rewardPerSecond;
    }

    ///@notice function to get Sportsbook contract address
    /// @return address of the sportsbook contract
    function getSportsBookContract() external view returns (address) {
        return sportsBookContract;
    }

    function setSportsBookContract(
        address _sportsAddress
    ) external onlyRole(MANAGER_ROLE) {
        sportsBookContract = _sportsAddress;
    }

    ///@notice setUnstakeWindowTime function to set the unstake window time
    ///@param _unstakeWindow unstake window duration
    function setUnstakeWindowTime(
        uint256 _unstakeWindow
    ) external onlyRole(STAKING_MANAGER) {
        UNSTAKE_WINDOW = _unstakeWindow;
    }

    ///@notice function to set cooldown seconds
    ///@param _coolDownSeconds cooldown seconds value
    function setCooldownSeconds(
        uint256 _coolDownSeconds
    ) external onlyRole(STAKING_MANAGER) {
        COOLDOWN_SECONDS = _coolDownSeconds;
    }

    ///@notice updateFarm function refereshes the farm info
    ///@return farm of type FarmInfo
    function updateFarm() public returns (FarmInfo memory farm) {
        farm = farmInfo;
        if (farm.lastRewardTime < block.timestamp) {
            uint256 supply = totalSupply();
            if (supply > 0) {
                uint256 time = block.timestamp - farm.lastRewardTime;
                uint256 rewardAmount = time * rewardPerSecond;
                farm.accRewardsPerShare +=
                    (rewardAmount * ACC_REWARD_PRECISION) /
                    supply;
            }
            farm.lastRewardTime = block.timestamp;
            farmInfo = farm;
        }
    }

    ///@notice function sets the rewards per second
    ///@param _rewardPerSecond value of how many rewards to emit per second
    function setRewardPerSecond(
        uint256 _rewardPerSecond
    ) public onlyRole(STAKING_MANAGER) {
        updateFarm();
        rewardPerSecond = _rewardPerSecond;
        emit SetRewards(_rewardPerSecond);
    }

    ///@notice function to stake with out pre approval. User needs to sign on their wallet
    ///@param owner owner address
    ///@param spender token spender address
    ///@param value token value
    ///@param deadline deadline
    ///@param v v component of the signature
    ///@param r r component of the signature
    ///@param s s component of the signature
    ///@param onBehalfOf address of the user to stake the tokens on behalf of
    ///@param LFIamount Amount to stake
    function permitAndStake(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        address onBehalfOf,
        uint256 LFIamount
    ) external {
        require(owner != address(0), "HOUSEPOOL:Owner Address can't be zero");
        require(
            spender != address(0),
            "HOUSEPOOL:spender Address can't be zero"
        );
        require(
            onBehalfOf != address(0),
            "HOUSEPOOL:onBehalfOf Address can't be zero"
        );
        ILFIToken(STAKED_TOKEN).permit(
            owner,
            spender,
            value,
            deadline,
            v,
            r,
            s
        );
        stake(onBehalfOf, LFIamount);
    }

    ///@notice unstakeMax function unstake all maximum stake value from the contract
    function unstakeMax() public {
        int256 unstakeValue = getMaxWithdrawal(msg.sender);
        require(unstakeValue > 0, "INVALID AMOUNT");
        if (cooldownActive) {
            uint256 cooldownStartTimestamp = cooldownStartTimes[msg.sender];
            require(
                (block.timestamp) >
                    (cooldownStartTimestamp + (COOLDOWN_SECONDS)),
                "HOUSEPOOL:COOLDOWN_NOT_COMPLETE"
            );
            require(
                block.timestamp -
                    (cooldownStartTimestamp + (COOLDOWN_SECONDS)) <=
                    UNSTAKE_WINDOW,
                "HOUSEPOOL:UNSTAKE_WINDOW_FINISHED"
            );
        }

        int256 liquidityWithAdjustedME = ceil(
            (int256(totalValueLocked) - (voi.maxExposure)),
            int256(10 ** (pool_decimals * 2))
        );

        require(
            (int256(unstakeValue) <= liquidityWithAdjustedME),
            "Can't withdraw, not enough liquidity to cover me and amount"
        );
        uint256 userLPTokens = balanceOf(msg.sender);
        // Farm Related Logic
        farmUtil(userLPTokens);
        if (cooldownActive) {
            if (userLPTokens - (userLPTokens) == 0) {
                cooldownStartTimes[msg.sender] = 0;
            }
        }
        _burn(msg.sender, userLPTokens);
        liquidity -= uint256(unstakeValue);
        totalValueLocked =
            int256(liquidity) +
            (voi.expectedValue) -
            pendingStakes;

        if (totalSupply() == 0) {
            lpTokenPrice = initlpTokenPrice;
        } else {
            lpTokenPrice =
                (uint256(totalValueLocked) * 10 ** MAX_PRECISION) /
                totalSupply();
        }
        userEVTracker[msg.sender] = 0;

        bool success = ILFIToken(STAKED_TOKEN).transfer(
            msg.sender,
            uint256(unstakeValue)
        );

        require(success == true, "Transfer was not successful");
        emit UnStaked(msg.sender, msg.sender, uint256(unstakeValue));
        emit PoolAttributesUpdated(
            block.timestamp,
            runningTotalDeposits,
            poolName,
            liquidity,
            totalValueLocked,
            lpTokenPrice,
            pendingStakes,
            voi.expectedValue,
            voi.maxExposure
        );
    }

    ///@notice function to set the cooldownActive state
    ///param _active the value whether true/false to set the cooldown state to active or now
    function setCoolDownActiveState(
        bool _active
    ) external onlyRole(MANAGER_ROLE) {
        cooldownActive = _active;
    }

    ///@notice function to get the cooldownActiveState
    ///@return returns the state of the cooldown whether false or true.
    function getCoolDownActiveState() external view returns (bool) {
        return cooldownActive;
    }

    ///@notice function to activte the cooldown for the user
    function activateCooldown() external {
        if (cooldownActive) {
            require(
                balanceOf(msg.sender) != 0,
                "HOUSEPOOL:INVALID_BALANCE_ON_COOLDOWN"
            );
            //solium-disable-next-line
            cooldownStartTimes[msg.sender] = block.timestamp;
            emit CooldownActivated(msg.sender);
        }
    }

    ///@notice function to claim the rewards by the user
    ///@param to the address to which the rewards are tranferred to
    function claimRewards(address to) external {
        require(to != address(0), "HOUSEPOOL:to address can't be zero");
        cleanUserMapping();
        FarmInfo memory farm = updateFarm();
        UserInfo storage user = userInfo[msg.sender];
        int256 accumulatedReward = int256(
            (balanceOf(msg.sender) * farm.accRewardsPerShare) /
                ACC_REWARD_PRECISION
        );
        uint256 _pendingReward = uint256(accumulatedReward - user.rewardDebt) +
            pendingRewards[msg.sender];
        user.rewardDebt = accumulatedReward;
        pendingRewards[msg.sender] = 0;
        bool success = ILFIToken(STAKED_TOKEN).transfer(to, _pendingReward);
        if (success) {
            emit RewardsClaimed(msg.sender, to, _pendingReward);
        } else {
            revert();
        }
    }

    ///@notice getuserEVTrackerForTheUser function to get the  getuserEVTrackerForTheUser of the user
    ///@param _user address of the user
    ///@return returns getuserEVTrackerForTheUser of the user
    function getuserEVTrackerForTheUser(
        address _user
    ) external view returns (int256) {
        return userEVTracker[_user];
    }

    ///@notice getUserBets function to get the list of bets by the user
    ///@param _user address of the user
    ///@return returns user bets
    function getUserBets(
        address _user
    ) external view returns (uint256[] memory) {
        return userBets[_user];
    }

    ///@notice getBetInfoByID function to get betInfo
    ///@param _ID bet ID
    ///@return returns the betting infomation
    function getBetInfoByID(
        uint256 _ID
    )
        external
        view
        returns (bool, address, uint256, uint256, uint256, uint256, uint256)
    {
        return (
            betInfoWithId[_ID].parlay,
            betInfoWithId[_ID].user,
            betInfoWithId[_ID].Id,
            betInfoWithId[_ID].amount,
            betInfoWithId[_ID].result,
            betInfoWithId[_ID].payout,
            betInfoWithId[_ID].commission
        );
    }

    ///@notice getEV function to return the maxExposure
    ///@return returns expectedValue
    function getEV() external view returns (int256) {
        return voi.expectedValue;
    }

    ///@notice getMaxExposure function to return the maxExposure
    ///@return returns max exposure
    function getMaxExposure() external view returns (int256) {
        return voi.maxExposure;
    }

    ///@notice getMyLiquidity function to return the liquidity provided by the user
    ///@param _user user address
    ///@return return the liquidity
    function getMyLiquidity(address _user) external view returns (uint256) {
        return (balanceOf(_user) * lpTokenPrice) / 10 ** MAX_PRECISION;
    }

    ///@notice setVOI function to set the voi
    ///@param sig_ signature of the authorized user
    ///@param voi_ voi
    function setVOI(
        bytes memory sig_,
        ValuesOfInterest memory voi_
    ) external onlyValid(voi_, sig_) onlyRole(DATA_PROVIDER_ORACLE) {
        _setVoi(voi_);
    }

    ///@notice storeBets function to store the bets placed
    ///@param betinformation information of the bets to be placed
    function storeBets(
        BetInfo[] memory betinformation
    ) external onlyRole(HOUSE_POOL_DATA_PROVIDER) {
        uint256 tempPendingStakes;
        for (uint256 i = 0; i < betinformation.length; i++) {
            tempPendingStakes += (betinformation[i].amount -
                betinformation[i].commission);
            betInfoWithId[betinformation[i].Id].parlay = betinformation[i]
                .parlay;
            betInfoWithId[betinformation[i].Id].user = betinformation[i].user;
            betInfoWithId[betinformation[i].Id].Id = betinformation[i].Id;
            betInfoWithId[betinformation[i].Id].amount = betinformation[i]
                .amount;
            betInfoWithId[betinformation[i].Id].result = betinformation[i]
                .result;
            betInfoWithId[betinformation[i].Id].payout = betinformation[i]
                .payout;
            betInfoWithId[betinformation[i].Id].commission = betinformation[i]
                .commission;
            userBets[betinformation[i].user].push(betinformation[i].Id);
        }
        pendingStakes += int256(tempPendingStakes);
        liquidity += tempPendingStakes;
        updateAttributes();
    }

    ///@notice updateBets function to update the bet information
    ///@param _Id, bet ids
    ///@param _payout payout amount of the respective betIDs
    function updateBets(
        uint256[] memory _Id,
        uint256[] memory _payout
    ) external onlyRole(HOUSE_POOL_DATA_PROVIDER) {
        require(_Id.length == _payout.length, "Invalid bets");
        for (uint256 i = 0; i < _Id.length; i++) {
            if (betInfoWithId[i].parlay) {
                betInfoWithId[_Id[i]].payout = _payout[i];
            }
        }
    }

    ///@notice settleBets function to settle bets
    ///@param _Id, bet Ids
    ///@param _result result of the respective betIDs
    function settleBets(
        uint256[] memory _Id,
        uint256[] memory _result
    ) external onlyRole(HOUSE_POOL_DATA_PROVIDER) {
        require(_Id.length == _result.length, "Invalid bets");
        for (uint256 i = 0; i < _Id.length; i++) {
            uint256 netAmount = (betInfoWithId[_Id[i]].amount -
                betInfoWithId[_Id[i]].commission);
            betInfoWithId[_Id[i]].result = _result[i];
            if (_result[i] == 1) {
                // when user wins
                liquidity -= (betInfoWithId[_Id[i]].payout);
                pendingStakes -= int256(netAmount);
                bool success = STAKED_TOKEN.transfer(
                    sportsBookContract,
                    betInfoWithId[_Id[i]].payout
                );
                if (success) {
                    updateAttributes();
                } else {
                    revert();
                }
            } else if (_result[i] == 3) {
                // when its a draw
                bool success = STAKED_TOKEN.transfer(
                    sportsBookContract,
                    (netAmount)
                );
                if (success) {
                    pendingStakes -= int256(netAmount);
                    liquidity -= (netAmount);
                    updateAttributes();
                } else {
                    revert();
                }
            } else if (_result[i] == 2) {
                // when user loses
                pendingStakes -= int256(netAmount);
                updateAttributes();
            }
            emit BetSettled(_Id[i], _result[i]);
        }
    }

    ///@notice calculateNewEVValue function calculates the new Ev value for a user.
    ///@param _newAmount Amount the user is staking
    ///@param _newEV new EV value
    ///@param _toUser address of the user to whom the new EV value is calculated.
    ///@return returns the ev value for new user
    function calculateNewEVValue(
        uint256 _newAmount,
        int256 _newEV,
        address _toUser
    ) public view returns (int256) {
        int256 newEVForUser = ((int256(_newAmount) * _newEV) +
            (int256(balanceOf(_toUser)) * userEVTracker[_toUser])) /
            int256((_newAmount + balanceOf(_toUser)));
        return newEVForUser;
    }

    ///@notice function to stake the amount of tokens
    ///@param onBehalfOf address of the user to send the tokens to
    ///@param amount amount of tokens to be staked
    function stake(address onBehalfOf, uint256 amount) public {
        require(
            amount > 1 && amount <= STAKED_TOKEN.balanceOf(msg.sender),
            "INVALID AMOUNT"
        );
        require(onBehalfOf != address(0), "onBehalOf Address can't be zero");
        uint256 lpTokensToMint = (amount * 10 ** MAX_PRECISION) / lpTokenPrice;
        // toBalance will be used to calculate new coolddown timestamp
        uint256 toBalance = balanceOf(onBehalfOf);
        // proportionally adjust user EV value
        userEVTracker[msg.sender] = calculateNewEVValue(
            lpTokensToMint,
            voi.expectedValue,
            msg.sender
        );
        farmUtil(lpTokensToMint);
        _mint(onBehalfOf, lpTokensToMint);
        liquidity += amount;
        updateAttributes();

        if (cooldownActive) {
            cooldownStartTimes[onBehalfOf] = getNextCooldownTimestamp(
                0,
                lpTokensToMint,
                onBehalfOf,
                toBalance
            );
        }
        bool success = ILFIToken(STAKED_TOKEN).transferFrom(
            msg.sender,
            address(this),
            amount
        );
        require(success == true, "Transfer was not successful");
        emit Staked(msg.sender, onBehalfOf, amount);
    }

    ///@notice function to unstake the tokens
    ///@param to address to which the unstaked tokens are returned
    ///@param amount amount of tokens to unstake
    function unStake(address to, uint256 amount) public {
        require(amount > 0, "INVALID AMOUNT");
        if (cooldownActive) {
            uint256 cooldownStartTimestamp = cooldownStartTimes[msg.sender];
            require(
                (block.timestamp) >
                    (cooldownStartTimestamp + (COOLDOWN_SECONDS)),
                "HOUSEPOOL:COOLDOWN_NOT_COMPLETE"
            );
            require(
                block.timestamp -
                    (cooldownStartTimestamp + (COOLDOWN_SECONDS)) <=
                    UNSTAKE_WINDOW,
                "HOUSEPOOL:UNSTAKE_WINDOW_FINISHED"
            );
        }

        int256 liquidityWithAdjustedME = ceil(
            (int256(totalValueLocked) - (voi.maxExposure)),
            int256(10 ** (pool_decimals * 2))
        );
        int256 maxUserWithdrawalAmount = getMaxWithdrawal(msg.sender);

        require(
            (int256(amount) <= liquidityWithAdjustedME),
            "Can't withdraw, not enough liquidity to cover me and amount"
        );

        if (int256(amount) == maxUserWithdrawalAmount) {
            unstakeMax();
        } else {
            uint256 tokensToBurn = (amount * 10 ** MAX_PRECISION) /
                lpTokenPrice;
            // Farm Related Logic
            uint256 balanceOfMessageSender = balanceOf(msg.sender);
            farmUtil(tokensToBurn);

            if (cooldownActive) {
                if (balanceOfMessageSender - (tokensToBurn) == 0) {
                    cooldownStartTimes[msg.sender] = 0;
                }
            }
            _burn(msg.sender, tokensToBurn);
            liquidity -= amount;
            totalValueLocked =
                int256(liquidity) +
                (voi.expectedValue) -
                pendingStakes;
            if (totalSupply() == 0) {
                //lpTokenPrice = 1000 * 10**MAX_PRECISION; // go with init price
                lpTokenPrice = initlpTokenPrice;
            } else {
                lpTokenPrice =
                    (uint256(totalValueLocked) * 10 ** MAX_PRECISION) /
                    totalSupply();
            }

            bool success = ILFIToken(STAKED_TOKEN).transfer(to, amount);

            require(success == true, "Transfer was not successful");
            emit UnStaked(msg.sender, to, amount);
            emit PoolAttributesUpdated(
                block.timestamp,
                runningTotalDeposits,
                poolName,
                liquidity,
                totalValueLocked,
                lpTokenPrice,
                pendingStakes,
                voi.expectedValue,
                voi.maxExposure
            );
        }
    }

    ///@notice function to withdraw the funds to treasury. Only Manager will be able to call this function.
    ///@param _withdrawalAmount Amount to be withdrawn

    function withdrawToTreasury(
        uint256 _withdrawalAmount
    ) external onlyRole(MANAGER_ROLE) {
        uint256 maxWithdrawalToTreasury = TreasuryAmountWithdrawal();
        require(
            _withdrawalAmount <= maxWithdrawalToTreasury,
            "Not allowed amount"
        );
        bool success = ILFIToken(STAKED_TOKEN).transfer(
            treasury,
            _withdrawalAmount
        );
        require(success == true, "Not successful");
        emit TreasuryWithdrawal(_withdrawalAmount);
    }

    ///@notice getMaxWithdrawal function take user address and calculate the maximum tokens that the user can withdraw
    /// @param _user address of the user.
    ///@return returns the maximum amount to withdraw
    function getMaxWithdrawal(address _user) public view returns (int256) {
        int256 userShare = int256(
            ((balanceOf(_user) * 10 ** pool_decimals) / totalSupply())
        );
        int256 maxUserWithdrawalAmount;
        if (
            ((userShare * voi.expectedValue)) < userShare * userEVTracker[_user]
        ) {
            maxUserWithdrawalAmount =
                ((userShare) * int256(totalValueLocked)) /
                int256(10 ** pool_decimals);
        } else {
            maxUserWithdrawalAmount = ((userShare *
                (int256(totalValueLocked) - voi.expectedValue)) /
                int256(10 ** pool_decimals) +
                (userShare * userEVTracker[_user]) /
                int256(10 ** pool_decimals));
        }

        if (maxUserWithdrawalAmount >= int256(liquidity)) {
            maxUserWithdrawalAmount = int256(liquidity);
        }
        return maxUserWithdrawalAmount;
    }

    ///@notice farmUtil internal function call
    function cleanUserMapping() internal {
        if (userCleanMapping[msg.sender] != true) {
            userInfo[msg.sender].amount = balanceOf(msg.sender);
            userInfo[msg.sender].rewardDebt = 0;
            userCleanMapping[msg.sender] = true;
        }
    }

    ///@notice getNextCooldownTimestamp function to get the next cooldown start timestamp of the user
    ///@param userCooldownTimestamp current timestamp
    ///@param amountToReceive amount of new LP tokens being minted
    ///@param toAddress receiver of the stake benefits
    ///@param toBalance LpToken balance before minting new tokens
    function getNextCooldownTimestamp(
        uint256 userCooldownTimestamp,
        uint256 amountToReceive,
        address toAddress,
        uint256 toBalance
    ) public view returns (uint256) {
        uint256 toCooldownTimestamp = cooldownStartTimes[toAddress];
        // Data clean up step, for corrupt timestamps
        if (toCooldownTimestamp > 36322041600) {
            return 0;
        }
        // Coold down is not active, no need to adjust the cooldown timestamp
        if (toCooldownTimestamp == 0) {
            return 0;
        }
        // Cooldown is active, assess if cooldwon needs to be adjusted
        // minimalValidCooldownTimestamp is the timestamp which can potentially be used to unstake
        uint256 minimalValidCooldownTimestamp = ((block.timestamp -
            COOLDOWN_SECONDS) - (UNSTAKE_WINDOW));
        // if user's timestamp is more than minimalValidCooldownTimestamp
        // that means there is no need to adjust the cooldown timestamp
        // as it has either already been used or the window has passed
        if (minimalValidCooldownTimestamp > toCooldownTimestamp) {
            toCooldownTimestamp = 0;
        } else {
            // landing here means the cooldown timestamp is still valid
            // it will need to be adjusted proportionally to the amount being staked
            // If from user's cooldown timestamp is more than minimalValidCooldownTimestamp
            // it means from user's cooldown timestamp has already been used or passed
            // But the to user's cooldown timestamp is still valid so needs to be adjusted
            // ------------
            // so instead of using the expired userCooldownTimestamp we use the current block timestamp
            // to calculate the new cooldown timestamp
            uint256 fromCooldownTimestamp = (minimalValidCooldownTimestamp >
                userCooldownTimestamp)
                ? block.timestamp
                : userCooldownTimestamp;
            // If we assigned block.timestamp to fromCooldownTimestamp
            // then it will never be less than toCooldownTimestamp(if it has a value)
            if (fromCooldownTimestamp < toCooldownTimestamp) {
                return toCooldownTimestamp;
            } else {
                // Propporational adjustment of cooldown timestamp proportionally to the amount being staked
                // to calculate the new cooldown timestamp we use the following formula
                toCooldownTimestamp =
                    (amountToReceive *
                        (fromCooldownTimestamp) +
                        (toBalance * (toCooldownTimestamp))) /
                    (amountToReceive + (toBalance));
            }
        }
        return toCooldownTimestamp;
    }

    ///@notice internal transfer function used by transfer function of ERC20
    ///@param from address of the sender
    ///@param to address of the receiver
    ///@param amount amount to transfer
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        uint256 balanceOfSender = balanceOf(from);
        FarmInfo memory farm = updateFarm();
        // Sender
        UserInfo storage sender = userInfo[from];
        sender.rewardDebt -= int256(
            (amount * farm.accRewardsPerShare) / ACC_REWARD_PRECISION
        );
        sender.amount -= amount;

        // Recipient
        if (from != to) {
            uint256 balanceOfReceiver = balanceOf(to);
            UserInfo storage receiver = userInfo[to];
            receiver.rewardDebt += int256(
                (amount * farm.accRewardsPerShare) / ACC_REWARD_PRECISION
            );
            receiver.amount += amount;
            userEVTracker[to] = calculateNewEVValue(
                amount,
                userEVTracker[from],
                to
            );
            uint256 senderCooldown;
            if (cooldownActive) {
                senderCooldown = cooldownStartTimes[from];
                cooldownStartTimes[to] = getNextCooldownTimestamp(
                    senderCooldown,
                    amount,
                    to,
                    balanceOfReceiver
                );
            }

            // if cooldown was set and whole balance of sender was transferred - clear cooldown
            if (balanceOfSender == amount && senderCooldown != 0) {
                cooldownStartTimes[from] = 0;
            }
        }
        super._transfer(from, to, amount);
    }

    ///@notice _afterTokenTransfer function is called after every transfer
    ///@param from address of the sender
    ///@param to address of the token receiver
    ///@param amount amount to transfer
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override(ERC20Upgradeable, ERC20VotesUpgradeable) {
        super._afterTokenTransfer(from, to, amount);
    }

    ///@notice _mint internal function to mint the tokens
    ///@param to address to mint the tokens to
    ///@param amount amount of token to mint
    function _mint(
        address to,
        uint256 amount
    ) internal override(ERC20Upgradeable, ERC20VotesUpgradeable) {
        super._mint(to, amount);
    }

    ///@notice function to create a new Farm
    function createFarm() internal {
        farmInfo = FarmInfo({
            accRewardsPerShare: 0,
            lastRewardTime: block.timestamp
        });
    }

    ///@notice _burn internal function  to burn the tokens
    ///@param account address to burn the token from
    ///@param amount amount to tokens to burn
    function _burn(
        address account,
        uint256 amount
    ) internal override(ERC20Upgradeable, ERC20VotesUpgradeable) {
        super._burn(account, amount);
    }

    ///@notice updateAttributed internal function to update the bet attributes once the bet is placed
    function updateAttributes() internal {
        totalValueLocked =
            int256(liquidity) +
            (voi.expectedValue) -
            pendingStakes;
        lpTokenPrice =
            (uint256(totalValueLocked) * 10 ** MAX_PRECISION) /
            totalSupply();
        emit PoolAttributesUpdated(
            block.timestamp,
            runningTotalDeposits,
            poolName,
            liquidity,
            totalValueLocked,
            lpTokenPrice,
            pendingStakes,
            voi.expectedValue,
            voi.maxExposure
        );
    }

    ///@notice internal function to update TVL whenever new ev is updated
    ///@param _expectedValue new ev value
    function _updateTVL(int256 _expectedValue) internal {
        //TVL += expectedValue; // TVL also should be in base units and currency dependent
        totalValueLocked = int256(liquidity) + _expectedValue - pendingStakes;
    }

    ///@notice internal function to set VOI
    ///@param _voi me and ev are passed
    function _setVoi(ValuesOfInterest memory _voi) internal {
        if (_voi.expectedValue != voi.expectedValue) {
            _setEV(_voi.expectedValue);
        }
        if (_voi.maxExposure != voi.maxExposure) {
            _setME(_voi.maxExposure);
        }
    }

    ///@notice internal function to set Maximum exposure
    ///@param _exposure new exposure value to set
    function _setME(int256 _exposure) internal {
        voi.maxExposure = _exposure;
    }

    ///@notice internal function to set EV
    ///@param _newEV new ev value
    function _setEV(int256 _newEV) internal {
        _updateTVL(_newEV);
        voi.expectedValue = _newEV;
        updateAttributes();
    }

    ///@notice internal function to ceil
    ///@param a value to ceil
    ///@param m number of zeros to ceil with.
    ///@return returns a ceiled value
    function ceil(int256 a, int256 m) internal pure returns (int256) {
        return ((a + m - 1) / m) * m;
    }

    ///@notice farmUtil internal function call
    ///@param _amount amount
    function farmUtil(uint256 _amount) internal {
        // Farm Related Logic
        cleanUserMapping();
        FarmInfo memory farm = updateFarm();
        UserInfo storage user = userInfo[msg.sender];
        if (balanceOf(msg.sender) > 0) {
            uint256 pending = uint256(
                int256(
                    (balanceOf(msg.sender) * farm.accRewardsPerShare) /
                        ACC_REWARD_PRECISION
                ) - user.rewardDebt
            );
            if (pending > 0) {
                pendingRewards[msg.sender] += pending;
            }
        }
        user.rewardDebt = int256(
            ((balanceOf(msg.sender)) * farm.accRewardsPerShare) /
                ACC_REWARD_PRECISION
        );
    }

    ///@notice Function calculates the amount of liqudity that treasury can withdraw
    function TreasuryAmountWithdrawal() internal view returns (uint256) {
        return ((30 * liquidity) / 100);
    }

    // *********************************************************************************************************************************
}
