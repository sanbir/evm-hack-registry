// SPDX-License-Identifier: BUSL-1.1
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

pragma solidity 0.8.4;

interface IBooster {
    struct UserBoostTrades {
        uint256 totalBoostTrades;
        uint256 totalBoostTradesUsed;
    }

    function getUserBoostData(
        address user,
        address token
    ) external view returns (UserBoostTrades memory);

    function updateUserBoost(address user, address token) external;

    function getBoostPercentage(
        address user,
        address token
    ) external view returns (uint256);

    event BuyCoupon(address indexed token, address indexed user, uint256 price);
    event SetPrice(uint256 couponPrice);
    event SetBoostPercentage(uint256 boost);
    event UpdateBoostTradesUser(address indexed user, address indexed token);
    event Configure(uint8[4] nftTierDiscounts);
}

interface IAccountRegistrar {
    struct AccountMapping {
        address oneCT;
        uint256 nonce;
    }
    event RegisterAccount(
        address indexed user,
        address indexed oneCT,
        uint256 nonce
    );
    event DeregisterAccount(address indexed account, uint256 nonce);

    function accountMapping(
        address
    ) external view returns (address oneCT, uint256 nonce);

    function registerAccount(
        address oneCT,
        address user,
        bytes memory signature
    ) external;
}

interface IBufferRouter {
    struct QueuedTrade {
        address user;
        uint256 totalFee;
        uint256 period;
        address targetContract;
        uint256 strike;
        uint256 slippage;
        bool allowPartialFill;
        string referralCode;
        uint256 traderNFTId;
        uint256 settlementFee;
        bool isLimitOrder;
        bool isTradeResolved;
        uint256 optionId;
        bool isEarlyCloseAllowed;
    }

    struct OptionInfo {
        uint256 queueId;
        address signer;
        uint256 nonce;
    }

    struct SignInfo {
        bytes signature;
        uint256 timestamp;
    }

    struct TradeParams {
        uint256 queueId;
        uint256 totalFee;
        uint256 period;
        address targetContract;
        uint256 strike;
        uint256 slippage;
        bool allowPartialFill;
        string referralCode;
        uint256 traderNFTId;
        uint256 price;
        uint256 settlementFee;
        bool isLimitOrder;
        uint256 limitOrderExpiry;
        SignInfo settlementFeeSignInfo;
        SignInfo userSignInfo;
        SignInfo publisherSignInfo;
    }

    struct Register {
        address oneCT;
        bytes signature;
        bool shouldRegister;
    }

    struct Permit {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
        bool shouldApprove;
    }
    struct OpenTxn {
        TradeParams tradeParams;
        Register register;
        Permit permit;
        address user;
    }

    struct AccountMapping {
        address oneCT;
        uint256 nonce;
    }

    struct CloseTradeParams {
        uint256 optionId;
        address targetContract;
        uint256 closingPrice;
        bool isAbove;
        SignInfo marketDirectionSignInfo;
        SignInfo publisherSignInfo;
    }

    struct CloseAnytimeParams {
        CloseTradeParams closeTradeParams;
        SignInfo userSignInfo;
    }

    struct IdMapping {
        uint256 id;
        bool isSet;
    }

    event OpenTrade(
        address indexed account,
        uint256 queueId,
        uint256 optionId,
        address targetContract
    );
    event CancelTrade(address indexed account, uint256 queueId, string reason);
    event FailUnlock(uint256 optionId, address targetContract, string reason);
    event FailResolve(uint256 queueId, string reason);
    event ContractRegistryUpdated(address targetContract, bool register);
    event ApproveRouter(
        address user,
        uint256 nonce,
        uint256 value,
        uint256 deadline
    );
}

interface IBufferBinaryOptions {
    event Create(
        address indexed account,
        uint256 indexed id,
        uint256 settlementFee,
        uint256 totalFee
    );

