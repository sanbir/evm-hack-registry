// Decentralized collaborative distribution contract issued by: HoldSafe community //
// Contract audited, verified and corrected by Criptonopix //

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    uint256 private _status;

    /**
     * @dev Unauthorized reentrant call.
     */
    error ReentrancyGuardReentrantCall();

    constructor() {
        _status = NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a nonReentrant function from another nonReentrant
     * function is not supported. It is possible to prevent this from happening
     * by making the nonReentrant function external, and making it call a
     * private function that does the actual work.
     */
    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        // On the first call to nonReentrant, _status will be NOT_ENTERED
        if (_status == ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }

        // Any calls to nonReentrant after this point will fail
        _status = ENTERED;
    }

    function _nonReentrantAfter() private {
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = NOT_ENTERED;
    }

    /**
     * @dev Returns true if the reentrancy guard is currently set to "entered", which indicates there is a
     * nonReentrant function in the call stack.
     */
    function _reentrancyGuardEntered() internal view returns (bool) {
        return _status == ENTERED;
    }
}

interface IERC20 {
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);

    function transfer(address recipient, uint256 amount)
        external
        returns (bool);

    function balanceOf(address account) external view returns (uint256);
}

interface IPancakeRouter {
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory);
}

interface IPancakePair {
    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );

    function token0() external view returns (address);

    function token1() external view returns (address);
}

