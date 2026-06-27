// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

/**
 * @title Grizzifi - Honeycomb Wealth Plan – Powered by DeFi
 * @dev USDT-based multi-plan staking with referral system
 */
contract Grizzifi {
    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    IERC20 public immutable USDT;

    struct Plan {
        uint256 dailyReturn;
        uint256 minDeposit;
        uint256 lockPeriod;
        bool isActive;
    }

    struct Investment {
        uint256 planId;
        uint256 amount;
        uint256 startTime;
        uint256 lastClaimTime;
        uint256 totalClaimed;
        bool capitalWithdrawn;
        address referrer;
    }

    struct User {
        Investment[] investments;
        uint256 totalInvested;
        uint256 totalEarned;
        uint256 totalReferralEarned;
        uint256 claimableReferralBonus;
        uint256 totalReferralBonusWithdrawn;
        address referrer;
        uint256 referralCount;
        mapping(uint256 => uint256) levelReferrals;
        address[] directReferrals;
        uint256 milestoneReward;
        uint256 milestoneIndex;
        uint256 teamsCount;
        uint256 directCount;
        mapping(address => bool) inTeam;
        bool inDirect;
        uint256 totalMilestoneEarned;  // New
    }

    mapping(address => User) public users;
    mapping(address => bool) public registered;
    mapping(uint256 => Plan) public plans;

    uint256 public totalPlans = 8;
    uint256 public totalInvested;
    uint256 public totalUsers;
    uint256 public totalPayouts;
    uint256 public platformFee = 1000;
    uint256 public startUNIX;

    uint256[] public referralRates = [2000, 1000, 500, 500, 500, 500, 500, 300, 300, 300, 100, 100, 100, 100, 100, 100, 100];

    uint256[] public teamMilestones = [
        20, 50, 100, 200, 500, 1000, 3000, 6000, 10000,
        30000];

    uint256[] public rewardAmounts = [
        50 * 1e18 , 120 * 1e18, 220 * 1e18,
        440 * 1e18, 800 * 1e18, 1600 * 1e18, 2500 * 1e18,
        4500 * 1e18, 7500 * 1e18, 15000 * 1e18
    ];
    uint256 public minInvestForMilestone = 10 * 1e18; // e.g., $10
    uint256 public minDirect = 2; // e.g., needs 2 direct referrals to qualify
    uint256 private constant TOTAL_REFERRAL_LEVELS = 17;

    event NewInvestment(address indexed user, uint256 planId, uint256 amount, address referrer);
    event RewardsClaimed(address indexed user, uint256 amount);
    event CapitalWithdrawn(address indexed user, uint256 planId, uint256 amount);
    event ReferralBonusAccrued(address indexed referrer, address indexed fromUser, uint256 level, uint256 amount);
    event ReferralBonusClaimed(address indexed user, uint256 amount);
    event MilestoneAchieved(address indexed upline,uint256 milestoneIndex,uint256 reward);

    constructor(address _usdtAddress) {
        require(_usdtAddress != address(0), "Invalid USDT address");
        USDT = IERC20(_usdtAddress);
        owner = msg.sender;
        plans[0] = Plan(80, 10 * 10**18, 7, true);
        plans[1] = Plan(100, 50 * 10**18, 14, true);
        plans[2] = Plan(120, 100 * 10**18, 30, true);
        plans[3] = Plan(140, 500 * 10**18, 60, true);
        plans[4] = Plan(160, 2500 * 10**18, 90, true);
        plans[5] = Plan(180, 5000 * 10**18, 120, true);
        plans[6] = Plan(200, 10000 * 10**18, 150, true);
        plans[7] = Plan(220, 25000 * 10**18, 180, true);
    }
    /**
     * @dev Investment function - allows users to harvestHoney USDT in a specific plan
     * @param _planId ID of the investment plan (0-7 after Micro plan removal)
     * @param _amount Amount of USDT to invest
     * @param _referrer Address of the referrer (can be zero address)
     * @notice Users transfer USDT to invest in chosen plan, referrer gets commission
     * Requirements:
     * - Plan must exist and be active
     * - Investment amount must meet minimum deposit
     * - Valid referrer address (if provided)
     * - User must have approved USDT transfer
     */
     
    function harvestHoney(uint256 _planId, uint256 _amount, address _referrer) external {
        require(startUNIX > 0, "We are not live yet!");
        require(_planId < totalPlans, "Invalid plan ID");
        require(plans[_planId].isActive, "Plan not active");
        require(_amount >= plans[_planId].minDeposit, "Below minimum");
        require(_amount > 0, "Amount must be > 0");

        if (!registered[msg.sender]) {
            registered[msg.sender] = true;
            totalUsers++;

            if (_referrer != address(0) && _referrer != msg.sender && registered[_referrer]) {
                users[msg.sender].referrer = _referrer;
                users[_referrer].referralCount++;
                users[_referrer].directReferrals.push(msg.sender);
                _updateReferralCounts(_referrer);
            }
        }
         if (_amount >= minInvestForMilestone) {
            _incrementUplineTeamCount(msg.sender);
        }

        uint256 feeAmount = (_amount * platformFee) / 10000;
        require(USDT.transferFrom(msg.sender, address(this), _amount), "USDT transfer failed");

        if (feeAmount > 0) {
            require(USDT.transfer(owner, feeAmount), "Fee transfer failed");
        }

        Investment memory newInv = Investment({
            planId: _planId,
            amount: _amount,
            startTime: block.timestamp,
            lastClaimTime: block.timestamp,
            totalClaimed: 0,
            capitalWithdrawn: false,
            referrer: users[msg.sender].referrer
        });

        users[msg.sender].investments.push(newInv);
        users[msg.sender].totalInvested += _amount;
        totalInvested += _amount;

        emit NewInvestment(msg.sender, _planId, _amount, users[msg.sender].referrer);
    }

   function collectHoney(uint256 _planId) external  {
            require(_planId < totalPlans, "Grizzifi: Invalid plan ID");
            User storage user = users[msg.sender];
            uint256 totalReward = 0;
            uint256 investmentCount = user.investments.length;

            for (uint256 i = 0; i < investmentCount; i++) {
                Investment storage investment = user.investments[i];

                // Skip if investment is in a different plan or capital already withdrawn
                if (investment.planId != _planId || investment.capitalWithdrawn) {
                    continue;
                }

                uint256 reward = calculateHoney(msg.sender, i);

                if (reward > 0) {
                    // Update investment stats
                    investment.lastClaimTime = block.timestamp;
                    investment.totalClaimed += reward;

                    totalReward += reward;
                }
            }

            require(totalReward > 0, "Grizzifi: No rewards available");

            // Update user/global stats
            user.totalEarned += totalReward;
            totalPayouts += totalReward;

            // Pay referral commissions (note: _payReferralCommissions accrues it, not transfers)
            _payReferralCommissions(msg.sender, totalReward);

            // Transfer total reward to user
            require(USDT.balanceOf(address(this)) >= totalReward, "Grizzifi: Insufficient contract balance");
            bool success = USDT.transfer(msg.sender, totalReward);
            require(success, "Grizzifi: Reward transfer failed");

            emit RewardsClaimed(msg.sender, totalReward);
        }
    
   
    function retrieveHoneyPot(uint256 _planId) external  {
    require(_planId < totalPlans, "Grizzifi: Invalid plan ID");
    User storage user = users[msg.sender];
    uint256 totalToWithdraw = 0;
    uint256 rewardTotal = 0;
    uint256 investmentCount = user.investments.length;

    for (uint256 i = 0; i < investmentCount; i++) {
        Investment storage investment = user.investments[i];

        // Skip if not matching plan or already withdrawn
        if (investment.planId != _planId || investment.capitalWithdrawn) continue;

        // Check if lock period has expired
        uint256 lockEndTime = investment.startTime + (plans[_planId].lockPeriod * 1 days);
        if (block.timestamp < lockEndTime) continue;

        // Calculate reward
        uint256 reward = calculateHoney(msg.sender, i);
        if (reward > 0) {
            investment.totalClaimed += reward;
            rewardTotal += reward;
            users[msg.sender].totalEarned += reward;
            totalPayouts += reward;
            _payReferralCommissions(msg.sender, reward);
        }

        // Mark as withdrawn and update
        investment.capitalWithdrawn = true;
        investment.lastClaimTime = block.timestamp;

        // Add original capital to total
        totalToWithdraw += investment.amount;
    }

    uint256 finalAmount = totalToWithdraw + rewardTotal;
    require(finalAmount > 0, "Grizzifi: No capital available for withdrawal");
    require(USDT.balanceOf(address(this)) >= finalAmount, "Grizzifi: Insufficient contract balance");

    bool success = USDT.transfer(msg.sender, finalAmount);
    require(success, "Grizzifi: Withdrawal transfer failed");

    emit CapitalWithdrawn(msg.sender, _planId, finalAmount);
    if (rewardTotal > 0) {
        emit RewardsClaimed(msg.sender, rewardTotal);
    }
}

    
    /**
     * @dev Calculate available rewards for a specific investment
     * @param _user Address of the user
     * @param _investmentIndex Index of the investment
     * @return rewardAmount Available reward amount in wei
     * @notice Calculates rewards based on time elapsed since last claim
     */
    function calculateHoney(address _user, uint256 _investmentIndex) public view returns (uint256) {
        if (_investmentIndex >= users[_user].investments.length) return 0;
        
        Investment memory investment = users[_user].investments[_investmentIndex];
        if (investment.capitalWithdrawn) return 0;
        
        Plan memory plan = plans[investment.planId];
        
        uint256 timeDiff = block.timestamp - investment.lastClaimTime;
        uint256 dailyReward = (investment.amount * plan.dailyReturn) / 10000; // Convert basis points
        uint256 rewardAmount = (dailyReward * timeDiff) / 1 days;
        
        // Rewards accrue indefinitely until capital is withdrawn.
        // The lock period only gatekeeps capital withdrawal, not reward accrual.
        // Therefore, the capping logic previously here is removed.
        
        return rewardAmount;
    }
    
    /**
     * @dev Get user's total available rewards across all investments
     * @param _user Address of the user
     * @return totalRewards Total claimable rewards in wei
     */
    function getTotalHoney(address _user) external view returns (uint256) {
        uint256 totalRewards = 0;
        uint256 investmentCount = users[_user].investments.length;
        
        for (uint256 i = 0; i < investmentCount; i++) {
            totalRewards += calculateHoney(_user, i);
        }
        return totalRewards;
    }
    
    /**
     * @dev Get user's investment count
     * @param _user Address of the user
     * @return count Number of investments made by user
     */
    function getUserInvestmentCount(address _user) external view returns (uint256) {
        return users[_user].investments.length;
    }
    
    function getUserInvestment(address _user, uint256 _index) external view returns (
        uint256 planId,
        uint256 amount,
        uint256 startTime,
        uint256 lastClaimTime,
        uint256 totalClaimed,
        bool capitalWithdrawn,
        address referrer
    ) {
        require(_index < users[_user].investments.length, "Grizzifi: Invalid index");
        Investment memory investment = users[_user].investments[_index];
        return (
            investment.planId,
            investment.amount,
            investment.startTime,
            investment.lastClaimTime,
            investment.totalClaimed,
            investment.capitalWithdrawn,
            investment.referrer
        );
    }


function getHiveStats(address _user, uint256 _planId) external view returns (
    uint256 availableReward,
    uint256 availableCapital,
    uint256 capitalInvested,
    uint256 activePlanCount,
    uint256 dailyEarning,
    uint256 totalWithdrawn
) {
    require(_planId < totalPlans, "Grizzifi: Invalid plan ID");

    User storage user = users[_user];
    Plan storage plan = plans[_planId]; // ✅ fix: store once to save stack
    uint256 investmentCount = user.investments.length;

    uint256 totalActiveAmount;

    for (uint256 i = 0; i < investmentCount; i++) {
        Investment storage inv = user.investments[i];

        if (inv.planId != _planId) continue;

     
        totalWithdrawn += inv.totalClaimed;

        if (inv.capitalWithdrawn) {
            totalWithdrawn += inv.amount;
        } else {
            activePlanCount++;
            capitalInvested += inv.amount;
            uint256 reward = calculateHoney(_user, i);
            availableReward += reward;

            // ✅ fix: use `plan` reference instead of `plans[_planId]`
            if (block.timestamp >= inv.startTime + (plan.lockPeriod * 1 days)) {
                availableCapital += inv.amount;
            }

            totalActiveAmount += inv.amount;
        }
    }

    dailyEarning = (totalActiveAmount * plan.dailyReturn) / 10000;
}

    /**
     * @dev Get user's investment-based referral level access
     * @param _user Address of the user
     * @return maxLevels Maximum referral levels user can earn from based on the sum of their active investments
     */
    function getUserReferralLevels(address _user) public view returns (uint256) {
        uint256 currentActiveInvestmentSum = 0;
        uint256 investmentCount = users[_user].investments.length;
        for (uint256 i = 0; i < investmentCount; i++) {
            if (!users[_user].investments[i].capitalWithdrawn) {
                currentActiveInvestmentSum += users[_user].investments[i].amount;
            }
        }

        // If no active investments or sum is less than the first tier, 0 levels.
        if (currentActiveInvestmentSum < 5 * 10**18) { // Minimum threshold for any level is $5
            return 0;
        }
        
        // Referral level unlock criteria based on the SUM OF ACTIVE investments
        // Max 17 levels, with the 17th level unlocking at $1000 USDT active sum
        if (currentActiveInvestmentSum >= 1000 * 10**18) return 17; // $1000+ USDT
        if (currentActiveInvestmentSum >= 900 * 10**18) return 16;  // $900+ USDT
        if (currentActiveInvestmentSum >= 800 * 10**18) return 15;  // $800+ USDT
        if (currentActiveInvestmentSum >= 700 * 10**18) return 14;  // $700+ USDT
        if (currentActiveInvestmentSum >= 600 * 10**18) return 13;  // $600+ USDT
        if (currentActiveInvestmentSum >= 550 * 10**18) return 12;  // $550+ USDT
        if (currentActiveInvestmentSum >= 500 * 10**18) return 11;  // $500+ USDT
        if (currentActiveInvestmentSum >= 450 * 10**18) return 10;  // $450+ USDT
        if (currentActiveInvestmentSum >= 400 * 10**18) return 9;   // $400+ USDT
        if (currentActiveInvestmentSum >= 350 * 10**18) return 8;   // $350+ USDT
        if (currentActiveInvestmentSum >= 300 * 10**18) return 7;   // $300+ USDT
        if (currentActiveInvestmentSum >= 250 * 10**18) return 6;   // $250+ USDT
        if (currentActiveInvestmentSum >= 200 * 10**18) return 5;   // $200+ USDT
        if (currentActiveInvestmentSum >= 150 * 10**18) return 4;   // $150+ USDT
        if (currentActiveInvestmentSum >= 100 * 10**18) return 3;   // $100+ USDT
        if (currentActiveInvestmentSum >= 50 * 10**18) return 2;    // $50+ USDT
        // The check for currentActiveInvestmentSum >= 5 * 10**18 is implicitly handled by the first check.
        // If it passed the initial currentActiveInvestmentSum < 5 * 10**18, it means it's >= 5.
        return 1; // If >= $5 but less than $50
    }
    
    function _payReferralCommissions(address _user, uint256 _amount) internal {
        address referrer = users[_user].referrer;
        
        for (uint256 i = 0; i < referralRates.length && referrer != address(0); i++) {
            uint256 referrerMaxLevels = getUserReferralLevels(referrer);
            
            // Only pay commission if referrer's investment level allows this generation
            if ((i + 1) <= referrerMaxLevels) {
                uint256 commission = (_amount * referralRates[i]) / 10000;
                
                if (commission > 0) { // No need to check contract balance here, only on actual withdrawal
                    users[referrer].totalReferralEarned += commission; // Still tracks total earned
                    users[referrer].claimableReferralBonus += commission; // Accrue to claimable balance
                    emit ReferralBonusAccrued(referrer, _user, i + 1, commission);
                }
            }
            
            referrer = users[referrer].referrer;
        }
    }
    

    /**
     * @dev Update referral counts for all levels when new user joins
     * @param _referrer Address of the direct referrer
     * @notice Updates referral counts up the chain for analytics
     */
    function _updateReferralCounts(address _referrer) internal {
        address current = _referrer;
        
        for (uint256 i = 0; i < referralRates.length && current != address(0); i++) {
            users[current].levelReferrals[i]++;
            current = users[current].referrer;
        }
    }

    /**
     * @dev Allows a user to claim their accrued referral bonuses.
     * @notice Transfers the user's claimable referral bonus amount to their wallet.
     */
        function collectRefBonus() external {
            User storage user = users[msg.sender];
            uint256 referralAmount = user.claimableReferralBonus;
            uint256 milestoneAmount = user.milestoneReward;
            uint256 totalToClaim = referralAmount + milestoneAmount;

            require(totalToClaim > 0, "Grizzifi: No referral or milestone bonuses to claim");
            require(USDT.balanceOf(address(this)) >= totalToClaim, "Grizzifi: Insufficient contract balance");

            // Reset
            user.claimableReferralBonus = 0;
            user.milestoneReward = 0;
            user.totalReferralBonusWithdrawn += totalToClaim;
            totalPayouts += totalToClaim;

            require(USDT.transfer(msg.sender, totalToClaim), "Grizzifi: Bonus transfer failed");

            emit ReferralBonusClaimed(msg.sender, totalToClaim);
        }

    /**
     * @dev Get contract USDT balance
     * @return balance Current USDT balance of the contract
     */
    function getContractBalance() external view returns (uint256) {
        return USDT.balanceOf(address(this));
    }
    
    /**
     * @dev Get USDT token address
     * @return usdtAddress Address of the USDT token contract
     */
    function getUSDTAddress() external view returns (address) {
        return address(USDT);
    }
    /**
     * @dev Get platform statistics
     * @return plans Total number of plans
     * @return users Total registered users
     * @return invested Total USDT invested
     * @return payouts Total USDT paid as rewards
     */
    function getPlatformStats() external view returns (uint256, uint256, uint256, uint256) {
        return (totalPlans, totalUsers, totalInvested, totalPayouts);
    }


       function startproject() external 
    {
        require(msg.sender==owner,"Invalid user");
        startUNIX = 1;
    }


    /**
     * @dev Get the number of referrals a user has at a specific downline level
     * @param _user Address of the user whose downline is being queried
     * @param _level The downline level (0 for 1st gen, 1 for 2nd gen, etc., up to 16 for 17th gen)
     * @return count Number of referrals at that specific level for the user
     */
    function getDownlineCountAtLevel(address _user, uint256 _level) external view returns (uint256) {
        require(_level < TOTAL_REFERRAL_LEVELS, "Grizzifi: Invalid level");
        // Accesses the User struct's levelReferrals mapping.
        // users[_user].levelReferrals[0] is count of direct referrals (_user's 1st generation)
        // users[_user].levelReferrals[1] is count of _user's 2nd generation referrals, etc.
        return users[_user].levelReferrals[_level];
    }

    /**
     * @dev Struct to hold summary stats for a user, useful for referral lists.
     */
    struct UserSummary {
        uint256 totalInvested;
        uint256 totalEarned;
        uint256 activeInvestmentCount;
        uint256 totalReferralEarned;
        uint256 referralCount;
    }

    /**
     * @dev Get a summary of a user's statistics.
     * @param _user The address of the user.
     * @return A summary of the user's stats.
     */
    function getBearProfile(address _user) external view returns (UserSummary memory) {
        User storage user = users[_user];
        uint256 activeCount = 0;
        for (uint i = 0; i < user.investments.length; i++) {
            if (!user.investments[i].capitalWithdrawn) {
                activeCount++;
            }
        }

        return UserSummary({
            totalInvested: user.totalInvested,
            totalEarned: user.totalEarned,
            activeInvestmentCount: activeCount,
            totalReferralEarned: user.totalReferralEarned,
            referralCount: user.referralCount
        });
    }

    /**
     * @dev Get a user's list of direct referrals.
     * @param _user The address of the user.
     * @return A list of addresses of direct referrals.
     */
    function getCubList(address _user) external view returns (address[] memory) {
        return users[_user].directReferrals;
    }
    /**
     * @dev Get network investment statistics for a specific level
     * @param _user Address of the user whose network to analyze
     * @param _level Level to analyze (0 = direct referrals, 1 = 2nd level, etc.)
     * @return totalAmount Total investment amount at this level
     * @return activeAmount Total active investment amount at this level
     * @return investmentCount Total number of investments at this level
     * @return activeInvestmentCount Number of active investments at this level
     * @return userCount Number of unique users at this level
     */
    function getNetworkLevelStats(address _user, uint256 _level) external view returns (
        uint256 totalAmount,
        uint256 activeAmount,
        uint256 investmentCount,
        uint256 activeInvestmentCount,
        uint256 userCount
    ) {
        require(_level < TOTAL_REFERRAL_LEVELS, "Grizzifi: Invalid level");
        
        address[] memory usersAtLevel = _getUsersAtLevel(_user, _level);
        userCount = usersAtLevel.length;
        
        for (uint256 i = 0; i < usersAtLevel.length; i++) {
            address userAtLevel = usersAtLevel[i];
            User storage userStats = users[userAtLevel];
            
            totalAmount += userStats.totalInvested;
            investmentCount += userStats.investments.length;
            
            // Calculate active investments
            for (uint256 j = 0; j < userStats.investments.length; j++) {
                if (!userStats.investments[j].capitalWithdrawn) {
                    activeAmount += userStats.investments[j].amount;
                    activeInvestmentCount++;
                }
            }
        }
    }

function _incrementUplineTeamCount(address _user) internal {
    address upline = users[_user].referrer;
    for (uint8 i = 0; i < 30; i++) {
        if (upline == address(0)) break;

        if (users[upline].totalInvested >= minInvestForMilestone) {
            if (!users[upline].inTeam[_user]) {
                if (i == 0 && !users[_user].inDirect) {
                    users[_user].inDirect = true;
                    users[upline].directCount++;
                }
                users[upline].inTeam[_user] = true;
                users[upline].teamsCount++;

                uint256 index = users[upline].milestoneIndex;
                if (
                    index < teamMilestones.length &&
                    users[upline].teamsCount == teamMilestones[index]
                ) {
                    if (users[upline].directCount >= minDirect) {
                        uint256 reward = rewardAmounts[index];
                        users[upline].milestoneReward += reward;
                        users[upline].totalMilestoneEarned += reward;
                        emit MilestoneAchieved(
                            upline, users[upline].milestoneIndex, reward
                        );
                    }
                    users[upline].milestoneIndex++;
                }
            } else {
                break;
            }
        }

        upline = users[upline].referrer;
    }
}

    function getCompleteNetworkStats(address _user) external view returns (uint256[5][] memory levelStats) {
        levelStats = new uint256[5][](TOTAL_REFERRAL_LEVELS);
        
        for (uint256 level = 0; level < TOTAL_REFERRAL_LEVELS; level++) {
            address[] memory usersAtLevel = _getUsersAtLevel(_user, level);
            uint256 userCount = usersAtLevel.length;
            uint256 totalAmount = 0;
            uint256 activeAmount = 0;
            uint256 investmentCount = 0;
            uint256 activeInvestmentCount = 0;
            
            for (uint256 i = 0; i < usersAtLevel.length; i++) {
                address userAtLevel = usersAtLevel[i];
                User storage userStats = users[userAtLevel];
                
                totalAmount += userStats.totalInvested;
                investmentCount += userStats.investments.length;
                
                // Calculate active investments
                for (uint256 j = 0; j < userStats.investments.length; j++) {
                    if (!userStats.investments[j].capitalWithdrawn) {
                        activeAmount += userStats.investments[j].amount;
                        activeInvestmentCount++;
                    }
                }
            }
            
            levelStats[level] = [totalAmount, activeAmount, investmentCount, activeInvestmentCount, userCount];
        }
    }

    /**
     * @dev Get users at a specific network level
     * @param _user Address of the user whose network to analyze
     * @param _level Level to get users for (0 = direct referrals, 1 = 2nd level, etc.)
     * @return usersAtLevel Array of user addresses at the specified level
     */
    function getUsersAtLevel(address _user, uint256 _level) external view returns (address[] memory) {
        require(_level < TOTAL_REFERRAL_LEVELS, "Grizzifi: Invalid level");
        return _getUsersAtLevel(_user, _level);
    }

    /**
     * @dev Internal function to get users at a specific network level
     * @param _user Address of the user whose network to analyze
     * @param _level Level to get users for
     * @return usersAtLevel Array of user addresses at the specified level
     */
    function _getUsersAtLevel(address _user, uint256 _level) internal view returns (address[] memory) {
        if (_level == 0) {
            return users[_user].directReferrals;
        }
        
        // For levels > 0, we need to recursively find users
        address[] memory previousLevel = _getUsersAtLevel(_user, _level - 1);
        uint256 totalCount = 0;
        
        // First, count total users at this level
        for (uint256 i = 0; i < previousLevel.length; i++) {
            totalCount += users[previousLevel[i]].directReferrals.length;
        }
        
        // Create array and populate it
        address[] memory usersAtLevel = new address[](totalCount);
        uint256 currentIndex = 0;
        
        for (uint256 i = 0; i < previousLevel.length; i++) {
            address[] memory directRefs = users[previousLevel[i]].directReferrals;
            for (uint256 j = 0; j < directRefs.length; j++) {
                usersAtLevel[currentIndex] = directRefs[j];
                currentIndex++;
            }
        }
        
        return usersAtLevel;
    }

    /**
     * @dev Get detailed investment breakdown for a specific user
     * @param _user Address of the user
     * @return investments Array of investment details [planId, amount, startTime, isActive]
     */
    function getUserInvestmentDetails(address _user) external view returns (uint256[4][] memory investments) {
        User storage user = users[_user];
        investments = new uint256[4][](user.investments.length);
        
        for (uint256 i = 0; i < user.investments.length; i++) {
            Investment storage investment = user.investments[i];
            investments[i] = [
                investment.planId,
                investment.amount,
                investment.startTime,
                investment.capitalWithdrawn ? 0 : 1  // 0 = inactive, 1 = active
            ];
        }
    }


}