    event Exercise(
        address indexed account,
        uint256 indexed id,
        uint256 profit,
        uint256 priceAtExpiration,
        bool isAbove
    );
    event Expire(
        uint256 indexed id,
        uint256 premium,
        uint256 priceAtExpiration,
        bool isAbove
    );
    event Pause(bool isPaused);
    event UpdateReferral(
        address user,
        address referrer,
        bool isReferralValid,
        uint256 totalFee,
        uint256 referrerFee,
        uint256 rebate,
        string referralCode
    );

    function createFromRouter(
        OptionParams calldata optionParams,
        uint256 queuedTime
    ) external returns (uint256 optionID);

    function evaluateParams(
        OptionParams calldata optionParams,
        uint256 slippage
    ) external returns (uint256 amount, uint256 revisedFee);

    function tokenX() external view returns (ERC20);

    function pool() external view returns (ILiquidityPool);

    function config() external view returns (IOptionsConfig);

    function token0() external view returns (string memory);

    function token1() external view returns (string memory);

    function ownerOf(uint256 id) external view returns (address);

    function assetPair() external view returns (string memory);

    function fees(
        uint256 amount,
        address user,
        string calldata referralCode,
        uint256 baseSettlementFeePercent
    )
        external
        view
        returns (uint256 total, uint256 settlementFee, uint256 premium);

    function isStrikeValid(
        uint256 slippage,
        uint256 currentPrice,
        uint256 strike
    ) external pure returns (bool);

    enum State {
        Inactive,
        Active,
        Exercised,
        Expired
    }

    enum AssetCategory {
        Forex,
        Crypto,
        Commodities
    }
    struct OptionExpiryData {
        uint256 optionId;
        uint256 priceAtExpiration;
    }

    event CreateOptionsContract(
        address config,
        address pool,
        address tokenX,
        string token0,
        string token1,
        AssetCategory category
    );
    struct Option {
        State state;
        uint256 strike;
        uint256 amount;
        uint256 lockedAmount;
        uint256 premium;
        uint256 expiration;
        uint256 totalFee;
        uint256 createdAt;
    }
    struct OptionParams {
        uint256 strike;
        uint256 amount;
        uint256 period;
        bool allowPartialFill;
        uint256 totalFee;
        address user;
        string referralCode;
        uint256 baseSettlementFeePercentage;
    }

    function options(
        uint256 optionId
    )
        external
        view
        returns (
            State state,
            uint256 strike,
            uint256 amount,
            uint256 lockedAmount,
            uint256 premium,
            uint256 expiration,
            uint256 totalFee,
            uint256 createdAt
        );

    function unlock(
        uint256 optionID,
        uint256 priceAtExpiration,
        uint256 closingTime,
        bool isAbove
    ) external;
}

interface ILiquidityPool {
    struct LockedAmount {
        uint256 timestamp;
        uint256 amount;
    }
    struct ProvidedLiquidity {
        uint256 unlockedAmount;
        LockedAmount[] lockedAmounts;
        uint256 nextIndexForUnlock;
    }
    struct LockedLiquidity {
        uint256 amount;
        uint256 premium;
        bool locked;
    }
    event Profit(uint256 indexed id, uint256 amount);
    event Loss(uint256 indexed id, uint256 amount);
    event Provide(address indexed account, uint256 amount, uint256 writeAmount);
    event UpdateMaxLiquidity(uint256 indexed maxLiquidity);
    event Withdraw(
        address indexed account,
        uint256 amount,
        uint256 writeAmount
    );

    function unlock(uint256 id) external;

    function totalTokenXBalance() external view returns (uint256 amount);

    function availableBalance() external view returns (uint256 balance);

    function send(uint256 id, address account, uint256 amount) external;

    function lock(uint256 id, uint256 tokenXAmount, uint256 premium) external;
}

