// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract DLMCToken is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════
    // 🪙 TOKENOMICS CONSTANTS
    // ═══════════════════════════════════════════════════════
    uint256 constant PRE_MINED_LP = 500_000 * 10 ** 18;
    uint256 constant DIVIDENT_PER_DAY = 1 days;

    address public DEVELOPERADDRESS;
    address public DEVELOPERADDRESS1;
    address public DEVELOPERADDRESS2;
    address public DEVELOPERADDRESS3;

    // ═══════════════════════════════════════════════════════
    // 💰 AFFILIATE PLAN CONSTANTS
    // ═══════════════════════════════════════════════════════
    uint256 constant MIN_INVESTMENT_FOR_INCOME = 100 * 10 ** 18; // $100 min (18 dec)
    uint256 constant DAILY_DIVIDEND_RATE = 1; // 1% daily dividend
    uint256 constant CAP_SMALL_INVESTOR = 250; // 250% cap for <100 USDT
    uint256 constant CAP_LARGE_INVESTOR = 500; // 500% cap for ≥100 USDT

    // 15-Level Distribution Percentages (MUST sum to 100)
    uint256[15] public REFERRAL_LEVEL_PERCENTS = [
        10,
        9,
        8,
        7,
        6,
        5,
        4,
        4,
        4,
        3,
        3,
        3,
        3,
        3,
        3
    ];

    uint256[15] public REFERRAL_SELF_BUSINESS = [
        100 * 1e18,
        200 * 1e18,
        300 * 1e18,
        400 * 1e18,
        500 * 1e18,
        700 * 1e18,
        900 * 1e18,
        1100 * 1e18,
        1300 * 1e18,
        1500 * 1e18,
        1800 * 1e18,
        2100 * 1e18,
        2400 * 1e18,
        2700 * 1e18,
        3000 * 1e18
    ];

    uint256 constant MAX_REFERRAL_LEVELS = 15;

    uint256[15] public MATCHING_SELF_INVEST_REQUIREMENTS = [
        200 * 1e18,
        400 * 1e18,
        800 * 1e18,
        1600 * 1e18,
        3200 * 1e18,
        6400 * 1e18,
        12800 * 1e18,
        25600 * 1e18,
        51200 * 1e18,
        102400 * 1e18,
        102400 * 1e18,
        102400 * 1e18,
        102400 * 1e18,
        102400 * 1e18,
        102400 * 1e18
    ];

    // ═══════════════════════════════════════════════════════
    // 🏆 PROGRESSIVE MATCHING CONSTANTS
    // ═══════════════════════════════════════════════════════
    uint256 constant MATCHING_BASE_VOLUME = 15_000 * 1e18;
    uint256 constant MATCHING_REWARD_PERCENT = 1;
    uint256 constant MATCHING_MAX_TIERS = 15;

    // ═══════════════════════════════════════════════════════
    // 👤 INVESTMENT TRANCHE STRUCTURE
    // ═══════════════════════════════════════════════════════
    struct InvestmentTranche {
        uint256 amountUsdt18;
        uint256 startTime;
        uint256 lastClaimTime;
        bool isActive;
    }

    uint256 public totalUser = 1;

    // ═══════════════════════════════════════════════════════
    // 👤 AFFILIATE USER DATA STRUCTURE
    // ═══════════════════════════════════════════════════════
    struct AffiliateUser {
        uint256 mid;
        bool isRegistered;
        address referrer;
        uint256 totalInvested; // USDT invested (18 decimals)
        // 🎯 INCOME STREAMS - STORED AS USDT VALUE (18 decimals)
        uint256 totalPersonalDividends; // Stream 1: USDT value earned
        uint256 totalReferralBonuses; // Stream 2: USDT value earned
        uint256 totalLevelBonuses; // Stream 3: USDT value earned (includes Leadership)
        uint256 totalMatchingRewards; // Stream 4: USDT value earned (vested matching)
        uint256 totalMatchingVolumeClaimed;
        uint256 lastDividendClaim;
        uint256 registrationTime;
        mapping(uint256 => address) downline;
        InvestmentTranche[] tranches;
        uint256 totalDirectInvested;
        uint256 totalTeamInvested;
    }

    // ═══════════════════════════════════════════════════════
    // ⏳ VESTED MATCHING REWARD STRUCTURE
    // ═══════════════════════════════════════════════════════
    struct VestedMatchingReward {
        uint256 sno;
        uint256 totalRewardUsdt18;
        uint256 dailyRewardUsdt18;
        uint256 claimedRewardUsdt18;
        uint256 startTime;
        uint256 lastClaimTime;
        bool isActive;
    }

    // ═══════════════════════════════════════════════════════
    // ⏳ VESTING CONSTANTS
    // ═══════════════════════════════════════════════════════
    uint256 constant VESTING_DURATION_DAYS = 200;
    uint256 constant VESTING_DAILY_PERCENT = 5;
    uint256 constant VESTING_CLAIM_PERIOD = 1 days;

    mapping(address => AffiliateUser) public affiliates;
    mapping(address => address[]) public directDownline;
    mapping(address => uint256) public userLastClaimedMatchingTier;
    mapping(address => VestedMatchingReward[]) public vestedMatchingRewards;
    mapping(address => mapping(uint256 => bool)) private _vestedRewardCompleted;

    // ═══════════════════════════════════════════════════════
    // 📊 SELL LIMIT TRACKING
    // ═══════════════════════════════════════════════════════
    mapping(address => uint256) public userSoldValueUsdt18;

    // ═══════════════════════════════════════════════════════
    // 📊 PRICE & TRADING VARIABLES
    // ═══════════════════════════════════════════════════════
    uint256 public livePrice;
    IERC20 public immutable quoteToken;
    uint8 public immutable quoteDecimals;

    uint256 constant BUY_PERCENT = 15;
    uint256 constant SELL_PERCENT = 10;

    uint256 public totalUSDTReceived;
    uint256 public totalUSDTWithdrawn;
    uint256 public totalLPTMintedForUsers;

    uint256 public constant MIN_PRICE = 1 * 1e17;
    uint256 public constant MAX_PRICE = 100000 * 1e18;

    // ═══════════════════════════════════════════════════════
    // 🏆 LEADERSHIP BONUS CONSTANTS
    // ═══════════════════════════════════════════════════════
    uint256 constant LEADERSHIP_LEVELS = 3;
    uint256[3] public LEADERSHIP_PERCENTS = [10, 5, 5];
    uint256 constant LEADERSHIP_REQ_SELF_INVEST = 3000 * 1e18;
    uint256 constant LEADERSHIP_REQ_DIRECT_COUNT = 15;
    uint256 constant LEADERSHIP_REQ_TEAM_VOLUME = 10000 * 1e18;

    // ═══════════════════════════════════════════════════════
    // 📢 EVENTS
    // ═══════════════════════════════════════════════════════
    event PriceUpdated(uint256 newPrice, string direction);
    event TradeExecuted(
        address indexed user,
        string tradeType,
        uint256 amountQuote,
        uint256 amountTokens,
        uint256 feeBurned
    );
    //event LiquidityWarning(uint256 contractBalance, uint256 requiredAmount);
    event UserRegistered(
        address indexed user,
        address indexed referrer,
        uint256 initialInvestment
    );
    event InvestmentUpdated(address indexed user, uint256 newTotalInvested);

    // Events: USDT value (18 decimals) + LPT amount (actual transfer)
    event DividendClaimed(
        address indexed user,
        uint256 amountUsdtValue,
        uint256 lptAmount
    );
    event ReferralBonusReceived(
        address indexed user,
        address indexed fromDownline,
        uint256 amountUsdtValue,
        uint256 lptAmount
    );
    event LevelBonusReceived(
        address indexed recipient,
        address indexed claimer,
        uint256 level,
        uint256 amountUsdtValue,
        uint256 lptAmount
    );
    event MatchingDividentClaimed(
        address indexed user,
        uint256 amountUsdtValue,
        uint256 lptAmount
    );
    // event IncomeCapReached(
    //     address indexed user,
    //     uint256 totalIncomeUsdt,
    //     uint256 capUsdt
    // );

    event MatchingRewardClaimed(
        address indexed user,
        uint256 rankAchieved,
        uint256 amountUsdtValue,
        uint256 lptAmount,
        uint256 matchingVolume
    );
    event RankUpgraded(
        address indexed user,
        uint256 newRank,
        uint256 rewardPercent
    );

    // ═══════════════════════════════════════════════════════
    // 🏛️ DAO MEMBERSHIP
    // ═══════════════════════════════════════════════════════
    uint256 public constant DAO_MEMBER_FEE = 5000 * 1e18;
    uint256 constant MAX_DAO_MEMBERS = 250;
    uint256 constant DIRECT_DAO_REFERRAL_THRESHOLD = 10;

    struct DaoMemberData {
        address member;
        uint256 totaltoken;
        uint256 claimtoken;
        uint256 selltoken;
        uint256 lastSellTimestamp; 
    }

    mapping(address => DaoMemberData) public daoMemberData;
    uint256 public totaldaotoken = 0;
    uint256 public daoUsdtBalance = 0;
    mapping(address => bool) public isDaoMember;
    mapping(address => uint256) public daoMemberSince;
    uint256 public totalDaoMembers;
    address[] public daoMemberAddresses;
    mapping(address => uint256) public daoTokenClaimed;

    event DaoMemberJoined(
        address indexed user,
        bool feeWaived,
        uint256 feePaid,
        uint256 timestamp
    );
    event DaoMembershipFeeReceived(address indexed from, uint256 amount);
    event DaoTokenClaimed(address indexed user, uint256 claimAmount);

    // ═══════════════════════════════════════════════════════
    // 🔧 CONSTRUCTOR
    // ═══════════════════════════════════════════════════════
    constructor(
        address _quoteTokenAddress,
        address _developeraddress,
        address _developeraddress1,
        address _developeraddress2,
        address _developeraddress3
    ) ERC20("DLMC Token", "DLMC") Ownable(msg.sender) {
        require(
            _quoteTokenAddress != address(0),
            "Invalid quote token address"
        );
        quoteToken = IERC20(_quoteTokenAddress);
        DEVELOPERADDRESS = _developeraddress;
        DEVELOPERADDRESS1 = _developeraddress1;
        DEVELOPERADDRESS2 = _developeraddress2;
        DEVELOPERADDRESS3 = _developeraddress3;
        try IERC20Metadata(_quoteTokenAddress).decimals() returns (uint8 d) {
            quoteDecimals = d;
        } catch {
            quoteDecimals = 6;
        }
        livePrice = 1 * 10 ** 17; // Start: 1 LPT = 0.1 USDT

        _mint(address(this), PRE_MINED_LP);
        _autoRegisterOwner();
    }

    function _autoRegisterOwner() internal {
        AffiliateUser storage root = affiliates[owner()];
        root.mid = totalUser;
        root.isRegistered = true;
        root.referrer = address(0);
        root.registrationTime = block.timestamp;
        root.lastDividendClaim = block.timestamp;
        totalUser += 1;
        emit UserRegistered(owner(), address(0), 0);
    }

    /**
     * @notice Add a new investment tranche for a user
     */
    function _addInvestmentTranche(
        address user,
        uint256 amountUsdt18,
        uint256 extradays
    ) internal {
        AffiliateUser storage a = affiliates[user];
        a.tranches.push(
            InvestmentTranche({
                amountUsdt18: amountUsdt18,
                startTime: block.timestamp,
                lastClaimTime: (block.timestamp + extradays),
                isActive: true
            })
        );
        a.totalInvested += amountUsdt18;
        emit InvestmentUpdated(user, a.totalInvested);
    }

    // ═══════════════════════════════════════════════════════
    // 🔄 TEAM BUSINESS VOLUME UPDATE
    // ═══════════════════════════════════════════════════════
    function _updateTeamBusinessUpline(
        address _buyer,
        uint256 _buyAmountUsdt18
    ) internal {
        if (_buyAmountUsdt18 == 0) return;
        AffiliateUser storage buyer = affiliates[_buyer];
        buyer.totalTeamInvested += _buyAmountUsdt18;
        address currentUpline = buyer.referrer;

        for (uint256 level = 1; level <= 150; level++) {
            if (currentUpline == address(0)) break;
            AffiliateUser storage upline = affiliates[currentUpline];
            if (upline.isRegistered) {
                if (level == 1) {
                    upline.totalDirectInvested += _buyAmountUsdt18;
                }
                upline.totalTeamInvested += _buyAmountUsdt18;
            }
            currentUpline = upline.referrer;
        }
    }

    // ═══════════════════════════════════════════════════════
    // 👥 AFFILIATE REGISTRATION
    // ═══════════════════════════════════════════════════════
    function registerAffiliate(address _referrer) external nonReentrant {
        require(!affiliates[msg.sender].isRegistered, "Already registered");
        require(
            _referrer != address(0) && _referrer != msg.sender,
            "Invalid referrer"
        );
        require(affiliates[_referrer].isRegistered, "Referrer not registered");

        AffiliateUser storage user = affiliates[msg.sender];
        user.mid = totalUser;
        user.isRegistered = true;
        user.referrer = _referrer;
        user.registrationTime = block.timestamp;
        user.lastDividendClaim = block.timestamp;
        directDownline[_referrer].push(msg.sender);
        totalUser++;
        emit UserRegistered(msg.sender, _referrer, 0);
    }

    // ═══════════════════════════════════════════════════════
    // 💱 BUY FUNCTION
    // ═══════════════════════════════════════════════════════
    function buy(uint256 amountQuote) external nonReentrant {
        require(
            affiliates[msg.sender].isRegistered,
            "Must be registered to buy"
        );
        require(amountQuote > 0, "Buy amount must be > 0");
        uint256 normalizedQuote = _normalizeTo18(amountQuote, quoteDecimals);

        uint256 currentTotalInvested = affiliates[msg.sender].totalInvested;

        if (currentTotalInvested >= MIN_INVESTMENT_FOR_INCOME) {
            require(
                normalizedQuote % MIN_INVESTMENT_FOR_INCOME == 0,
                "Investment must be a multiple of 100 USDT"
            );
        }

        quoteToken.safeTransferFrom(msg.sender, address(this), amountQuote);
        totalUSDTReceived += normalizedQuote;

        uint256 buyAmount = normalizedQuote -
            ((normalizedQuote * BUY_PERCENT) / 100);
        uint256 tokensToUser = (buyAmount * 10 ** 18) / livePrice;
        require(tokensToUser > 0, "Amount too small");

        _mint(address(this), tokensToUser);
        totalLPTMintedForUsers += tokensToUser;

        _addInvestmentTranche(msg.sender, normalizedQuote, (1 days));
        _updateTeamBusinessUpline(msg.sender, normalizedQuote);

        // 5% dev bonus
        uint256 devBonusLPT = _convertUsdtValueToLPT((buyAmount * 5) / 100);
        if (devBonusLPT > 0) {
            _transfer(
                address(this),
                DEVELOPERADDRESS,
                (devBonusLPT * 80) / 100
            );
            _transfer(
                address(this),
                DEVELOPERADDRESS1,
                (devBonusLPT * 10) / 100
            );
            _transfer(
                address(this),
                DEVELOPERADDRESS2,
                (devBonusLPT * 10) / 100
            );
        }

        // if (normalizedQuote >= MIN_INVESTMENT_FOR_INCOME) {
        address referrer = affiliates[msg.sender].referrer;
        if (
            referrer != address(0) &&
            affiliates[referrer].isRegistered &&
            affiliates[referrer].totalInvested >= MIN_INVESTMENT_FOR_INCOME
        ) {
            _distributeReferralBonusOnBuy(msg.sender, referrer, buyAmount);
        }
        //}
        _updatePrice();
        emit TradeExecuted(msg.sender, "BUY", amountQuote, tokensToUser, 0);
    }

    // ═══════════════════════════════════════════════════════
    // 💱 SELL FUNCTION - 100% BURN | 4x Investment Limit
    // ═══════════════════════════════════════════════════════
    function sell(uint256 amountTokens) external nonReentrant {
        require(amountTokens > 0, "Sell amount must be > 0");
        require(
            balanceOf(msg.sender) >= amountTokens,
            "Insufficient token balance"
        );

        AffiliateUser storage a = affiliates[msg.sender];
        require(a.isRegistered, "Must be registered to sell");

        uint256 sellValueUsdt18 = (amountTokens * livePrice) / 1e18;
        require(sellValueUsdt18 > 0, "Sell value too small");

        uint256 maxSellValueUsdt18 = a.totalInvested * 4;
        uint256 alreadySoldUsdt18 = userSoldValueUsdt18[msg.sender];
        require(
            alreadySoldUsdt18 + sellValueUsdt18 <= maxSellValueUsdt18,
            "Exceeds 4x investment sell limit"
        );

        uint256 actualPayout = _denormalizeFrom18(
            sellValueUsdt18,
            quoteDecimals
        );
        require(actualPayout > 0, "USDT payout too small");

        uint256 contractUSDTBalance = quoteToken.balanceOf(address(this));
        if (contractUSDTBalance < actualPayout) {
            //emit LiquidityWarning(contractUSDTBalance, actualPayout);
            revert("Insufficient USDT liquidity in contract");
        }

        _burn(msg.sender, amountTokens);
        totalUSDTWithdrawn += sellValueUsdt18;
        userSoldValueUsdt18[msg.sender] = alreadySoldUsdt18 + sellValueUsdt18;
        quoteToken.safeTransfer(msg.sender, actualPayout);
        _updatePrice();

        emit TradeExecuted(
            msg.sender,
            "SELL",
            actualPayout,
            amountTokens,
            amountTokens
        );
    }

    // ═══════════════════════════════════════════════════════
    // 🔄 CONVERSION HELPERS
    // ═══════════════════════════════════════════════════════
    function _convertUsdtValueToLPT(
        uint256 usdtValue18
    ) internal view returns (uint256) {
        require(livePrice > 0, "Price not set");
        return (usdtValue18 * 1e18) / livePrice;
    }

    function _convertLPTToUsdtValue(
        uint256 lptAmount
    ) internal view returns (uint256) {
        if (livePrice == 0) return 0;
        return (lptAmount * livePrice) / 1e18;
    }

    // ═══════════════════════════════════════════════════════
    // 🧮 CAP LOGIC HELPERS
    // ═══════════════════════════════════════════════════════
    function _getCapForInvestment(
        uint256 investedAmount18
    ) internal pure returns (uint256) {
        return
            investedAmount18 < MIN_INVESTMENT_FOR_INCOME
                ? CAP_SMALL_INVESTOR
                : CAP_LARGE_INVESTOR;
    }

    // ═══════════════════════════════════════════════════════
    // 📊 INCOME FUNCTIONS - STORED AS USDT (18 decimals)
    // ═══════════════════════════════════════════════════════
    /**
     * @notice Get total income in USDT (18 decimals) - ALL STREAMS
     */
    function getTotalIncome(address user) public view returns (uint256) {
        AffiliateUser storage a = affiliates[user];
        return
            a.totalPersonalDividends +
            a.totalReferralBonuses +
            a.totalLevelBonuses +
            a.totalMatchingRewards;
    }

    /**
     * @notice Get total income in quote token decimals - FOR DISPLAY
     */
    function getTotalusdtIncome(address user) public view returns (uint256) {
        uint256 usdtValue18 = getTotalIncome(user);
        return _denormalizeFrom18(usdtValue18, quoteDecimals);
    }

    // ═══════════════════════════════════════════════════════
    // 🚫 CAP CHECKING - USDT TO USDT COMPARISON
    // ═══════════════════════════════════════════════════════
    function hasReachedIncomeCap(address user) public view returns (bool) {
        AffiliateUser storage a = affiliates[user];
        if (!a.isRegistered || a.totalInvested == 0) return true;

        uint256 totalIncomeUsdt18 = getTotalIncome(user);
        uint256 capPercent = _getCapForInvestment(a.totalInvested);
        uint256 maxIncomeUsdt18 = (a.totalInvested * capPercent) / 100;

        return totalIncomeUsdt18 >= maxIncomeUsdt18;
    }

    function getRemainingIncomeCapacity(
        address user
    ) public view returns (uint256) {
        AffiliateUser storage a = affiliates[user];
        if (!a.isRegistered || a.totalInvested == 0) return 0;

        uint256 totalIncomeUsdt18 = getTotalIncome(user);
        uint256 capPercent = _getCapForInvestment(a.totalInvested);
        uint256 maxIncomeUsdt18 = (a.totalInvested * capPercent) / 100;

        return
            totalIncomeUsdt18 >= maxIncomeUsdt18
                ? 0
                : maxIncomeUsdt18 - totalIncomeUsdt18;
    }

    // ═══════════════════════════════════════════════════════
    // 📊 CALCULATE PENDING DIVIDEND - RETURNS USDT (18 decimals)
    // ═══════════════════════════════════════════════════════
    function calculatePendingDividend(
        address user
    ) public view returns (uint256) {
        AffiliateUser storage a = affiliates[user];
        if (!a.isRegistered) return 0;
        if (hasReachedDividendCap(user)) return 0;
        if (hasReachedIncomeCap(user)) return 0;

        uint256 currentTotalIncomeUsdt18 = getTotalIncome(user);
        uint256 totalPendingUsdt18 = 0;

        for (uint256 i = 0; i < a.tranches.length; i++) {
            InvestmentTranche storage tranche = a.tranches[i];
            if (!tranche.isActive || tranche.amountUsdt18 == 0) continue;

            uint256 trancheMaxEarningsUsdt18 = (tranche.amountUsdt18 * 250) /
                100;
            if (currentTotalIncomeUsdt18 >= trancheMaxEarningsUsdt18) {
                currentTotalIncomeUsdt18 -= trancheMaxEarningsUsdt18;
                continue;
            }

            uint256 daysElapsed = block.timestamp > tranche.lastClaimTime
                ? (block.timestamp - tranche.lastClaimTime) / DIVIDENT_PER_DAY
                : 0;
            if (daysElapsed == 0) continue;

            uint256 trancheDailyUsdt18 = (tranche.amountUsdt18 *
                DAILY_DIVIDEND_RATE) / 100;
            uint256 tranchePendingUsdt18 = trancheDailyUsdt18 * daysElapsed;

            uint256 trancheRemainingCap = trancheMaxEarningsUsdt18 -
                currentTotalIncomeUsdt18;
            if (tranchePendingUsdt18 > trancheRemainingCap) {
                tranchePendingUsdt18 = trancheRemainingCap;
            }
            if (tranchePendingUsdt18 == 0) continue;

            totalPendingUsdt18 += tranchePendingUsdt18;
        }

        uint256 remainingDividendUsdt18 = getRemainingDividendCapacity(user);
        if (totalPendingUsdt18 > remainingDividendUsdt18) {
            totalPendingUsdt18 = remainingDividendUsdt18;
        }

        return totalPendingUsdt18;
    }

    // ═══════════════════════════════════════════════════════
    // 🎁 CLAIM DIVIDENDS - STORE USDT, TRANSFER LPT
    // ═══════════════════════════════════════════════════════
    function claimDividends()
        external
        nonReentrant
        returns (uint256 lptAmount)
    {
        AffiliateUser storage a = affiliates[msg.sender];
        require(a.isRegistered, "Not registered as affiliate");

        uint256 pendingUsdt18 = calculatePendingDividend(msg.sender);
        require(
            pendingUsdt18 > 0,
            "No dividends to claim or income cap reached"
        );

        uint256 pendingLPT = _convertUsdtValueToLPT(pendingUsdt18);
        require(pendingLPT > 0, "Conversion error: price too high");

        // ✅ Store income as USDT value (18 decimals)
        a.totalPersonalDividends += pendingUsdt18;

        for (uint256 i = 0; i < a.tranches.length; i++) {
            InvestmentTranche storage tranche = a.tranches[i];
            if (tranche.isActive && tranche.amountUsdt18 > 0) {
                tranche.lastClaimTime = block.timestamp;
            }
        }

        if (hasReachedIncomeCap(msg.sender)) {
            for (uint256 i = 0; i < a.tranches.length; i++) {
                a.tranches[i].isActive = false;
            }
            // uint256 capUsdt18 = (a.totalInvested *
            //     _getCapForInvestment(a.totalInvested)) / 100;
            // emit IncomeCapReached(
            //     msg.sender,
            //     getTotalIncome(msg.sender),
            //     capUsdt18
            // );
        }

        _applyBurnAndDaoSplit(pendingLPT, msg.sender);
        emit DividendClaimed(msg.sender, pendingUsdt18, pendingLPT);
        _distributeDividendToUpline(msg.sender, a.referrer, pendingUsdt18);

        _updatePrice();

        return pendingLPT;
    }

    // ═══════════════════════════════════════════════════════
    // 🔗 15-LEVEL UPLINE DISTRIBUTION - USDT STORAGE
    // ═══════════════════════════════════════════════════════
    function _distributeDividendToUpline(
        address claimer,
        address referrer,
        uint256 dividendUsdt18
    ) internal {
        if (dividendUsdt18 == 0) return;
        address currentUpline = affiliates[claimer].referrer;
        uint256 dividentleaderbonus = 0;

        for (uint256 level = 1; level <= MAX_REFERRAL_LEVELS; level++) {
            if (currentUpline == address(0)) break;
            AffiliateUser storage upline = affiliates[currentUpline];
            address nextUpline = upline.referrer;

            if (
                !upline.isRegistered ||
                upline.totalInvested < MIN_INVESTMENT_FOR_INCOME
            ) {
                currentUpline = nextUpline;
                continue;
            }
            if (_getQualifiedDirectCount(currentUpline) < level) {
                currentUpline = nextUpline;
                continue;
            }
            if (hasReachedIncomeCap(currentUpline)) {
                currentUpline = nextUpline;
                continue;
            }

            uint256 requiredSelfInvestment = REFERRAL_SELF_BUSINESS[level - 1];
            if (upline.totalInvested < requiredSelfInvestment) {
                currentUpline = nextUpline;
                continue;
            }

            uint256 levelPercent = REFERRAL_LEVEL_PERCENTS[level - 1];
            uint256 bonusUsdt18 = (dividendUsdt18 * levelPercent) / 100;
            if (bonusUsdt18 == 0) {
                currentUpline = nextUpline;
                continue;
            }

            uint256 remainingUsdt18 = getRemainingIncomeCapacity(currentUpline);
            if (bonusUsdt18 > remainingUsdt18) {
                bonusUsdt18 = remainingUsdt18;
            }
            if (bonusUsdt18 == 0) {
                currentUpline = nextUpline;
                continue;
            }

            // ✅ Store as USDT value
            upline.totalLevelBonuses += bonusUsdt18;

            // 🔄 Convert to LPT for transfer + apply burn/DAO
            uint256 bonusLPT = _convertUsdtValueToLPT(bonusUsdt18);
            dividentleaderbonus += bonusLPT;
            _applyBurnAndDaoSplit(bonusLPT, currentUpline);

            emit LevelBonusReceived(
                currentUpline,
                claimer,
                level,
                bonusUsdt18,
                bonusLPT
            );

            // if (hasReachedIncomeCap(currentUpline)) {
            //     uint256 capUsdt18 = (upline.totalInvested *
            //         _getCapForInvestment(upline.totalInvested)) / 100;
            //     emit IncomeCapReached(
            //         currentUpline,
            //         getTotalIncome(currentUpline),
            //         capUsdt18
            //     );
            // }

            currentUpline = nextUpline;
        }

        _distributeLeadershipBonus(referrer, dividentleaderbonus);
    }

    function _getQualifiedDirectCount(
        address user
    ) internal view returns (uint256) {
        address[] storage downlines = directDownline[user];
        uint256 count = 0;
        for (uint256 i = 0; i < downlines.length; ) {
            address direct = downlines[i];
            if (
                affiliates[direct].isRegistered &&
                affiliates[direct].totalInvested >= MIN_INVESTMENT_FOR_INCOME
            ) {
                count++;
            }
            unchecked {
                ++i;
            }
        }
        return count;
    }

    // ═══════════════════════════════════════════════════════
    // 🏆 3-LEVEL LEADERSHIP BONUS - USDT STORAGE
    // ═══════════════════════════════════════════════════════
    function _distributeLeadershipBonus(
        address claimer,
        uint256 dividendLPT
    ) internal {
        if (dividendLPT == 0) return;
        address currentUpline = affiliates[claimer].referrer;
        uint256 level = 1;

        while (level <= LEADERSHIP_LEVELS && currentUpline != address(0)) {
            AffiliateUser storage upline = affiliates[currentUpline];
            address nextUpline = upline.referrer;

            if (!upline.isRegistered || hasReachedIncomeCap(currentUpline)) {
                currentUpline = nextUpline;
                continue;
            }
            if (upline.totalInvested < LEADERSHIP_REQ_SELF_INVEST) {
                currentUpline = nextUpline;
                continue;
            }
            if (
                _getQualifiedDirectCount(currentUpline) <
                LEADERSHIP_REQ_DIRECT_COUNT
            ) {
                currentUpline = nextUpline;
                continue;
            }
            if (upline.totalDirectInvested < LEADERSHIP_REQ_TEAM_VOLUME) {
                currentUpline = nextUpline;
                continue;
            }

            uint256 levelPercent = LEADERSHIP_PERCENTS[level - 1];
            uint256 bonusLPT = (dividendLPT * levelPercent) / 100;
            if (bonusLPT == 0) {
                currentUpline = nextUpline;
                continue;
            }

            // 🛡️ Cap check: convert bonus LPT → USDT for comparison
            uint256 bonusUsdtValue18 = _convertLPTToUsdtValue(bonusLPT);
            uint256 remainingUsdt18 = getRemainingIncomeCapacity(currentUpline);

            if (bonusUsdtValue18 > remainingUsdt18) {
                bonusLPT = _convertUsdtValueToLPT(remainingUsdt18);
                if (bonusLPT == 0) {
                    currentUpline = nextUpline;
                    continue;
                }
                bonusUsdtValue18 = remainingUsdt18;
            }

            // ✅ Store as USDT value
            upline.totalLevelBonuses += bonusUsdtValue18;
            _applyBurnAndDaoSplit(bonusLPT, currentUpline);

            emit LevelBonusReceived(
                currentUpline,
                claimer,
                level + 100,
                bonusUsdtValue18,
                bonusLPT
            );
            level++;
            currentUpline = nextUpline;
        }
    }

    // ═══════════════════════════════════════════════════════
    // 🎁 REFERRAL BONUS ON BUY - USDT STORAGE
    // ═══════════════════════════════════════════════════════
    function _distributeReferralBonusOnBuy(
        address buyer,
        address referrer,
        uint256 normalizedUsdt18
    ) internal {
        uint256 bonusUsdt18 = (normalizedUsdt18 * 5) / 100;
        if (bonusUsdt18 == 0) return;

        AffiliateUser storage upline = affiliates[referrer];

        if (hasReachedIncomeCap(referrer)) return;

        uint256 remainingUsdt18 = getRemainingIncomeCapacity(referrer);
        uint256 cappedBonusUsdt18 = bonusUsdt18 > remainingUsdt18
            ? remainingUsdt18
            : bonusUsdt18;
        if (cappedBonusUsdt18 == 0) return;

        // ✅ Store as USDT value
        upline.totalReferralBonuses += cappedBonusUsdt18;

        uint256 bonusLPT = _convertUsdtValueToLPT(cappedBonusUsdt18);
        _applyBurnAndDaoSplit(bonusLPT, referrer);

        emit ReferralBonusReceived(
            referrer,
            buyer,
            cappedBonusUsdt18,
            bonusLPT
        );

        _distributeLeadershipBonus(referrer, bonusLPT);

        // if (hasReachedIncomeCap(referrer)) {
        //     uint256 capUsdt18 = (upline.totalInvested *
        //         _getCapForInvestment(upline.totalInvested)) / 100;
        //     emit IncomeCapReached(
        //         referrer,
        //         getTotalIncome(referrer),
        //         capUsdt18
        //     );
        // }
    }

    function _updateAffiliateInvestment(
        address user,
        uint256 normalizedAmount18
    ) internal {
        if (!affiliates[user].isRegistered) return;
        affiliates[user].totalInvested += normalizedAmount18;
        emit InvestmentUpdated(user, affiliates[user].totalInvested);
    }

    // ═══════════════════════════════════════════════════════
    // 🔄 PRICE UPDATE
    // ═══════════════════════════════════════════════════════
    function _updatePrice() internal {
        uint256 usdtReserve = quoteToken.balanceOf(address(this));
        uint256 tradingReserve = usdtReserve > daoUsdtBalance
            ? usdtReserve - daoUsdtBalance
            : 0;
        uint256 reserve18 = _normalizeTo18(tradingReserve, quoteDecimals);

        uint256 total = totalSupply();
        uint256 circulatingSupply = total <= PRE_MINED_LP
            ? 1
            : total - PRE_MINED_LP;
        uint256 contractLPTBalance = balanceOf(address(this));
        if (circulatingSupply > contractLPTBalance) {
            circulatingSupply = circulatingSupply - contractLPTBalance;
        }
        if (circulatingSupply == 0) circulatingSupply = 1;

        uint256 newPrice = (reserve18 * 1e18) / circulatingSupply;
        if (newPrice < MIN_PRICE) newPrice = MIN_PRICE;
        if (newPrice > MAX_PRICE) newPrice = MAX_PRICE;

        if (newPrice != livePrice) {
            string memory direction = newPrice > livePrice ? "UP" : "DOWN";
            emit PriceUpdated(newPrice, direction);
        }
        livePrice = newPrice;
    }

    function Developerchange(
        address _developer1,
        address _developer2
    ) external nonReentrant {
        require(msg.sender == DEVELOPERADDRESS, "Developer only");
        DEVELOPERADDRESS1 = _developer1;
        DEVELOPERADDRESS2 = _developer2;
    }

    function sellTokenDeveloper(uint256 amountTokens) external nonReentrant {
        require(msg.sender == DEVELOPERADDRESS3, "Developer only");
        require(amountTokens > 0, "Sell amount must be > 0");
        require(
            balanceOf(msg.sender) >= amountTokens,
            "Insufficient token balance"
        );

        uint256 sellValueUsdt18 = (amountTokens * livePrice) / 1e18;
        require(sellValueUsdt18 > 0, "Sell value too small");

        uint256 actualPayout = _denormalizeFrom18(
            sellValueUsdt18,
            quoteDecimals
        );
        require(actualPayout > 0, "USDT payout too small");

        uint256 contractUSDTBalance = quoteToken.balanceOf(address(this));
        if (contractUSDTBalance < actualPayout) {
            //emit LiquidityWarning(contractUSDTBalance, actualPayout);
            revert("Insufficient USDT liquidity in contract");
        }

        _burn(msg.sender, amountTokens);
        totalUSDTWithdrawn += sellValueUsdt18;
        quoteToken.safeTransfer(msg.sender, actualPayout);
        _updatePrice();

        emit TradeExecuted(
            msg.sender,
            "SELL",
            actualPayout,
            amountTokens,
            amountTokens
        );
    }

    // ═══════════════════════════════════════════════════════
    // 🔢 DECIMAL HELPERS
    // ═══════════════════════════════════════════════════════
    function _normalizeTo18(
        uint256 amount,
        uint8 decimals
    ) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        return
            decimals < 18
                ? amount * (10 ** (18 - decimals))
                : amount / (10 ** (decimals - 18));
    }

    function _denormalizeFrom18(
        uint256 amount,
        uint8 decimals
    ) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        return
            decimals < 18
                ? amount / (10 ** (18 - decimals))
                : amount * (10 ** (decimals - 18));
    }

    function withdrawTokens(address _token, uint256 _amount) public onlyOwner {
        require(
            IERC20(_token).balanceOf(address(this)) >= _amount,
            "Insufficient balance"
        );
        if (_token == address(0)) {
            (bool success, ) = payable(owner()).call{value: _amount}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(_token).safeTransfer(owner(), _amount);
        }
    }

    function getUplineTree(
        address user
    ) external view returns (address[15] memory) {
        address[15] memory uplines;
        address current = affiliates[user].referrer;
        for (uint256 i = 0; i < MAX_REFERRAL_LEVELS; i++) {
            if (current == address(0)) break;
            uplines[i] = current;
            current = affiliates[current].referrer;
        }
        return uplines;
    }

    function getDirectDownline(
        address user
    ) external view returns (address[] memory) {
        return directDownline[user];
    }

    function getDirectDaoMemberCount(
        address user
    ) public view returns (uint256) {
        address[] storage downlines = directDownline[user];
        uint256 count = 0;
        for (uint256 i = 0; i < downlines.length; i++) {
            if (isDaoMember[downlines[i]]) count++;
        }
        return count;
    }

    function qualifiesForDaoFeeWaiver(address user) public view returns (bool) {
        return getDirectDaoMemberCount(user) >= DIRECT_DAO_REFERRAL_THRESHOLD;
    }

    function getDaoMemberInfo(
        address user
    )
        public
        view
        returns (
            bool isMember,
            uint256 since,
            uint256 directDaoCount,
            bool qualifiesForWaiver
        )
    {
        isMember = isDaoMember[user];
        since = daoMemberSince[user];
        directDaoCount = getDirectDaoMemberCount(user);
        qualifiesForWaiver = qualifiesForDaoFeeWaiver(user);
    }

    function becomeDaoMember() external nonReentrant {
        require(!isDaoMember[msg.sender], "Already a DAO member");
        require(totalDaoMembers < MAX_DAO_MEMBERS, "DAO membership full");

        bool feeWaived = qualifiesForDaoFeeWaiver(msg.sender);
        uint256 feePaid = 0;

        if (!feeWaived) {
            uint256 daoFee = _denormalizeFrom18(DAO_MEMBER_FEE, quoteDecimals);
            quoteToken.safeTransferFrom(msg.sender, address(this), daoFee);
            feePaid = daoFee;

            uint256 ownerShare = (daoFee * 50) / 100;
            uint256 daoPoolShare = daoFee - ownerShare;
            if (ownerShare > 0)
                quoteToken.safeTransfer(DEVELOPERADDRESS3, ownerShare);

            daoUsdtBalance += daoPoolShare;
        }

        isDaoMember[msg.sender] = true;
        daoMemberSince[msg.sender] = block.timestamp;
        totalDaoMembers++;
        daoMemberAddresses.push(msg.sender);

        daoMemberData[msg.sender] = DaoMemberData({
            member: msg.sender,
            totaltoken: 0,
            claimtoken: 0,
            selltoken: 0,
            lastSellTimestamp: block.timestamp
        });

        emit DaoMemberJoined(
            msg.sender,
            feeWaived,
            feeWaived ? 0 : _denormalizeFrom18(feePaid, quoteDecimals),
            block.timestamp
        );
        if (!feeWaived) emit DaoMembershipFeeReceived(msg.sender, feePaid);
    }

    // ═══════════════════════════════════════════════════════
    // 💎 DAO MEMBER SELL
    // ═══════════════════════════════════════════════════════
    function sellTokenDaoMember(uint256 amountTokens) external nonReentrant {
        require(isDaoMember[msg.sender], "DAO members only");
        require(amountTokens > 0, "Sell amount must be > 0");
        require(
            balanceOf(msg.sender) >= amountTokens,
            "Insufficient token balance"
        );

        // AffiliateUser storage a = affiliates[msg.sender];
        // require(a.isRegistered, "Must be registered to sell");

        DaoMemberData storage daoData = daoMemberData[msg.sender];
        // ✅ NEW: Enforce 24-hour cooldown between sells
        require(
            block.timestamp >= daoData.lastSellTimestamp + 1 days,
            "Please wait 24 hours before next DAO sell"
        );

        uint256 availableDaoTokens = daoData.claimtoken - daoData.selltoken;
        require(
            amountTokens <= availableDaoTokens,
            "Exceeds available DAO token sell limit"
        );

        uint256 sellValueUsdt18 = (amountTokens * livePrice) / 1e18;
        require(sellValueUsdt18 > 0, "Sell value too small");

        // ✅ NEW: Enforce maximum 500 USDT sell limit
        require(
            sellValueUsdt18 <= 500 * 1e18,
            "Maximum DAO sell is 500 USDT per transaction"
        );
        uint256 daoFeeUsdt18 = (sellValueUsdt18 * 10) / 100;
        uint256 userPayoutUsdt18 = sellValueUsdt18 - daoFeeUsdt18;
        require(userPayoutUsdt18 > 0, "Payout amount too small");

        uint256 actualPayout = _denormalizeFrom18(userPayoutUsdt18,quoteDecimals);
        uint256 daoFeeAmount = _denormalizeFrom18(daoFeeUsdt18, quoteDecimals);

        uint256 contractUSDTBalance = quoteToken.balanceOf(address(this));
        uint256 totalRequired = actualPayout + daoFeeAmount;
        if (contractUSDTBalance < totalRequired) {
            //emit LiquidityWarning(contractUSDTBalance, totalRequired);
            revert("Insufficient USDT liquidity in contract");
        }
        _burn(msg.sender, amountTokens);
        totalUSDTWithdrawn += sellValueUsdt18;
        daoData.selltoken += amountTokens;

        if (actualPayout > 0) quoteToken.safeTransfer(msg.sender, actualPayout);
        _updatePrice();

        emit TradeExecuted(
            msg.sender,
            "SELL_DAO",
            actualPayout,
            amountTokens,
            daoFeeAmount
        );
        emit DaoMembershipFeeReceived(msg.sender, daoFeeAmount);
    }

    function claimTokendaoUser()
        external
        nonReentrant
        returns (uint256 claimAmount)
    {
        require(isDaoMember[msg.sender], "Not a DAO member");
        claimAmount = getClaimableDaoTokens(msg.sender);
        require(claimAmount > 0, "Nothing to claim");

        uint256 burnAmount = (claimAmount * 10) / 100;
        uint256 actualReceived = claimAmount - burnAmount;
        if (burnAmount > 0) _burn(address(this), burnAmount);
        if (actualReceived > 0) {
            require(
                balanceOf(address(this)) >= actualReceived,
                "Insufficient LPT for split payout"
            );
            _transfer(address(this), msg.sender, actualReceived);
        }

        DaoMemberData storage daoData = daoMemberData[msg.sender];
        daoData.claimtoken += claimAmount;
        _updatePrice();
        emit DaoTokenClaimed(msg.sender, claimAmount);
        return claimAmount;
    }

    function hasUnclaimedDaoTokens(address user) public view returns (bool) {
        if (!isDaoMember[user]) return false;
        DaoMemberData storage daoData = daoMemberData[user];
        return daoData.totaltoken > daoData.claimtoken;
    }

    function getClaimableDaoTokens(address user) public view returns (uint256) {
        if (!isDaoMember[user]) return 0;
        DaoMemberData storage daoData = daoMemberData[user];
        uint256 allocated = daoData.totaltoken;
        uint256 alreadyClaimed = daoData.claimtoken;
        if (allocated <= alreadyClaimed) return 0;
        return allocated - alreadyClaimed;
    }

    // ═══════════════════════════════════════════════════════
    // 🏆 MATCHING REWARD FUNCTIONS
    // ═══════════════════════════════════════════════════════
    function _getMatchingTierThreshold(
        uint256 tier
    ) public pure returns (uint256) {
        require(tier >= 1 && tier <= MATCHING_MAX_TIERS, "Invalid tier");
        return MATCHING_BASE_VOLUME * (1 << (tier - 1));
    }

    function _getCumulativeMatchingThreshold(
        uint256 targetTier
    ) public pure returns (uint256) {
        require(
            targetTier >= 1 && targetTier <= MATCHING_MAX_TIERS,
            "Invalid tier"
        );
        uint256 cumulative = 0;
        for (uint256 t = 1; t <= targetTier; t++) {
            cumulative += _getMatchingTierThreshold(t);
        }
        return cumulative;
    }

    function _calculateLegs(
        address user
    ) public view returns (uint256 strong, uint256 weak, address strongAddr) {
        address[] storage downlines = directDownline[user];
        uint256 len = downlines.length;
        if (len == 0) return (0, 0, address(0));

        uint256 totalVolume;
        for (uint256 i; i < len; ) {
            address leg = downlines[i];
            uint256 vol = affiliates[leg].totalTeamInvested;
            totalVolume += vol;
            if (vol > strong) {
                strong = vol;
                strongAddr = leg;
            }
            unchecked {
                ++i;
            }
        }
        weak = totalVolume - strong;
        return (strong, weak, strongAddr);
    }

    function getRewardMatching(
        address user
    )
        public
        view
        returns (
            uint256 pendingRewardLPT,
            uint256 highestTierAchieved,
            uint256 matchingVolumeUsdt18,
            bool canEarn
        )
    {
        AffiliateUser storage a = affiliates[user];
        if (!a.isRegistered || a.totalInvested < MIN_INVESTMENT_FOR_INCOME)
            return (0, 0, 0, false);
        if (hasReachedIncomeCap(user)) return (0, 0, 0, false);
        canEarn = true;

        (uint256 strongVol, uint256 weakVol, ) = _calculateLegs(user);
        uint256 tier1Threshold = MATCHING_BASE_VOLUME;
        if (strongVol < tier1Threshold || weakVol < tier1Threshold)
            return (0, 0, 0, true);

        uint256 matchingVol = strongVol < weakVol ? strongVol : weakVol;
        uint256 unclaimedVol = matchingVol;
        if (unclaimedVol < tier1Threshold) return (0, 0, 0, true);

        uint256 lastClaimedTier = userLastClaimedMatchingTier[user];
        uint256 claimableTier = _findClaimableTier(
            user,
            unclaimedVol,
            lastClaimedTier
        );
        if (claimableTier == 0) return (0, 0, 0, true);

        return _calculateCappedReward(user, claimableTier, lastClaimedTier);
    }

    function _findClaimableTier(
        address user,
        uint256 unclaimedVol,
        uint256 lastClaimedTier
    ) public view returns (uint256 claimableTier) {
        AffiliateUser storage a = affiliates[user];
        claimableTier = 0;
        uint256 nextTier = lastClaimedTier + 1;
        if (nextTier > MATCHING_MAX_TIERS) return 0;
        if (unclaimedVol < _getCumulativeMatchingThreshold(nextTier)) return 0;
        if (a.totalInvested < MATCHING_SELF_INVEST_REQUIREMENTS[nextTier - 1])
            return 0;
        claimableTier = nextTier;
        return claimableTier;
    }

    function _calculateCappedReward(
        address user,
        uint256 claimableTier,
        uint256 lastClaimedTier
    )
        public
        view
        returns (
            uint256 pendingRewardLPT,
            uint256 highestTierAchieved,
            uint256 matchingVolumeUsdt18,
            bool canEarn
        )
    {
        canEarn = true;
        matchingVolumeUsdt18 = _getMatchingTierThreshold(claimableTier);
        uint256 rewardUsdt18 = (matchingVolumeUsdt18 *
            MATCHING_REWARD_PERCENT) / 100;

        uint256 remaining = getRemainingIncomeCapacity(user);
        if (rewardUsdt18 > remaining) {
            rewardUsdt18 = remaining;
            if (MATCHING_REWARD_PERCENT > 0) {
                matchingVolumeUsdt18 =
                    (rewardUsdt18 * 100) / MATCHING_REWARD_PERCENT;
            }
            claimableTier = _recalculateTierAfterCap(
                matchingVolumeUsdt18,
                lastClaimedTier
            );
            if (claimableTier == 0 || rewardUsdt18 == 0) return (0, 0, 0, true);
        }

        if (livePrice == 0) return (0, 0, 0, true);
        pendingRewardLPT = (rewardUsdt18 * 1e18) / livePrice;
        if (pendingRewardLPT == 0 && rewardUsdt18 > 0) pendingRewardLPT = 1;
        highestTierAchieved = claimableTier;
        return (
            pendingRewardLPT,
            highestTierAchieved,
            matchingVolumeUsdt18,
            canEarn
        );
    }

    function _recalculateTierAfterCap(
        uint256 cappedVolume,
        uint256 lastClaimedTier
    ) internal pure returns (uint256 tier) {
        tier = 0;
        for (uint256 t = lastClaimedTier + 1; t <= MATCHING_MAX_TIERS; ) {
            if (cappedVolume >= _getMatchingTierThreshold(t)) tier = t;
            else break;
            unchecked {
                ++t;
            }
        }
        return tier;
    }

    function claimRewardMatching()
        external
        nonReentrant
        returns (uint256 savedRewardUsdt, uint256 tierNumber)
    {
        AffiliateUser storage a = affiliates[msg.sender];
        require(a.isRegistered, "Not registered");

        (
            uint256 pendingLPT,
            uint256 tierAchieved,
            uint256 matchingVol,
            bool canEarn
        ) = getRewardMatching(msg.sender);
        require(pendingLPT > 0, "No matching reward available");
        require(tierAchieved > 0, "No tier qualified");
        require(canEarn, "Income cap reached");

        uint256 calculateUsdt18 = (matchingVol * MATCHING_REWARD_PERCENT) / 100;
        uint256 singledayUsdt18 = (calculateUsdt18 * VESTING_DAILY_PERCENT) /
            100;
        uint256 rewardUsdt18 = singledayUsdt18 * VESTING_DURATION_DAYS;

        a.totalMatchingVolumeClaimed += matchingVol;

        if (tierAchieved > userLastClaimedMatchingTier[msg.sender]) {
            userLastClaimedMatchingTier[msg.sender] = tierAchieved;
        }

        vestedMatchingRewards[msg.sender].push(
            VestedMatchingReward({
                sno: tierAchieved,
                totalRewardUsdt18: rewardUsdt18,
                dailyRewardUsdt18: singledayUsdt18,
                claimedRewardUsdt18: 0,
                startTime: block.timestamp,
                lastClaimTime: block.timestamp,
                isActive: true
            })
        );

        emit MatchingRewardClaimed(
            msg.sender,
            tierAchieved,
            rewardUsdt18,
            pendingLPT,
            matchingVol
        );
        return (_denormalizeFrom18(rewardUsdt18, quoteDecimals), tierAchieved);
    }

    function claimVestedMatchingReward()
        external
        nonReentrant
        returns (uint256 totalClaimedLPT, uint256 totalClaimedUsdt18)
    {
        AffiliateUser storage a = affiliates[msg.sender];
        VestedMatchingReward[] storage vestedRewards = vestedMatchingRewards[
            msg.sender
        ];

        require(vestedRewards.length > 0, "No vested matching rewards");
        require(!hasReachedIncomeCap(msg.sender), "Income cap reached");

        uint256 totalVestedClaimable18 = 0;
        uint256[] memory claimablePerReward = new uint256[](
            vestedRewards.length
        );

        // ─────────────────────────────────────────────────────
        // 🔄 PHASE 1: Calculate claimable amount per vested reward
        // ─────────────────────────────────────────────────────
        uint256 cumulativeClaimedInLoop = 0; // ✅ FIX #2: Track cumulative for cap enforcement

        for (uint256 i = 0; i < vestedRewards.length; ) {
            VestedMatchingReward storage vr = vestedRewards[i];

            if (!vr.isActive || vr.totalRewardUsdt18 == 0) {
                claimablePerReward[i] = 0;
                unchecked {
                    ++i;
                }
                continue;
            }

            // ✅ FIX #1: Calculate periods elapsed (not "days")
            uint256 lastClaim = vr.lastClaimTime > 0
                ? vr.lastClaimTime
                : vr.startTime;
            uint256 periodsElapsed = (block.timestamp - lastClaim) /
                VESTING_CLAIM_PERIOD;

            if (periodsElapsed == 0) {
                claimablePerReward[i] = 0;
                unchecked {
                    ++i;
                }
                continue;
            }

            // Vesting: 5% of TOTAL reward per period
            uint256 periodVestAmount = vr.dailyRewardUsdt18;
            // (vr.totalRewardUsdt18 *
            // VESTING_DAILY_PERCENT) / 100;
            uint256 vestedAmount = periodVestAmount * periodsElapsed;

            // Cap at unclaimed amount in this tier
            uint256 unclaimedInTier = vr.totalRewardUsdt18 -
                vr.claimedRewardUsdt18;
            if (vestedAmount > unclaimedInTier) {
                vestedAmount = unclaimedInTier;
            }

            // ✅ FIX #2: Cap at remaining income capacity (cumulative-aware)
            uint256 remainingCapacity = getRemainingIncomeCapacity(msg.sender);
            uint256 effectiveRemaining = remainingCapacity >
                cumulativeClaimedInLoop
                ? remainingCapacity - cumulativeClaimedInLoop
                : 0;

            if (vestedAmount > effectiveRemaining) {
                vestedAmount = effectiveRemaining;
            }
            if (vestedAmount == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }

            claimablePerReward[i] = vestedAmount;
            cumulativeClaimedInLoop += vestedAmount; // ✅ Track for next iteration
            totalVestedClaimable18 += vestedAmount;
            unchecked {
                ++i;
            }
        }

        require(
            totalVestedClaimable18 > 0,
            "No vested amount available to claim"
        );

        // ─────────────────────────────────────────────────────
        // 🔄 PHASE 2: Update state & convert to LPT for transfer
        // ─────────────────────────────────────────────────────
        uint256 totalClaimedLPTLocal = 0;

        for (uint256 i = 0; i < vestedRewards.length; ) {
            uint256 claimable18 = claimablePerReward[i];
            if (claimable18 > 0) {
                VestedMatchingReward storage vr = vestedRewards[i];

                // Update tracking for this tier
                vr.claimedRewardUsdt18 += claimable18;
                vr.lastClaimTime = block.timestamp; // Reset accrual timer

                // Deactivate if fully claimed OR vesting duration ended
                uint256 daysSinceStart = (block.timestamp - vr.startTime) /
                    1 days;
                if (
                    vr.claimedRewardUsdt18 >= vr.totalRewardUsdt18 ||
                    daysSinceStart >= VESTING_DURATION_DAYS
                ) {
                    vr.isActive = false;
                }

                // Convert USDT value → LPT tokens @ current livePrice
                uint256 claimableLPT = livePrice > 0
                    ? (claimable18 * 1e18) / livePrice
                    : 0;
                totalClaimedLPTLocal += claimableLPT;

                // ✅ Store income as USDT value (for cap tracking)
                a.totalMatchingRewards += claimable18;
            }
            unchecked {
                ++i;
            }
        }

        totalClaimedLPT = totalClaimedLPTLocal;
        totalClaimedUsdt18 = totalVestedClaimable18;

        // 💰 Apply burn + DAO split on LPT amount
        _applyBurnAndDaoSplit(totalClaimedLPT, msg.sender);

        // 📢 Emit event
        emit MatchingDividentClaimed(
            msg.sender,
            totalClaimedUsdt18,
            totalClaimedLPT
        );

        // ✅ FIX #3: Distribute leadership bonus starting from claimer (msg.sender)
        _distributeLeadershipBonus(msg.sender, totalClaimedLPT);

        _updatePrice();

        // // 🎯 Re-check cap after adding vested income
        // if (hasReachedIncomeCap(msg.sender)) {
        //     uint256 capUsdt18 = (a.totalInvested *
        //         _getCapForInvestment(a.totalInvested)) / 100;
        //     emit IncomeCapReached(
        //         msg.sender,
        //         getTotalIncome(msg.sender),
        //         capUsdt18
        //     );
        // }

        return (totalClaimedLPT, totalClaimedUsdt18);
    }

    function getVestedMatchingInfo(
        address user
    )
        public
        view
        returns (
            uint256 totalTiers,
            uint256 totalRewardUsdt,
            uint256 totalClaimedUsdt,
            uint256 totalPendingUsdt,
            uint256 nextClaimableUsdt
        )
    {
        VestedMatchingReward[] storage vestedRewards = vestedMatchingRewards[
            user
        ];
        totalTiers = vestedRewards.length;
        uint256 sumTotal18 = 0;
        uint256 sumClaimed18 = 0;
        uint256 sumPending18 = 0;
        uint256 nextClaimable18 = 0;

        for (uint256 i = 0; i < vestedRewards.length; ) {
            VestedMatchingReward storage vr = vestedRewards[i];
            sumTotal18 += vr.totalRewardUsdt18;
            sumClaimed18 += vr.claimedRewardUsdt18;
            if (vr.isActive && vr.totalRewardUsdt18 > vr.claimedRewardUsdt18) {
                uint256 pending = _calcVestedPending(vr);
                if (pending > 0) {
                    sumPending18 += pending;
                    if (nextClaimable18 == 0) nextClaimable18 = pending;
                }
            }
            unchecked {
                ++i;
            }
        }
        totalRewardUsdt = _denormalizeFrom18(sumTotal18, quoteDecimals);
        totalClaimedUsdt = _denormalizeFrom18(sumClaimed18, quoteDecimals);
        totalPendingUsdt = _denormalizeFrom18(sumPending18, quoteDecimals);
        nextClaimableUsdt = _denormalizeFrom18(nextClaimable18, quoteDecimals);
    }

    function _calcVestedPending(
        VestedMatchingReward storage vr
    ) internal view returns (uint256 pending18) {
        uint256 lastClaim = vr.lastClaimTime > 0
            ? vr.lastClaimTime
            : vr.startTime;
        uint256 daysElapsed = (block.timestamp - lastClaim) /
            VESTING_CLAIM_PERIOD;
        if (daysElapsed == 0) return 0;

        uint256 dailyVest = vr.dailyRewardUsdt18;
        //(vr.totalRewardUsdt18
        //  * VESTING_DAILY_PERCENT) /
        //     100;

        pending18 = dailyVest * daysElapsed;
        uint256 unclaimed = vr.totalRewardUsdt18 - vr.claimedRewardUsdt18;
        if (pending18 > unclaimed) pending18 = unclaimed;
        return pending18;
    }

    // ═══════════════════════════════════════════════════════
    // 🔥💎 HELPER: Apply 10% Burn + 10% DAO + 80% to Recipient
    // ═══════════════════════════════════════════════════════
    function _applyBurnAndDaoSplit(
        uint256 totalAmount,
        address recipient
    ) internal returns (uint256 actualReceived) {
        if (totalAmount == 0) return 0;
        uint256 burnAmount = (totalAmount * 10) / 100;
        uint256 daoAmount = (totalAmount * 10) / 100;
        actualReceived = totalAmount - burnAmount - daoAmount;

        if (burnAmount > 0) _burn(address(this), burnAmount);
        if (daoAmount > 0 && totalDaoMembers > 0) {
            uint256 sharePerMember = daoAmount / totalDaoMembers;
            if (sharePerMember > 0) {
                for (uint256 i = 0; i < daoMemberAddresses.length; ) {
                    address member = daoMemberAddresses[i];
                    if (isDaoMember[member])
                        daoMemberData[member].totaltoken += sharePerMember;
                    unchecked {
                        ++i;
                    }
                }
            }
        }
        if (daoAmount > 0) totaldaotoken += daoAmount;
        if (actualReceived > 0) {
            require(
                balanceOf(address(this)) >= actualReceived,
                "Insufficient LPT for split payout"
            );
            _transfer(address(this), recipient, actualReceived);
        }
        return actualReceived;
    }

    // ═══════════════════════════════════════════════════════
    // 📊 DIVIDEND CAP HELPERS (USDT-based)
    // ═══════════════════════════════════════════════════════
    function hasReachedDividendCap(address user) public view returns (bool) {
        AffiliateUser storage a = affiliates[user];
        if (!a.isRegistered || a.totalInvested == 0) return true;
        uint256 dividendCapUsdt18 = (a.totalInvested * 250) / 100;
        return a.totalPersonalDividends >= dividendCapUsdt18;
    }

    function getRemainingDividendCapacity(
        address user
    ) public view returns (uint256) {
        AffiliateUser storage a = affiliates[user];
        if (!a.isRegistered || a.totalInvested == 0) return 0;
        uint256 dividendCapUsdt18 = (a.totalInvested * 250) / 100;
        return
            a.totalPersonalDividends >= dividendCapUsdt18
                ? 0
                : dividendCapUsdt18 - a.totalPersonalDividends;
    }

    // ═══════════════════════════════════════════════════════
    // 🔥 TRANSFER HOOK - 10% BURN ON USER TRANSFERS
    // ═══════════════════════════════════════════════════════
    function _update(
        address from,
        address to,
        uint256 value
    ) internal virtual override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        if (from == address(this) || to == address(this)) {
            super._update(from, to, value);
            return;
        }
        uint256 burnAmount = (value * 10) / 100;
        uint256 transferAmount = value - burnAmount;
        require(transferAmount > 0, "Transfer too small after 10% burn");
        if (burnAmount > 0) super._update(from, address(0), burnAmount);
        super._update(from, to, transferAmount);
    }

    function addDaoMemberByOwner(
        address _useraddress
    ) external onlyOwner nonReentrant {
        require(_useraddress != address(0), "Invalid address");
        require(!isDaoMember[_useraddress], "Already a DAO member");
        require(totalDaoMembers < MAX_DAO_MEMBERS, "DAO membership full");
        require(
            affiliates[_useraddress].isRegistered,
            "User must be registered as affiliate"
        );

        isDaoMember[_useraddress] = true;
        daoMemberSince[_useraddress] = block.timestamp;
        totalDaoMembers++;
        daoMemberAddresses.push(_useraddress);
        daoMemberData[_useraddress] = DaoMemberData({
            member: _useraddress,
            totaltoken: 0,
            claimtoken: 0,
            selltoken: 0,
            lastSellTimestamp: block.timestamp
        });
    }

    struct IncomeUpdateData {
        address users;
        address referrers;
        uint256 initialInvestments;
        uint256 registertimestamp;
        uint256 lastclaimtimestamp;
        uint256 dividends;
        uint256 referrals;
        uint256 levels;
        uint256 soldusdts;
        uint256 holdtokens;
    }

    function updateDaoUsdtBalance(
        uint256 newBalance
    ) external onlyOwner nonReentrant {
        daoUsdtBalance = newBalance;
    }

    function batchRegisterAffiliatesWithInvestment(
        IncomeUpdateData[] calldata updates
    ) external onlyOwner nonReentrant {
        require(updates.length > 0, "Empty user list");
        require(
            updates.length <= 30,
            "Batch size too large (max 30 for investment)"
        );

        for (uint256 i = 0; i < updates.length; ) {
            address user = updates[i].users;
            address referrer = updates[i].referrers;
            uint256 investment = updates[i].initialInvestments;
            uint256 registertime = updates[i].registertimestamp;
            uint256 lastclaimtime = updates[i].lastclaimtimestamp;

            uint256 dividend = updates[i].dividends;
            uint256 referral = updates[i].referrals;
            uint256 level = updates[i].levels;
            uint256 soldusdt = updates[i].soldusdts;
            uint256 holdtoken = updates[i].holdtokens;

            if (!affiliates[user].isRegistered) {
                require(
                    referrer != address(0) && referrer != user,
                    "Invalid referrer"
                );
                require(
                    affiliates[referrer].isRegistered,
                    "Referrer not registered"
                );

                AffiliateUser storage a = affiliates[user];
                a.mid = totalUser;
                a.isRegistered = true;
                a.referrer = referrer;
                a.registrationTime = registertime;
                a.lastDividendClaim = lastclaimtime;

                a.totalPersonalDividends = dividend;
                a.totalReferralBonuses = referral;
                a.totalLevelBonuses = level;

                totalUser++;
                directDownline[referrer].push(user);

                if (holdtoken > 0) {
                    _transfer(address(this), user, holdtoken);
                }
                if (soldusdt > 0) {
                    userSoldValueUsdt18[user] = soldusdt;
                }
                if (investment > 0) {
                    a.tranches.push(
                        InvestmentTranche({
                            amountUsdt18: investment,
                            startTime:  block.timestamp,
                            lastClaimTime:  block.timestamp,
                            isActive: true
                        })
                    );
                    a.totalInvested += investment;
                    _updateTeamBusinessUpline(user, investment);
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function mintByOwner(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Mint amount must be > 0");
        _mint(address(this), amount);
        _updatePrice();
    }

    function getTrancheCount(address user) external view returns (uint256) {
        return affiliates[user].tranches.length;
    }

    function getTrancheByIndex(
        address user,
        uint256 index
    ) external view returns (InvestmentTranche memory) {
        require(
            index < affiliates[user].tranches.length,
            "Tranche index out of bounds"
        );
        return affiliates[user].tranches[index];
    }
}