contract Hold_Safe is ReentrancyGuard {
    address public owner;
    address public constant     tokenAddress = 0xf83Aa05D3D7A6CA2DcE8a5329F7D1BE879b215F0;
    address public constant    defaultWallet = 0x74ef1A0EA1CDA62B191c8FB522A57aD6bB499B66;
    address public constant           router = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    // TOP DONATOR
    address public                topDonator = 0x0000000000000000000000000000000000000000;
    uint256 public               topDonation = 0;
    uint256 public                       pId = 0;
    uint256 public     requiredBalanceFactor = 4; 

    uint256 public constant         lockDays = 15; // LOCK PERIOD
    uint256 public constant        maxClaims = 20; // TOTAL CLAIMS PER DONATION
    uint256 public constant rewardPercentage = 1500; // 15%
    uint256 public constant      denominator = 10000;
    uint256 public constant     usdtDecimals = 1e18;
    uint256 public constant  quoteUSDTFactor = 1e16;

    uint256 public constant   minimumDeposit = usdtDecimals * 5;
    uint256 public constant   maximumDeposit = usdtDecimals * 2000;
    
    bool    public                    paused = false;

    struct Donation {
        uint256 donatedInUSDT; // Original value in USDT
        uint256 unlockTime;
        uint256 locked;
        uint256 reward;
        uint256 totalClaims;
        uint256 withdrawn;
        bool    isActive;
    }

    // PUBLIC MAPPINGS
    mapping(address => bool)          public isDisabled;
    mapping(uint256 => Donation)      public donations;
    mapping(address => uint256)       public totalContributed;
    mapping(address => uint256)       public totalWithdrawn;
    mapping(address => uint256)       public lastContribution;
    mapping(address => uint256)       public maxWithdraw;
    mapping(address => address)       public referrers;
    mapping(address => uint256)       public referrerRewards;
    mapping(uint256 => uint256)       public totalPaidReferrals;
    mapping(uint256 => uint256)       public totalPaidReferralAmount;

    // PRIVATE MAPPINGS
    mapping(uint256 => address)  public poolOwner;


    uint256[10] public thresholds = [
          (15    * usdtDecimals),
          (300   * usdtDecimals),
          (600   * usdtDecimals),
          (1500  * usdtDecimals),
          (3000  * usdtDecimals),
          (6000  * usdtDecimals),
          (9000  * usdtDecimals),
          (12000 * usdtDecimals),
          (15000 * usdtDecimals),
          (18000 * usdtDecimals)];

    uint256[10] public levels = [1000, 300, 200, 100, 100, 100, 50, 50, 50, 50];

    event Donated(
        address indexed donor,
        uint256 amount,
        uint256 unlockTime,
        uint256 reward,
        address indexed referrer
    );
    event RewardPaid(address indexed referrer, uint256 level, uint256 amount);
    event Withdrawn(address indexed donor, uint256 reward);
    event Paused(address account);
    event Unpaused(address account);
    event ReferrerClaimed(address indexed referrer, uint256 amount);
    event ReferralRewardAdded(address indexed referrer, uint256 rewardAmount);
    event ReferralAdded(address indexed referrer, address indexed referee);
    event ManualDonationDisabled();

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can perform this action");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Donations are paused");
        _;
    }

    modifier whenPaused() {
        require(paused, "Donations are not paused");
        _;
    }

    function getTotalDonations() public view returns (uint256) {
        return pId;
    }

    function NewOwner(address _addressOwner) external onlyOwner {
        require(_addressOwner != address(0), "Invalid address");
        owner = _addressOwner;
    }

    function disableAddress(address _address) external onlyOwner {
        require(_address != address(0), "Invalid address");
        isDisabled[_address] = true;
    }

    function enableAddress(address _address) external onlyOwner {
        require(_address != address(0), "Invalid address");
        isDisabled[_address] = false;
    }

    function pooler(uint256 _pid, address _wallet) public view returns (bool) {
        if (poolOwner[_pid] == _wallet) {
            return true;
        } else {
            return false;
        }
    }

    function shouldReset(address _donatorAddress) private {
        if (maxWithdraw[_donatorAddress] <= 0) {

            // RESET MAX WITHDRAW
            maxWithdraw[_donatorAddress] = 0;

            // RESET REWARD
            referrerRewards[msg.sender] = 0;

            for (uint256 i = 0; i < pId; i++) {
                if (pooler(i, _donatorAddress) && donations[i].isActive) {
                    donations[i].isActive = false;
                }
            }
        }
    }

    function getActiveDonationsByWallet(address _donatorAddress) public view returns (uint256[] memory) {
        uint256 activeCount = 0;

        // Count how many donations are active by address
        for (uint256 i = 0; i < pId; i++) {
            if (donations[i].isActive && pooler(i, _donatorAddress)) {
                activeCount++;
            }
        }

        // Create a list of active donations by address
        uint256[] memory activeDonations = new uint256[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < pId; i++) {
            if (donations[i].isActive && pooler(i, _donatorAddress)) {
                activeDonations[index] = i;
                index++;
            }
        }

        return activeDonations;
    }

    function getActiveDonations() public view returns (uint256[] memory) {
        uint256 activeCount = 0;

        // Count how many donations are active
        for (uint256 i = 0; i < pId; i++) {
            if (donations[i].isActive) {
                activeCount++;
            }
        }

        // Create a list of active addresses
        uint256[] memory activeDonations = new uint256[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < pId; i++) {
            if (donations[i].isActive) {
                activeDonations[index] = i;
                index++;
            }
        }

        return activeDonations;
    }

    function getInactiveDonations() public view returns (uint256[] memory) {
        uint256 inactiveCount = 0;

        // Count how many donations are inactive
        for (uint256 i = 0; i < pId; i++) {
            if (!donations[i].isActive) {
                inactiveCount++;
            }
        }

        // Create a list of inactive addresses
        uint256[] memory inactiveDonors = new uint256[](inactiveCount);
        uint256 index = 0;
        for (uint256 i = 0; i < pId; i++) {
            if (!donations[i].isActive) {
                inactiveDonors[index] = i;
                index++;
            }
        }

        return inactiveDonors;
    }

    function Stake(uint256 usdtAmount, address referrer) external whenNotPaused {
        require(
            !isDisabled[msg.sender],
            "This address is disabled from making donations"
        );
        require(usdtAmount >= minimumDeposit, "Minimum value reached");
        require(usdtAmount <= maximumDeposit, "Maximum value reached");
        require(
            msg.sender != defaultWallet,
            "This address is disabled from making donations"
        );
        uint256 reward = ((usdtAmount) * rewardPercentage) / denominator;

        // REFERRAL LOGIC
        if (referrers[msg.sender] != address(0)) {
            referrer = referrers[msg.sender];
        }

        address validReferrer = (referrer != address(0) &&
            maxWithdraw[referrer] >= (thresholds[0]))
            ? referrer
            : defaultWallet;
        referrers[msg.sender] = validReferrer;

        emit ReferralAdded(validReferrer, msg.sender);
        // CALLS REFERRAL
        calculateReferrerRewards(usdtAmount, validReferrer);

        // UPDATES MAX WITHDRAW
        uint256 maximumWithdraw = (usdtAmount * rewardPercentage / denominator) * maxClaims;
        maxWithdraw[msg.sender] += maximumWithdraw;

        donations[pId] = Donation({
            donatedInUSDT: usdtAmount,
            unlockTime: block.timestamp + (lockDays * 1 days),
            locked: block.timestamp,
            reward: reward,
            totalClaims: 0,
            withdrawn: 0,
            isActive: true
        });

        totalContributed[msg.sender] += usdtAmount;
        lastContribution[msg.sender] = usdtAmount;

        // SETS TOTAL CONTRIBUTION AND CHECKS TOP DONATOR
        uint256 totalContribution = totalContributed[msg.sender];
        if (topDonation < totalContribution) {
            topDonation = totalContribution;
            topDonator  = msg.sender;
        }

        poolOwner[pId] = msg.sender;

        // TRANSFER TOKENS FROM DEPOSIT WALLET TO THIS CONTRACT
        uint256 tokenAmount = getTokenAmountFromUSDT(usdtAmount);
        require((IERC20(tokenAddress).balanceOf(msg.sender) >= tokenAmount), "Do not try to fool me.");
        IERC20(tokenAddress).transferFrom(msg.sender, address(this), tokenAmount);
        emit Donated(
            msg.sender,
            tokenAmount,
            donations[pId].unlockTime,
            reward,
            validReferrer
        );

        // CREATES NEW POOL ID
        pId++;
    }

    function getUSDTFromTokenAmount(uint256 tokenAmount)
        public
        view
        returns (uint256)
    {
        IPancakeRouter pancakeRouter = IPancakeRouter(router); // Use a local variable to avoid shadowing
        // Coin addresses
        address bnbAddress = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // WBNB
        address usdtAddress = 0x55d398326f99059fF775485246999027B3197955; // USDT

        // Conversion path: USDT -> BNB -> TOKEN
        address[] memory path = new address[](3);
        path[0] = tokenAddress;
        path[1] = bnbAddress;
        path[2] = usdtAddress;

        // Calls the router to calculate the number of tokens
        uint256[] memory amounts = pancakeRouter.getAmountsOut(
            tokenAmount,
            path
        );
        uint256 TAmount = amounts[2];
        // The last value in the array is the number of tokens you receive
        return TAmount;
    }

    function getTokenAmountFromUSDT(uint256 usdtAmount)
        public
        view
        returns (uint256)
    {
        IPancakeRouter pancakeRouter = IPancakeRouter(router); // Use a local variable to avoid shadowing
        // Coin addresses
        address bnbAddress = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // WBNB
        address usdtAddress = 0x55d398326f99059fF775485246999027B3197955; // USDT
        uint256 value1 = quoteUSDTFactor;

        // Conversion path: USDT -> BNB -> TOKEN
        address[] memory path = new address[](3);
        path[0] = usdtAddress;
        path[1] = bnbAddress;
        path[2] = tokenAddress;

        // Calls the router to calculate the number of tokens
        uint256[] memory amounts = pancakeRouter.getAmountsOut(value1, path);
        uint256 AmountValue = (amounts[2] * usdtAmount) / quoteUSDTFactor;
        // The last value in the array is the number of tokens you receive
        return AmountValue;
    }

    function checkMaxClaims(uint256 _pid) public view returns (bool) {
        if (donations[_pid].totalClaims >= (maxClaims)) {
            return true;
        } else {
            return false;
        }
    }

    function getLevel(address user) public view returns (uint256) {
        uint256 total = maxWithdraw[user];
        for (uint256 i = 0; i < thresholds.length; i++) {
            if (total < thresholds[i]) {
                return i;
            }
        }
        return thresholds.length; // If the user exceeds the last limit, he will be in the last level
    }

    function Claim(uint256 _pid) external nonReentrant {
        // GLOBAL REQUIREMENTS
        require(pooler(_pid, msg.sender),
        "You must own the Pool");

        require(maxWithdraw[msg.sender] > 0,
        "You reached maximum withdraw");

        require(block.timestamp >= donations[_pid].unlockTime,
        "Tokens are still locked");

        require(donations[_pid].isActive,
        "No active donation to withdraw");

        require(!checkMaxClaims(_pid),
        "Max claims reached");

        // CONVERTS USDT REWARDS IN TOKENS
        uint256 rewardInTokens = getTokenAmountFromUSDT(donations[_pid].reward);

        // UPDATES LOCK PERIOD
        donations[_pid].locked = donations[_pid].unlockTime;
        donations[_pid].unlockTime += (lockDays * 1 days);

        // CHECKS MAX WITHDRAW
        if (donations[_pid].reward <= maxWithdraw[msg.sender]){ 
            maxWithdraw[msg.sender] -= donations[_pid].reward;
        }

        // UPDATES MAX WITHDRAW IF LOWER THAN REWARD
        if (donations[_pid].reward > maxWithdraw[msg.sender]) {
            rewardInTokens = getTokenAmountFromUSDT(maxWithdraw[msg.sender]);
            maxWithdraw[msg.sender] = 0;
        } 

        // SAFELY TRANSFER TOKENS
        safeTransfer(msg.sender, rewardInTokens);
        
        // UPDATES TOTAL CLAIMS
        donations[_pid].totalClaims++;
        donations[_pid].withdrawn += donations[_pid].reward;

        // TURNS OFF POOL IF MAX CLAIMS REACHED
        if (checkMaxClaims(_pid)) {
            donations[_pid].isActive = false;
        }

        // CHECKS IF WALLET SHOULD BE RESET
        shouldReset(msg.sender);

        // NICE! YOU DID IT!
        emit Withdrawn(msg.sender, rewardInTokens);
    }

    function Rewards() external nonReentrant {

        require(maxWithdraw[msg.sender] > 0 || msg.sender == defaultWallet, 
        "You reached maximum withdraw");

        //CHECKS IF THERE IS ANY REWARD TO BE PAID
        uint256 reward = referrerRewards[msg.sender];
        require(reward > 0, "No rewards to claim");

        // REBALANCES MAX WITHDRAW
        if (msg.sender != defaultWallet) {
            uint256 maxWithdrawal = maxWithdraw[msg.sender];
            bool taken = false;
            if (maxWithdrawal >= (reward)) {
                maxWithdraw[msg.sender] -= (reward);
                taken = true;
            }
            if (maxWithdrawal < (reward) && !taken) {
                reward = maxWithdrawal;
                maxWithdraw[msg.sender] = 0;
            }
        }
        // SAFELY TRANSFER
        safeTransfer(msg.sender, getTokenAmountFromUSDT(reward));
        
        // RESETS REWARDS TO BE PAID
        referrerRewards[msg.sender] = 0;
        
        // CHECKS IF EVERYTHING SHOULD BE RESET
        shouldReset(msg.sender);

        // NICE! YOU DID IT!
        emit ReferrerClaimed(msg.sender, reward);
    }

    function calculateReferrerRewards(uint256 usdtAmount, address referrer)
        private
        returns (uint256)
    {
        uint256 totalReward = 0;
        uint256 currentLevel = 1; // Initialize with 1
        if (usdtAmount == 0) {
            return 0; // Returns 0 if the amount is zero
        }
        address previousReferrer;
        while (
            referrer != address(0) &&
            referrer != defaultWallet &&
            currentLevel <= 10
        ) {
            require(
                referrer != previousReferrer,
                "Circular reference detected"
            );
            previousReferrer = referrer;
            if (maxWithdraw[referrer] >= ((thresholds[currentLevel - 1]))) {
                // Correct array access
                uint256 levelReward = (usdtAmount / denominator) * levels[currentLevel - 1];
                referrerRewards[referrer] += levelReward; // Directly updates rewards
                emit RewardPaid(referrer, currentLevel, levelReward); // Audit log

                totalPaidReferrals[currentLevel]++;
                totalPaidReferralAmount[currentLevel] += levelReward;

                // SETS TOTAL REWARD
                totalReward += levelReward;
            }
            referrer = referrers[referrer];
            currentLevel++;
        }
        if (referrer == defaultWallet && currentLevel <= 10) {
            uint256 defaultWalletReward = (usdtAmount / denominator) * levels[currentLevel - 1];
            referrerRewards[defaultWallet] += defaultWalletReward;
            return defaultWalletReward;
        }

        if (referrer == defaultWallet && currentLevel > 10) {
            uint256 defaultWalletReward = (usdtAmount / denominator) * levels[9];
            referrerRewards[defaultWallet] += defaultWalletReward;
            return defaultWalletReward;
        }

        // After level 10, always apply level 10 logic
        if (
            referrer != address(0) &&
            referrer != defaultWallet &&
            currentLevel > 10
        ) {
            uint256 level10Reward = (usdtAmount / denominator) * levels[9];
            referrerRewards[referrer] += level10Reward; // Directly updates rewards
            totalReward += level10Reward;

            emit RewardPaid(referrer, 10, level10Reward); // Log para auditoria
        }

        return totalReward;
    }

    function safeTransfer(address _address, uint256 _amount) private {
        require(IERC20(tokenAddress).balanceOf(address(this)) >= _amount, "Balance too low.");
        IERC20(tokenAddress).transfer(_address, _amount);

        // UPDATES TOTAL WITHDRAWN
        totalWithdrawn[_address] += _amount;
    }

    function pause() external onlyOwner whenNotPaused {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner whenPaused {
        paused = false;
        emit Unpaused(msg.sender);
    }
    
    function getDonatorsPerLevel() external view returns (uint256[] memory walletCounts) {
        uint256 levelCount = thresholds.length; // Assume que thresholds.length é 10
        walletCounts = new uint256[](levelCount);

        address[] memory processedWallets = new address[](pId); // Array para rastrear carteiras processadas
        uint256 processedCount = 0;

        for (uint256 i = 0; i < pId; i++) {
            address wallet = poolOwner[i];
            uint256 level = getLevel(wallet);

            // Ajuste do nível para índice baseado em 0
            require(level >= 1 && level <= levelCount, "Level out of bounds");

            uint256 index = level - 1; // Converter nível 1-10 para índice 0-9

            // Verificar se a carteira já foi processada
            bool isProcessed = false;
            for (uint256 j = 0; j < processedCount; j++) {
                if (processedWallets[j] == wallet) {
                    isProcessed = true;
                    break;
                }
            }

            if (!isProcessed) {
                walletCounts[index]++;
                processedWallets[processedCount] = wallet;
                processedCount++;
            }
        }

        return walletCounts;
    }

    constructor() {
        owner = msg.sender;
    }
}