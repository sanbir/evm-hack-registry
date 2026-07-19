// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IBurnableERC20 is IERC20 {
    function burn(uint256 amount) external;
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint);
    function price1CumulativeLast() external view returns (uint);
    function token0() external view returns (address);
}

contract InfinitySix is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public usdt;
    IERC20 public projectToken;
    IUniswapV2Router02 public dexRouter;
    address public uniswapPair;

    address public constant GENESIS_USER = 0xf86c0c3883878a55F6CF82C9daABC2E59ab6dcE3;
    
    address public constant DEVELOPER = 0xb7Da1d272b51E293Fc4cdbD6f3a9d79B28270eD8;

    uint256 public constant MIN_INVESTMENT = 100 * 10**18; 
    uint256 public constant DIRECT_BONUS_RATE = 50;
    uint256 public constant UPLINE_INCOME_THRESHOLD = 1800 * 10**18; 
    uint256 public constant MAX_DIRECTS = 150;
    
    uint256 public maxDownlineDepth = 500; 
    
    uint256 public liquiditySlippage = 5; 
    
    uint256 public launchTime; 

    struct Observation {
        uint32 timestamp;
        uint256 priceCumulative;
    }
    
    Observation[3] public observations; 
    uint8 public observationIndex;       
    bool public observationsFilled;      

    uint256 public twapPrice; 
    uint32 public constant TWAP_UPDATE_INTERVAL = 1 minutes; 

    uint256 public constant minTwapPrice = 10000000000000; 

    uint256 private constant WAD = 10**18;

    uint256[11] public rankReq = [
        0, 
        3000 * WAD, 10000 * WAD, 40000 * WAD, 120000 * WAD, 
        500000 * WAD, 2000000 * WAD, 10000000 * WAD, 
        50000000 * WAD, 200000000 * WAD, 1000000000 * WAD
    ];
    uint256[11] public rankIncome = [
        0, 
        50 * WAD, 200 * WAD, 1000 * WAD, 3000 * WAD, 
        10000 * WAD, 40000 * WAD, 200000 * WAD, 
        1000000 * WAD, 4000000 * WAD, 20000000 * WAD
    ];

    struct Investment {
        uint256 amount;
        uint256 compoundedPrincipal;
        uint256 rwpWithdrawn;
        uint256 lastUpdateTime;
        bool isActive; 
    }

    struct User {
        uint256 totalDeposits; 
        uint256 directBonus; 
        
        uint256 directCount;     
        uint256 directVolume;    
        uint256 currentRwpRate;  
        
        uint256 teamVolume; 
        uint256 totalDownlineBusiness; 
        
        uint256[41] levelRewardBase; 
        uint256 levelRewardsRealized; 
        uint256 lastLevelUpdateTime; 
        
        bool isUplineEligible;
        uint256 eligibleL1Count; 
        uint256 eligibleL2Count; 
        uint256 eligibleL3Count; 
        uint256[3] lastUplineRwpSeen; 
        uint256 pendingUplineIncome;  
        
        uint8 currentRank;
        uint256 salaryLastClaimTime;
        uint256 salaryEndTime;
        uint256 unwithdrawnSalary;
        uint256 totalWithdrawn;            
        address referrer; 
        bool isCapped; 
    }

    mapping(address => User) public users;
    mapping(address => Investment[]) public userInvestments; 
    mapping(address => address[]) public userDirects; 
    mapping(address => mapping(address => uint256)) public legSnapshot; 
    
    mapping(address => mapping(address => uint256)) public burnedVolume; 
    mapping(address => mapping(address => uint256)) public maintenanceBurnedVolume; 

    event Invested(address indexed user, uint256 amount, address indexed referrer);
    event Withdrawn(address indexed user, uint256 usdtValue, uint256 tokenAmount);
    event TwapUpdated(uint256 newPrice, uint32 timeElapsed);
    event InvestmentCapped(address indexed user, uint256 packageIndex);
    event DownlineFlushed(address indexed downline, string reason);
    event RateBoosted(address indexed user, uint256 newRate);
    event RankClaimed(address indexed user, uint8 rank, bool isMaintenance);
    event LiquidityAdded(uint256 usdtAmount, uint256 tokenAmount);

    constructor(address _usdt, address _projectToken, address _dexRouter, address initialOwner) Ownable(initialOwner) {
        usdt = IERC20(_usdt);
        projectToken = IERC20(_projectToken);
        dexRouter = IUniswapV2Router02(_dexRouter);
        
        usdt.approve(address(dexRouter), type(uint256).max);
        projectToken.approve(address(dexRouter), type(uint256).max);

        launchTime = block.timestamp; 

        uint256 genesisAmount = 100000 * WAD;
        users[GENESIS_USER].totalDeposits = genesisAmount;
        users[GENESIS_USER].lastLevelUpdateTime = block.timestamp;
        
        userInvestments[GENESIS_USER].push(Investment({
            amount: genesisAmount,
            compoundedPrincipal: genesisAmount,
            rwpWithdrawn: 0,
            lastUpdateTime: block.timestamp,
            isActive: true
        }));
        
        emit Invested(GENESIS_USER, genesisAmount, address(0));
    }

    function setUniswapPair(address _pair) external onlyOwner {
        require(_pair != address(0), "Invalid pair address");
        uniswapPair = _pair;
    }

    function setMaxDownlineDepth(uint256 _newDepth) external {
        require(msg.sender == DEVELOPER, "Only developer can update depth");
        require(_newDepth > 0, "Depth must be greater than 0");
        maxDownlineDepth = _newDepth;
    }

    function setLiquiditySlippage(uint256 _slippage) external {
        require(msg.sender == DEVELOPER, "Only developer can update slippage");
        require(_slippage >= 1 && _slippage <= 25, "Slippage must be between 1% and 25%");
        liquiditySlippage = _slippage;
    }

    function invest(uint256 usdtAmount, address referrer, uint256 minTokensOut) external nonReentrant {
        require(usdtAmount >= MIN_INVESTMENT, "Minimum investment is $100");
        require(uniswapPair != address(0), "Liquidity pair not set");
        require(userInvestments[msg.sender].length < 100, "Max 100 investments allowed per wallet");
        
        User storage user = users[msg.sender];
        uint256 oldActiveVolume = 0;
        bool wasCapped = user.isCapped;

        if (user.totalDeposits == 0) {
            require(referrer != address(0), "A valid sponsor ID is required");
            require(referrer != msg.sender, "Cannot refer yourself");
            require(users[referrer].totalDeposits > 0, "Sponsor is not active");
            
            user.referrer = referrer;
            user.lastLevelUpdateTime = block.timestamp;
            
            require(users[referrer].directCount < MAX_DIRECTS, "Sponsor reached 150 directs max");
            
            _realizeLevelIncome(referrer);

            users[referrer].directCount += 1;
            userDirects[referrer].push(msg.sender); 
            _checkAndToggleEligibility(referrer);
            
        } else {
            if (wasCapped) {
                user.isCapped = false;
                user.lastLevelUpdateTime = block.timestamp; 
                for (uint256 i = 0; i < userInvestments[msg.sender].length; i++) {
                    if (userInvestments[msg.sender][i].isActive) {
                        userInvestments[msg.sender][i].lastUpdateTime = block.timestamp;
                        oldActiveVolume += userInvestments[msg.sender][i].amount;
                    }
                }
            } else {
                _updateCompounding(msg.sender);
            }
        }

        user.totalDeposits += usdtAmount;
        _checkAndToggleEligibility(msg.sender);

        userInvestments[msg.sender].push(Investment({
            amount: usdtAmount,
            compoundedPrincipal: usdtAmount,
            rwpWithdrawn: 0,
            lastUpdateTime: block.timestamp,
            isActive: true
        }));

        usdt.safeTransferFrom(msg.sender, address(this), usdtAmount);

        _updateDownlineBusiness(msg.sender, usdtAmount);

        if (user.referrer != address(0)) {
            User storage refUser = users[user.referrer];
            if (!refUser.isCapped) {
                refUser.directBonus += (usdtAmount * DIRECT_BONUS_RATE) / 1000;
            }
            refUser.directVolume += usdtAmount;
            _checkAndApplyBooster(user.referrer);
        }

        uint256 userRate = user.currentRwpRate == 0 ? 5 : user.currentRwpRate;
        _updateUplineStream(msg.sender, usdtAmount, true, userRate, true);
        
        if (oldActiveVolume > 0) {
            _updateUplineStream(msg.sender, oldActiveVolume, true, userRate, false);
        }

        _processUsdt(usdtAmount, minTokensOut);
        updateTwap(); 

        _tryAutoRank(msg.sender);
        if (user.referrer != address(0)) {
            _tryAutoRank(user.referrer);
        }

        emit Invested(msg.sender, usdtAmount, referrer);
    }

    function _updateDownlineBusiness(address _user, uint256 _amount) internal {
        address currentUpline = users[_user].referrer;
        for (uint256 i = 1; i <= maxDownlineDepth; i++) {
            if (currentUpline == address(0)) break; 
            users[currentUpline].totalDownlineBusiness += _amount;
            currentUpline = users[currentUpline].referrer;
        }
    }

    function claimRank() external nonReentrant {
        User storage user = users[msg.sender];
        require(!user.isCapped, "User is capped");
        require(user.directCount > 0, "No active directs");

        _realizeSalary(msg.sender);

        uint8 newRank = user.currentRank;
        bool isMaintenance = false;
        bool rankUpgraded = false;

        for (uint8 r = 10; r > user.currentRank; r--) {
            if (_checkRankQualification(msg.sender, r)) {
                newRank = r;
                rankUpgraded = true;
                break;
            }
        }

        if (!rankUpgraded && user.currentRank > 0) {
            if (block.timestamp >= user.salaryEndTime - 7 days) { 
                if (_checkMaintenanceQualification(msg.sender, user.currentRank)) {
                    isMaintenance = true;
                }
            }
        }

        require(rankUpgraded || isMaintenance, "Not qualified for upgrade or maintenance yet");

        if (isMaintenance) {
            _consumeMaintenanceVolume(msg.sender, user.currentRank);
        }

        if (rankUpgraded) {
            user.currentRank = newRank;
            user.salaryLastClaimTime = block.timestamp;
            user.salaryEndTime = block.timestamp + 30 days; 
        } else if (isMaintenance) {
            user.salaryLastClaimTime = block.timestamp;
            user.salaryEndTime = user.salaryEndTime > block.timestamp ? user.salaryEndTime + 30 days : block.timestamp + 30 days;
        }

        address[] memory directs = userDirects[msg.sender];
        for(uint256 i = 0; i < directs.length; i++) {
            address d = directs[i];
            legSnapshot[msg.sender][d] = users[d].totalDeposits + users[d].totalDownlineBusiness;
        }

        emit RankClaimed(msg.sender, user.currentRank, isMaintenance);
    }

    function _tryAutoRank(address _user) internal {
        User storage u = users[_user];
        if (u.isCapped || u.directCount == 0) return;

        uint8 newRank = u.currentRank;
        bool rankUpgraded = false;
        bool isMaintenance = false;

        for (uint8 r = 10; r > u.currentRank; r--) {
            if (_checkRankQualification(_user, r)) {
                newRank = r;
                rankUpgraded = true;
                break;
            }
        }

        if (!rankUpgraded && u.currentRank > 0) {
            if (block.timestamp >= u.salaryEndTime - 7 days) {
                if (_checkMaintenanceQualification(_user, u.currentRank)) {
                    isMaintenance = true;
                }
            }
        }

        if (rankUpgraded || isMaintenance) {
            _realizeSalary(_user);

            if (isMaintenance) {
                _consumeMaintenanceVolume(_user, u.currentRank);
            }

            if (rankUpgraded) {
                u.currentRank = newRank;
                u.salaryLastClaimTime = block.timestamp;
                u.salaryEndTime = block.timestamp + 30 days;
            } else if (isMaintenance) {
                u.salaryLastClaimTime = block.timestamp;
                u.salaryEndTime = u.salaryEndTime > block.timestamp ? u.salaryEndTime + 30 days : block.timestamp + 30 days;
            }
            
            address[] memory directs = userDirects[_user];
            for(uint256 i = 0; i < directs.length; i++) {
                address d = directs[i];
                legSnapshot[_user][d] = users[d].totalDeposits + users[d].totalDownlineBusiness;
            }
            
            emit RankClaimed(_user, u.currentRank, isMaintenance);
        }
    }

    function _checkRankQualification(address _user, uint8 _rank) internal view returns (bool) {
        uint256 target = rankReq[_rank];
        uint256 maxPerLeg = (target * 40) / 100;
        uint256 totalEligible = 0;
        
        address[] memory directs = userDirects[_user];
        for(uint256 i = 0; i < directs.length; i++) {
            address d = directs[i];
            uint256 rawVol = users[d].totalDeposits + users[d].totalDownlineBusiness;
            uint256 burned = burnedVolume[_user][d];
            
            uint256 effectiveVol = rawVol > burned ? rawVol - burned : 0;
            
            totalEligible += effectiveVol > maxPerLeg ? maxPerLeg : effectiveVol;
            if (totalEligible >= target) return true;
        }
        return totalEligible >= target;
    }

    function _checkMaintenanceQualification(address _user, uint8 _rank) internal view returns (bool) {
        uint256 target = rankReq[_rank] / 5;
        uint256 maxPerLeg = (target * 40) / 100; 
        uint256 totalEligible = 0;
        
        address[] memory directs = userDirects[_user];
        for(uint256 i = 0; i < directs.length; i++) {
            address d = directs[i];
            uint256 currentLegVol = users[d].totalDeposits + users[d].totalDownlineBusiness;
            uint256 pastLegVol = legSnapshot[_user][d];
            
            uint256 newVol = currentLegVol > pastLegVol ? currentLegVol - pastLegVol : 0;
            
            totalEligible += newVol > maxPerLeg ? maxPerLeg : newVol;
            if (totalEligible >= target) return true;
        }
        return totalEligible >= target;
    }

    function _consumeMaintenanceVolume(address _user, uint8 _rank) internal {
        uint256 target = rankReq[_rank] / 5; 
        uint256 maxPerLeg = (target * 40) / 100;
        uint256 remainingToBurn = target;

        address[] memory directs = userDirects[_user];
        for(uint256 i = 0; i < directs.length; i++) {
            if (remainingToBurn == 0) break; 

            address d = directs[i];
            uint256 currentLegVol = users[d].totalDeposits + users[d].totalDownlineBusiness;
            uint256 pastLegVol = legSnapshot[_user][d];

            if (currentLegVol > pastLegVol) {
                uint256 newVol = currentLegVol - pastLegVol;
                uint256 usableFromLeg = newVol > maxPerLeg ? maxPerLeg : newVol;

                uint256 amountToTake = usableFromLeg > remainingToBurn ? remainingToBurn : usableFromLeg;

                maintenanceBurnedVolume[_user][d] += amountToTake; 
                remainingToBurn -= amountToTake;
            }
        }
    }

    function _realizeSalary(address _user) internal {
        User storage u = users[_user];
        if (u.currentRank > 0 && u.salaryLastClaimTime < u.salaryEndTime && !u.isCapped) {
            uint256 endTime = block.timestamp > u.salaryEndTime ? u.salaryEndTime : block.timestamp;
            uint256 timePassed = endTime - u.salaryLastClaimTime;
            
            if (timePassed > 0) {
                uint256 salaryPerSec = rankIncome[u.currentRank] / 30 days;
                u.unwithdrawnSalary += timePassed * salaryPerSec;
                u.salaryLastClaimTime = endTime;
            }
        }
    }

    function getPendingSalary(address userAddress) public view returns (uint256) {
        User memory u = users[userAddress];
        if (u.currentRank == 0 || u.isCapped) return u.unwithdrawnSalary;

        uint256 pending = u.unwithdrawnSalary;
        if (u.salaryLastClaimTime < u.salaryEndTime) {
            uint256 endTime = block.timestamp > u.salaryEndTime ? u.salaryEndTime : block.timestamp;
            uint256 timePassed = endTime - u.salaryLastClaimTime;
            uint256 salaryPerSec = rankIncome[u.currentRank] / 30 days;
            pending += timePassed * salaryPerSec;
        }
        return pending;
    }
    
    function getLevelIncomeData(address _user) external view returns (uint256 pending, uint256 ratePerDay) {
        User storage u = users[_user];
        if (u.isCapped) return (0, 0);

        uint256 unlockedLevels = _user == GENESIS_USER ? 40 : u.directCount * 2;
        if (unlockedLevels > 40) unlockedLevels = 40;

        for (uint8 lvl = 1; lvl <= unlockedLevels; lvl++) {
            if (u.levelRewardBase[lvl] > 0) {
                ratePerDay += (u.levelRewardBase[lvl] * 5) / 1000;
            }
        }

        uint256 timeElapsed = block.timestamp - u.lastLevelUpdateTime;
        pending = (ratePerDay * timeElapsed) / 1 days;
        
        return (pending, ratePerDay);
    }

    function getPendingUplineIncome(address _user) external view returns (uint256) {
        User storage u = users[_user];
        if (!u.isUplineEligible || u.isCapped) return u.pendingUplineIncome;

        uint256 pending = u.pendingUplineIncome;
        
        address up1 = u.referrer;
        if (up1 != address(0)) {
            uint256 rwp1 = getTotalLifetimeRWP(up1);
            
            if (up1 != GENESIS_USER && rwp1 > u.lastUplineRwpSeen[0]) {
                uint256 div = users[up1].eligibleL1Count > 0 ? users[up1].eligibleL1Count : 1;
                pending += ((rwp1 - u.lastUplineRwpSeen[0]) * 50) / (1000 * div);
            }

            address up2 = users[up1].referrer;
            if (up2 != address(0)) {
                uint256 rwp2 = getTotalLifetimeRWP(up2);
                
                if (up2 != GENESIS_USER && rwp2 > u.lastUplineRwpSeen[1]) {
                    uint256 div = users[up2].eligibleL2Count > 0 ? users[up2].eligibleL2Count : 1;
                    pending += ((rwp2 - u.lastUplineRwpSeen[1]) * 30) / (1000 * div);
                }

                address up3 = users[up2].referrer;
                if (up3 != address(0)) {
                    uint256 rwp3 = getTotalLifetimeRWP(up3);
                    
                    if (up3 != GENESIS_USER && rwp3 > u.lastUplineRwpSeen[2]) {
                        uint256 div = users[up3].eligibleL3Count > 0 ? users[up3].eligibleL3Count : 1;
                        pending += ((rwp3 - u.lastUplineRwpSeen[2]) * 20) / (1000 * div);
                    }
                }
            }
        }
        return pending;
    }

    function _checkAndToggleEligibility(address _user) internal {
        User storage u = users[_user];
        bool shouldBeEligible = (u.totalDeposits >= UPLINE_INCOME_THRESHOLD && u.directCount >= 5 && !u.isCapped);
        
        if (shouldBeEligible && !u.isUplineEligible) {
            u.isUplineEligible = true;
            _realizeUplineIncome(_user); 
            _resetUplineRwpTrackers(_user);
            _adjustUplineEligibleCounts(_user, true);
        } else if (!shouldBeEligible && u.isUplineEligible) {
            u.isUplineEligible = false;
            _realizeUplineIncome(_user); 
            _adjustUplineEligibleCounts(_user, false);
        }
    }

    function _adjustUplineEligibleCounts(address _user, bool _isAdd) internal {
        address up1 = users[_user].referrer;
        if (up1 != address(0)) {
            if (_isAdd) users[up1].eligibleL1Count++; else if (users[up1].eligibleL1Count > 0) users[up1].eligibleL1Count--;
            
            address up2 = users[up1].referrer;
            if (up2 != address(0)) {
                if (_isAdd) users[up2].eligibleL2Count++; else if (users[up2].eligibleL2Count > 0) users[up2].eligibleL2Count--;
                
                address up3 = users[up2].referrer;
                if (up3 != address(0)) {
                    if (_isAdd) users[up3].eligibleL3Count++; else if (users[up3].eligibleL3Count > 0) users[up3].eligibleL3Count--;
                }
            }
        }
    }

    function getTotalLifetimeRWP(address _user) public view returns (uint256) {
        uint256 total = 0;
        Investment[] memory packages = userInvestments[_user];
        uint256 userRate = users[_user].currentRwpRate == 0 ? 5 : users[_user].currentRwpRate;
        uint256 multiplier = _getMultiplier(userRate);

        for (uint256 i = 0; i < packages.length; i++) {
            uint256 simulatedPrincipal = packages[i].compoundedPrincipal;
            
            if (packages[i].isActive && !users[_user].isCapped) {
                uint256 timeElapsed = block.timestamp - packages[i].lastUpdateTime;
                uint256 daysElapsed = timeElapsed / 1 days;
                uint256 secondsElapsed = timeElapsed % 1 days;

                if (daysElapsed > 0) {
                    simulatedPrincipal = (simulatedPrincipal * _rpow(multiplier, daysElapsed, WAD)) / WAD;
                }
                if (secondsElapsed > 0) {
                    simulatedPrincipal += (simulatedPrincipal * userRate * secondsElapsed) / (1000 * 1 days);
                }
            }

            uint256 generated = (simulatedPrincipal - packages[i].amount) + packages[i].rwpWithdrawn;
            uint256 maxRwp = (packages[i].amount * 25) / 10;
            
            if (_user != GENESIS_USER && generated > maxRwp) {
                generated = maxRwp; 
            }
            total += generated;
        }
        return total;
    }

    function _realizeUplineIncome(address _user) internal {
        User storage u = users[_user];
        if (u.isUplineEligible) {
            address up1 = u.referrer;
            if (up1 != address(0)) {
                uint256 rwp1 = getTotalLifetimeRWP(up1);
                
                if (up1 != GENESIS_USER && rwp1 > u.lastUplineRwpSeen[0]) {
                    uint256 div = users[up1].eligibleL1Count > 0 ? users[up1].eligibleL1Count : 1;
                    u.pendingUplineIncome += ((rwp1 - u.lastUplineRwpSeen[0]) * 50) / (1000 * div);
                }
                u.lastUplineRwpSeen[0] = rwp1; 

                address up2 = users[up1].referrer;
                if (up2 != address(0)) {
                    uint256 rwp2 = getTotalLifetimeRWP(up2);
                    
                    if (up2 != GENESIS_USER && rwp2 > u.lastUplineRwpSeen[1]) {
                        uint256 div = users[up2].eligibleL2Count > 0 ? users[up2].eligibleL2Count : 1;
                        u.pendingUplineIncome += ((rwp2 - u.lastUplineRwpSeen[1]) * 30) / (1000 * div);
                    }
                    u.lastUplineRwpSeen[1] = rwp2;

                    address up3 = users[up2].referrer;
                    if (up3 != address(0)) {
                        uint256 rwp3 = getTotalLifetimeRWP(up3);
                        
                        if (up3 != GENESIS_USER && rwp3 > u.lastUplineRwpSeen[2]) {
                            uint256 div = users[up3].eligibleL3Count > 0 ? users[up3].eligibleL3Count : 1;
                            u.pendingUplineIncome += ((rwp3 - u.lastUplineRwpSeen[2]) * 20) / (1000 * div);
                        }
                        u.lastUplineRwpSeen[2] = rwp3;
                    }
                }
            }
        }
    }

    function _resetUplineRwpTrackers(address _user) internal {
        User storage u = users[_user];
        address up1 = u.referrer;
        if (up1 != address(0)) {
            u.lastUplineRwpSeen[0] = getTotalLifetimeRWP(up1);
            address up2 = users[up1].referrer;
            if (up2 != address(0)) {
                u.lastUplineRwpSeen[1] = getTotalLifetimeRWP(up2);
                address up3 = users[up2].referrer;
                if (up3 != address(0)) {
                    u.lastUplineRwpSeen[2] = getTotalLifetimeRWP(up3);
                }
            }
        }
    }

    function _checkAndApplyBooster(address _user) internal {
        User storage u = users[_user];
        uint256 oldRate = u.currentRwpRate == 0 ? 5 : u.currentRwpRate;
        uint256 newRate = 5;
        
        if (u.directCount >= 10 && u.directVolume >= 10000 * 10**18) newRate = 10;
        else if (u.directCount >= 5 && u.directVolume >= 5000 * 10**18) newRate = 8;
        else if (u.directCount >= 3 && u.directVolume >= 1500 * 10**18) newRate = 7;
        
        if (newRate > oldRate) {
            if (u.totalDeposits > 0) _updateCompounding(_user); 
            u.currentRwpRate = newRate;
            emit RateBoosted(_user, newRate);
            
            if (!u.isCapped) {
                uint256 activeVol = 0;
                for (uint256 i = 0; i < userInvestments[_user].length; i++) {
                    if (userInvestments[_user][i].isActive) activeVol += userInvestments[_user][i].amount;
                }
                if (activeVol > 0) {
                    _updateUplineStream(_user, activeVol, true, newRate - oldRate, false);
                }
            }
        }
    }

    function _realizeLevelIncome(address _user) internal {
        User storage u = users[_user];
        if (u.isCapped) return;

        uint256 timeElapsed = block.timestamp - u.lastLevelUpdateTime;
        if (timeElapsed > 0) {
            uint256 pending = 0;
            uint256 unlockedLevels = _user == GENESIS_USER ? 40 : u.directCount * 2;
            if (unlockedLevels > 40) unlockedLevels = 40;

            for (uint8 lvl = 1; lvl <= unlockedLevels; lvl++) {
                if (u.levelRewardBase[lvl] > 0) {
                    pending += (u.levelRewardBase[lvl] * 5 * timeElapsed) / (1000 * 1 days);
                }
            }
            u.levelRewardsRealized += pending;
        }
        u.lastLevelUpdateTime = block.timestamp;
    }

    function _updateUplineStream(address _user, uint256 _amount, bool _isAdd, uint256 _rateFactor, bool _addTeamVolume) internal {
        address currentUpline = users[_user].referrer;
        
        for (uint8 i = 1; i <= 40; i++) {
            if (currentUpline == address(0)) break; 
            
            User storage upline = users[currentUpline];
            
            if (!upline.isCapped) {
                _realizeLevelIncome(currentUpline);

                uint256 percent;
                if (i == 1) percent = 100;
                else if (i == 2) percent = 50;  
                else if (i == 3) percent = 40;  
                else percent = 30;              

                uint256 baseDelta = (_amount * percent * _rateFactor) / (1000 * 5); 

                if (_isAdd) {
                    if (_addTeamVolume) {
                        upline.teamVolume += _amount;
                    }
                    upline.levelRewardBase[i] += baseDelta; 
                } else {
                    if (upline.levelRewardBase[i] >= baseDelta) upline.levelRewardBase[i] -= baseDelta;
                    else upline.levelRewardBase[i] = 0;
                }
            }
            currentUpline = upline.referrer;
        }
    }

    function flushDeadAccount(address _userAddress) external {
        User storage user = users[_userAddress];
        require(user.totalDeposits > 0 && !user.isCapped, "User inactive or globally capped");

        uint256 droppedVolume = 0;
        uint256 userRate = user.currentRwpRate == 0 ? 5 : user.currentRwpRate;

        for (uint256 i = 0; i < userInvestments[_userAddress].length; i++) {
            Investment storage inv = userInvestments[_userAddress][i];
            if (inv.isActive) {
                uint256 maxRwpAllowed = (inv.amount * 25) / 10;

                if (_userAddress != GENESIS_USER && inv.rwpWithdrawn >= maxRwpAllowed) {
                    inv.isActive = false; 
                    droppedVolume += inv.amount;
                }
            }
        }

        require(droppedVolume > 0, "No individual packages have capped out");
        _updateUplineStream(_userAddress, droppedVolume, false, userRate, false);
        emit DownlineFlushed(_userAddress, "2.5x Package Capped - Stream Removed");
    }

    function withdraw() external nonReentrant {
        if(uniswapPair != address(0)) {
             updateTwap();
        }

        _updateCompounding(msg.sender);
        User storage user = users[msg.sender];
        require(user.totalDeposits > 0 && !user.isCapped, "No active investment or 7x capped");

        uint256 totalAvailableRwpToWithdraw = 0;
        uint256 volumeToDropFromUplines = 0;
        uint256 userRate = user.currentRwpRate == 0 ? 5 : user.currentRwpRate;

        for (uint256 i = 0; i < userInvestments[msg.sender].length; i++) {
            Investment storage inv = userInvestments[msg.sender][i];
            
            if (inv.isActive) {
                uint256 generated = (inv.compoundedPrincipal - inv.amount) + inv.rwpWithdrawn;
                uint256 maxRwpAllowed = (inv.amount * 25) / 10;
                uint256 availableForPackage = inv.compoundedPrincipal - inv.amount;

                if (msg.sender != GENESIS_USER && generated >= maxRwpAllowed) {
                    uint256 excess = generated - maxRwpAllowed;
                    availableForPackage -= excess;
                    
                    inv.isActive = false;
                    volumeToDropFromUplines += inv.amount;
                    emit InvestmentCapped(msg.sender, i);
                }

                totalAvailableRwpToWithdraw += availableForPackage;
                inv.rwpWithdrawn += availableForPackage;
                inv.compoundedPrincipal -= availableForPackage;
            }
        }

        if (volumeToDropFromUplines > 0) {
            _updateUplineStream(msg.sender, volumeToDropFromUplines, false, userRate, false);
        }

        _realizeLevelIncome(msg.sender); 
        _realizeUplineIncome(msg.sender);
        _realizeSalary(msg.sender); 

        uint256 totalUsdtToWithdraw = totalAvailableRwpToWithdraw + user.directBonus + user.levelRewardsRealized + user.pendingUplineIncome + user.unwithdrawnSalary;
        require(totalUsdtToWithdraw > 0, "Nothing to withdraw");

        if (msg.sender != GENESIS_USER) {
            uint256 maxTotalAllowed = user.totalDeposits * 7;
            if (user.totalWithdrawn + totalUsdtToWithdraw >= maxTotalAllowed) {
                totalUsdtToWithdraw = maxTotalAllowed - user.totalWithdrawn;
                user.isCapped = true; 
                _checkAndToggleEligibility(msg.sender); 
                
                uint256 activeVolumeRemaining = 0;
                for (uint256 i = 0; i < userInvestments[msg.sender].length; i++) {
                    if (userInvestments[msg.sender][i].isActive) {
                        activeVolumeRemaining += userInvestments[msg.sender][i].amount;
                    }
                }
                if (activeVolumeRemaining > 0) {
                    _updateUplineStream(msg.sender, activeVolumeRemaining, false, userRate, false);
                }
            }
        }

        user.directBonus = 0; 
        user.levelRewardsRealized = 0; 
        user.pendingUplineIncome = 0;
        user.unwithdrawnSalary = 0; 
        user.totalWithdrawn += totalUsdtToWithdraw;

        uint256 effectivePrice = twapPrice > minTwapPrice ? twapPrice : minTwapPrice;

        uint256 tokensToTransfer = (totalUsdtToWithdraw * WAD) / effectivePrice;
        require(projectToken.balanceOf(address(this)) >= tokensToTransfer, "Not enough tokens in contract");

        uint256 burnAmount = (tokensToTransfer * 5) / 100;
        uint256 userAmount = tokensToTransfer - burnAmount;

        if (msg.sender == GENESIS_USER) {
            uint256 share25 = (userAmount * 25) / 100;
            uint256 share20_1 = (userAmount * 20) / 100;
            uint256 share15 = (userAmount * 15) / 100;
            uint256 share20_2 = (userAmount * 20) / 100;
            uint256 share10 = (userAmount * 10) / 100;
            uint256 share5_1 = (userAmount * 5) / 100;
            uint256 share5_2 = userAmount - (share25 + share20_1 + share15 + share20_2 + share10 + share5_1);

            require(projectToken.transfer(0x03DA638ff4c6f3A438726783e4D31F350E83aB53, share25), "Tx1 fail");
            require(projectToken.transfer(0xf6f4aCBd143Bb8b9FF8CFFf10753C848d4B26a2F, share20_1), "Tx2 fail");
            require(projectToken.transfer(0xa1C0859378e4b3f157F9e7b96A76caEd6e8C7Fc3, share15), "Tx3 fail");
            require(projectToken.transfer(0x1A1cE4eb714480206586EAD87af132C4D73BA34e, share20_2), "Tx4 fail");
            require(projectToken.transfer(0xC257647d96D340dCa8507971eDcF2fF13B871671, share10), "Tx5 fail");
            require(projectToken.transfer(0x54aAcCFE22e37b4ABc3DA351b1Be7e81517Bcd34, share5_1), "Tx6 fail");
            require(projectToken.transfer(DEVELOPER, share5_2), "Tx7 fail");
        } else {
            require(projectToken.transfer(msg.sender, userAmount), "Token transfer failed");
        }
        
        if (burnAmount > 0) {
            IBurnableERC20(address(projectToken)).burn(burnAmount);
        }
        
        _tryAutoRank(msg.sender);

        emit Withdrawn(msg.sender, totalUsdtToWithdraw, userAmount);
    }

    function _getMultiplier(uint256 rate) internal pure returns (uint256) {
        if (rate == 10) return 1010000000000000000; 
        if (rate == 8)  return 1008000000000000000; 
        if (rate == 7)  return 1007000000000000000; 
        return 1005000000000000000;                 
    }

    function _rpow(uint256 x, uint256 n, uint256 scalar) internal pure returns (uint256 z) {
        z = n % 2 != 0 ? x : scalar;
        for (n /= 2; n != 0; n /= 2) {
            x = (x * x) / scalar;
            if (n % 2 != 0) {
                z = (z * x) / scalar;
            }
        }
    }

    function _updateCompounding(address userAddress) internal {
        if (users[userAddress].isCapped) return; 

        Investment[] storage packages = userInvestments[userAddress];
        uint256 userRate = users[userAddress].currentRwpRate == 0 ? 5 : users[userAddress].currentRwpRate;
        uint256 multiplier = _getMultiplier(userRate);
        
        for (uint256 i = 0; i < packages.length; i++) {
            if (packages[i].isActive) {
                uint256 timeElapsed = block.timestamp - packages[i].lastUpdateTime;
                
                if (timeElapsed >= 1 days) {
                    uint256 newPrincipal = packages[i].compoundedPrincipal;
                    uint256 daysElapsed = timeElapsed / 1 days;
                    
                    newPrincipal = (newPrincipal * _rpow(multiplier, daysElapsed, WAD)) / WAD;

                    packages[i].compoundedPrincipal = newPrincipal;
                    packages[i].lastUpdateTime += (daysElapsed * 1 days);
                }
            }
        }
    }

    function updateTwap() public {
        if (uniswapPair == address(0)) return; 
        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLastPair) = pair.getReserves();
        if (reserve0 == 0 || reserve1 == 0) return; 

        uint32 currentTimestamp = uint32(block.timestamp % 2 ** 32);
        
        uint8 lastIndex = observationIndex == 0 ? 2 : observationIndex - 1; 
        Observation memory lastObs = observations[lastIndex];
        
        if (lastObs.timestamp != 0) {
            uint32 timeSinceLastUpdate;
            unchecked { timeSinceLastUpdate = currentTimestamp - lastObs.timestamp; }
            if (timeSinceLastUpdate < TWAP_UPDATE_INTERVAL) return;
        }

        bool isToken0 = pair.token0() == address(projectToken);
        uint256 priceCumulativeCurrent;
        
        if (isToken0) {
            priceCumulativeCurrent = pair.price0CumulativeLast();
            if (currentTimestamp != blockTimestampLastPair) {
                unchecked { priceCumulativeCurrent += (uint256(reserve1) << 112) / reserve0 * (currentTimestamp - blockTimestampLastPair); }
            }
        } else {
            priceCumulativeCurrent = pair.price1CumulativeLast();
            if (currentTimestamp != blockTimestampLastPair) {
                unchecked { priceCumulativeCurrent += (uint256(reserve0) << 112) / reserve1 * (currentTimestamp - blockTimestampLastPair); }
            }
        }

        Observation memory oldestObs;
        if (observationsFilled) {
            oldestObs = observations[observationIndex]; 
        } else {
            oldestObs = observations[0]; 
        }

        if (oldestObs.timestamp != 0) {
            uint32 timeDelta;
            unchecked { timeDelta = currentTimestamp - oldestObs.timestamp; }
            
            if (timeDelta > 0) {
                unchecked {
                    uint256 priceDelta = priceCumulativeCurrent - oldestObs.priceCumulative;
                    uint256 priceAverage = priceDelta / timeDelta;
                    twapPrice = (priceAverage * WAD) >> 112; 
                }
                emit TwapUpdated(twapPrice, timeDelta);
            }
        }

        observations[observationIndex] = Observation({
            timestamp: currentTimestamp,
            priceCumulative: priceCumulativeCurrent
        });

        observationIndex++;
        if (observationIndex == 3) { 
            observationIndex = 0;
            observationsFilled = true;
        }
    }

    function _processUsdt(uint256 totalUsdtAmount, uint256 minTokensOut) internal {
        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        
        require(reserve0 > 0 && reserve1 > 0, "Liquidity pool is empty");

        if (block.timestamp <= launchTime + 365 days) {
            uint256 swapAmount = (totalUsdtAmount * 60) / 100;
            uint256 liquidityUsdtAmount = totalUsdtAmount - swapAmount;

            address[] memory path = new address[](2);
            path[0] = address(usdt);
            path[1] = address(projectToken);

            dexRouter.swapExactTokensForTokens(
                swapAmount, 
                minTokensOut, 
                path, 
                address(this), 
                block.timestamp
            );

            (uint112 newReserve0, uint112 newReserve1, ) = pair.getReserves();

            (uint112 reserveUsdt, uint112 reserveToken) = pair.token0() == address(usdt) 
                ? (newReserve0, newReserve1) 
                : (newReserve1, newReserve0);

            uint256 exactTokensNeeded = dexRouter.quote(liquidityUsdtAmount, reserveUsdt, reserveToken);

            if (projectToken.balanceOf(address(this)) >= exactTokensNeeded) {
                
                uint256 minToleranceMultiplier = 100 - liquiditySlippage;
                uint256 amountUsdtMin = (liquidityUsdtAmount * minToleranceMultiplier) / 100;
                uint256 amountTokenMin = (exactTokensNeeded * minToleranceMultiplier) / 100;

                dexRouter.addLiquidity(
                    address(usdt),
                    address(projectToken),
                    liquidityUsdtAmount,
                    exactTokensNeeded,
                    amountUsdtMin,
                    amountTokenMin,
                    address(0x000000000000000000000000000000000000dEaD), 
                    block.timestamp
                );
                
                emit LiquidityAdded(liquidityUsdtAmount, exactTokensNeeded);
            }
        } else {
            address[] memory path = new address[](2);
            path[0] = address(usdt);
            path[1] = address(projectToken);

            dexRouter.swapExactTokensForTokens(
                totalUsdtAmount, 
                minTokensOut, 
                path, 
                address(this), 
                block.timestamp
            );
        }
    }
    
    function rescueAccidentalTokens(address tokenAddress, uint256 amount) external {
        require(msg.sender == DEVELOPER, "Only developer can rescue tokens");
        require(tokenAddress != address(projectToken), "Cannot drain reward tokens");
        IERC20(tokenAddress).safeTransfer(DEVELOPER, amount);
    }
}

// This smart contract is built with transparency and user trust in mind.
// All rules, rewards, and limitations are fully defined on-chain and cannot be altered.