interface IOptionsConfig {
    event UpdateMaxPeriod(uint32 value);
    event UpdateMinPeriod(uint32 value);
    event UpdateEarlyCloseThreshold(uint32 earlyCloseThreshold);
    event UpdateEarlyClose(bool isAllowed);
    event UpdateSettlementFeeDisbursalContract(address value);
    event UpdatetraderNFTContract(address value);
    event UpdateMinFee(uint256 value);
    event UpdateOptionStorageContract(address value);
    event UpdateCreationWindowContract(address value);
    event UpdatePlatformFee(uint256 _platformFee);
    event UpdatePoolOIStorageContract(address _poolOIStorageContract);
    event UpdatePoolOIConfigContract(address _poolOIConfigContract);
    event UpdateMarketOIConfigContract(address _marketOIConfigContract);
    event UpdateIV(uint256 _iv);
    event UpdateBoosterContract(address _boosterContract);

    function settlementFeeDisbursalContract() external view returns (address);

    function maxPeriod() external view returns (uint32);

    function minPeriod() external view returns (uint32);

    function minFee() external view returns (uint256);

    function platformFee() external view returns (uint256);

    function optionStorageContract() external view returns (address);

    function creationWindowContract() external view returns (address);

    function poolOIStorageContract() external view returns (address);

    function poolOIConfigContract() external view returns (address);

    function marketOIConfigContract() external view returns (address);

    function iv() external view returns (uint256);

    function earlyCloseThreshold() external view returns (uint32);

    function isEarlyCloseAllowed() external view returns (bool);

    function boosterContract() external view returns (address);
}

interface ITraderNFT {
    function tokenOwner(uint256 id) external view returns (address user);

    function tokenTierMappings(uint256 id) external view returns (uint8 tier);

    event UpdateTiers(uint256[] tokenIds, uint8[] tiers, uint256[] batchIds);
}

interface IFakeTraderNFT {
    function tokenOwner(uint256 id) external view returns (address user);

    function tokenTierMappings(uint256 id) external view returns (uint8 tier);

    event UpdateNftBasePrice(uint256 nftBasePrice);
    event UpdateMaxNFTMintLimits(uint256 maxNFTMintLimit);
    event UpdateBaseURI(string baseURI);
    event Claim(address indexed account, uint256 claimTokenId);
    event Mint(address indexed account, uint256 tokenId, uint8 tier);
}

interface IReferralStorage {
    function codeOwner(string memory _code) external view returns (address);

    function traderReferralCodes(address) external view returns (string memory);

    function getTraderReferralInfo(
        address user
    ) external view returns (string memory, address);

    function setTraderReferralCode(address user, string memory _code) external;

    function setReferrerTier(address, uint8) external;

    function referrerTierStep(
        uint8 referralTier
    ) external view returns (uint8 step);

    function referrerTierDiscount(
        uint8 referralTier
    ) external view returns (uint32 discount);

    function referrerTier(address referrer) external view returns (uint8 tier);

    struct ReferrerData {
        uint256 tradeVolume;
        uint256 rebate;
        uint256 trades;
    }

    struct ReferreeData {
        uint256 tradeVolume;
        uint256 rebate;
    }

    struct ReferralData {
        ReferrerData referrerData;
        ReferreeData referreeData;
    }

    struct Tier {
        uint256 totalRebate; // e.g. 2400 for 24%
        uint256 discountShare; // 5000 for 50%/50%, 7000 for 30% rebates/70% discount
    }

    event UpdateTraderReferralCode(address indexed account, string code);
    event UpdateReferrerTier(address referrer, uint8 tierId);
    event RegisterCode(address indexed account, string code);
    event SetCodeOwner(
        address indexed account,
        address newAccount,
        string code
    );
}

interface IOptionStorage {
    function save(
        uint256 optionId,
        address optionsContract,
        address user
    ) external;
}

interface ICreationWindowContract {
    function isInCreationWindow(uint256 period) external view returns (bool);
}

interface IPoolOIStorage {
    function updatePoolOI(bool isIncreased, uint256 interest) external;

    function totalPoolOI() external view returns (uint256);
}

interface IPoolOIConfig {
    function getMaxPoolOI() external view returns (uint256);

    function getPoolOICap() external view returns (uint256);
}

interface IMarketOIConfig {
    function getMaxMarketOI(
        uint256 currentMarketOI
    ) external view returns (uint256);

    function getMarketOICap() external view returns (uint256);
}
