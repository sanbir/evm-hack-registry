// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.4;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/Interfaces.sol";
import "./OptionMath.sol";

/**
 * @author Heisenberg
 * @title Buffer Options
 * @notice Creates ERC721 Options
 */

contract BufferBinaryOptions is
    IBufferBinaryOptions,
    ReentrancyGuard,
    ERC721,
    AccessControl
{
    using SafeERC20 for ERC20;
    uint256 public nextTokenId = 0;
    uint256 public totalMarketOI;
    bool public isPaused;
    uint16 public stepSize = 25; // Factor of 1e2
    string public override token0;
    string public override token1;

    ILiquidityPool public override pool;
    IOptionsConfig public override config;
    IReferralStorage public referral;
    AssetCategory public assetCategory;
    ERC20 public override tokenX;

    mapping(uint256 => Option) public override options;
    mapping(address => uint256[]) public userOptionIds;
    bytes32 public constant ROUTER_ROLE = keccak256("ROUTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    constructor() ERC721("Buffer", "BFR") {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /************************************************
     *  INITIALIZATION FUNCTIONS
     ***********************************************/

    function initialize(
        ERC20 _tokenX,
        ILiquidityPool _pool,
        IOptionsConfig _config,
        IReferralStorage _referral,
        AssetCategory _category,
        string memory _token0,
        string memory _token1
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(tokenX) == address(0)) {
            tokenX = _tokenX;
            pool = _pool;
            config = _config;
            referral = _referral;
            assetCategory = _category;
            token0 = _token0;
            token1 = _token1;
            _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
            emit CreateOptionsContract(
                address(config),
                address(pool),
                address(tokenX),
                token0,
                token1,
                assetCategory
            );
        } else {
            revert("Already initialized");
        }
    }

    function assetPair() external view override returns (string memory) {
        return string(abi.encodePacked(token0, token1));
    }

    /**
     * @notice Grants complete approval from the pool
     */
    function approvePoolToTransferTokenX() public {
        tokenX.approve(address(pool), ~uint256(0));
    }

    /**
     * @notice Pauses/Unpauses the option creation
     */
    function setIsPaused() public {
        if (hasRole(PAUSER_ROLE, msg.sender)) {
            isPaused = true;
        } else if (hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            isPaused = !isPaused;
        } else {
            revert("Wrong role");
        }
        emit Pause(isPaused);
    }

    /************************************************
     *  ROUTER ONLY FUNCTIONS
     ***********************************************/

    /**
     * @notice Creates an option with the specified parameters
     * @dev Can only be called by router
     */
    function createFromRouter(
        OptionParams calldata optionParams,
        uint256 queuedTime
    ) external override onlyRole(ROUTER_ROLE) returns (uint256 optionID) {
        Option memory option = Option(
            State.Active,
            optionParams.strike,
            optionParams.amount,
            optionParams.amount,
            optionParams.amount / 2,
            queuedTime + optionParams.period,
            optionParams.totalFee,
            queuedTime
        );
        optionID = _generateTokenId();
        userOptionIds[optionParams.user].push(optionID);
        options[optionID] = option;
        _mint(optionParams.user, optionID);

        uint256 referrerFee = _processReferralRebate(
            optionParams.user,
            optionParams.totalFee,
            optionParams.amount,
            optionParams.referralCode,
            optionParams.baseSettlementFeePercentage
        );

        uint256 settlementFee = optionParams.totalFee -
            option.premium -
            referrerFee;

        tokenX.safeTransfer(
            config.settlementFeeDisbursalContract(),
            settlementFee
        );

        pool.lock(optionID, option.lockedAmount, option.premium);
        IBooster booster = IBooster(config.boosterContract());
        if (
            booster.getBoostPercentage(optionParams.user, address(tokenX)) > 0
        ) {
            booster.updateUserBoost(optionParams.user, address(tokenX));
        }
        IOptionStorage(config.optionStorageContract()).save(
            optionID,
            address(this),
            optionParams.user
        );
        totalMarketOI += optionParams.totalFee;
        IPoolOIStorage(config.poolOIStorageContract()).updatePoolOI(
            true,
            optionParams.totalFee
        );
        emit Create(
            optionParams.user,
            optionID,
            settlementFee,
            optionParams.totalFee
        );
    }

    /**
     * @notice Unlocks/Exercises the active options
     * @dev Can only be called router
     */
    function unlock(
        uint256 optionID,
        uint256 closingPrice,
        uint256 closingTime,
        bool isAbove
    ) external override onlyRole(ROUTER_ROLE) {
        require(_exists(optionID), "O10");
        Option storage option = options[optionID];
        require(option.state == State.Active, "O5");

        if (
            (isAbove && closingPrice > option.strike) ||
            (!isAbove && closingPrice < option.strike) ||
            option.expiration > closingTime
        ) {
            _exercise(optionID, closingPrice, closingTime, isAbove);
        } else {
            option.state = State.Expired;
            pool.unlock(optionID);
            _burn(optionID);
            emit Expire(optionID, option.premium, closingPrice, isAbove);
        }
        totalMarketOI -= option.totalFee;
        IPoolOIStorage(config.poolOIStorageContract()).updatePoolOI(
            false,
            option.totalFee
        );
    }

    /************************************************
     *  READ ONLY FUNCTIONS
     ***********************************************/

    /**
     * @notice Returns decimals of the pool token
     */
    function decimals() public view returns (uint256) {
        return tokenX.decimals();
    }

    /**
     * @notice Calculates the fees for buying an option
     */
    function fees(
        uint256 amount,
        address user,
        string calldata referralCode,
        uint256 baseSettlementFeePercentage
    )
        public
        view
        override
        returns (uint256 total, uint256 settlementFee, uint256 premium)
    {
        uint256 settlementFeePercentage = getSettlementFeePercentage(
            referral.codeOwner(referralCode),
            user,
            baseSettlementFeePercentage
        );
        (total, settlementFee, premium) = _fees(
            amount,
            settlementFeePercentage
        );
    }

    function isStrikeValid(
        uint256 slippage,
        uint256 currentPrice,
        uint256 strike
    ) external pure override returns (bool) {
        if (
            (currentPrice <= (strike * (1e4 + slippage)) / 1e4) &&
            (currentPrice >= (strike * (1e4 - slippage)) / 1e4)
        ) {
            return true;
        } else return false;
    }

    function getMaxTradeSize() public view returns (uint256) {
        return
            min(
                IPoolOIConfig(config.poolOIConfigContract()).getMaxPoolOI(),
                IMarketOIConfig(config.marketOIConfigContract()).getMaxMarketOI(
                    totalMarketOI
                )
            );
    }

    function getMaxOI() public view returns (uint256) {
        return
            min(
                IPoolOIConfig(config.poolOIConfigContract()).getPoolOICap(),
                IMarketOIConfig(config.marketOIConfigContract())
                    .getMarketOICap()
            );
    }

    /**
     * @notice Runs all the checks on the option parameters and
     * returns the revised amount and fee
     */
    function evaluateParams(
        OptionParams calldata optionParams,
        uint256 slippage
    ) external view override returns (uint256 amount, uint256 revisedFee) {
        require(slippage <= 5e2, "O34"); // 5% is the max slippage a user can use
        require(optionParams.period >= config.minPeriod(), "O21");
        require(optionParams.period <= config.maxPeriod(), "O25");
        require(optionParams.totalFee >= config.minFee(), "O35");
        require(!isPaused, "O33");
        require(
            assetCategory == AssetCategory.Crypto ||
                ICreationWindowContract(config.creationWindowContract())
                    .isInCreationWindow(optionParams.period),
            "O30"
        );

        uint256 maxTradeSize = getMaxTradeSize();
        require(maxTradeSize > 0, "O36");
        revisedFee = min(optionParams.totalFee, maxTradeSize);

        if (revisedFee < optionParams.totalFee) {
            require(optionParams.allowPartialFill, "O29");
        }

        // Calculate the amount here from the revised fees
        uint256 settlementFeePercentage = getSettlementFeePercentage(
            referral.codeOwner(optionParams.referralCode),
            optionParams.user,
            optionParams.baseSettlementFeePercentage
        );
        (uint256 unitFee, , ) = _fees(
            10 ** decimals(),
            settlementFeePercentage
        );
        amount = (revisedFee * 10 ** decimals()) / unitFee;
    }

    /************************************************
     * ERC721 FUNCTIONS
     ***********************************************/

    function _generateTokenId() internal returns (uint256) {
        return nextTokenId++;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function ownerOf(
        uint256 tokenId
    )
        public
        view
        virtual
        override(ERC721, IBufferBinaryOptions)
        returns (address)
    {
        return super.ownerOf(tokenId);
    }

    /************************************************
     *  INTERNAL OPTION UTILITY FUNCTIONS
     ***********************************************/

    /**
     * @notice Calculates the fees for buying an option
     */
    function _fees(
        uint256 amount,
        uint256 settlementFeePercentage
    )
        internal
        pure
        returns (uint256 total, uint256 settlementFee, uint256 premium)
    {
        // Probability for ATM options will always be 0.5 due to which we can skip using BSM
        premium = amount / 2;
        total = (premium * 1e4) / (1e4 - settlementFeePercentage);
        settlementFee = total - premium;
    }

    /**
     * @notice Exercises the ITM options
     */
    function _exercise(
        uint256 optionID,
        uint256 closingPrice,
        uint256 closingTime,
        bool isAbove
    ) internal returns (uint256 profit) {
        Option storage option = options[optionID];
        address user = ownerOf(optionID);
        if (option.expiration > closingTime) {
            profit =
                (option.lockedAmount *
                    OptionMath.blackScholesPriceBinary(
                        config.iv(),
                        option.strike,
                        closingPrice,
                        option.expiration - closingTime,
                        true,
                        isAbove
                    )) /
                1e8;
        } else {
            profit = option.lockedAmount;
        }
        pool.send(optionID, user, profit);

        // Burn the option
        _burn(optionID);
        option.state = State.Exercised;
        emit Exercise(user, optionID, profit, closingPrice, isAbove);
    }

    /**
     * @notice Sends the referral rebate to the referrer and
     * updates the stats in the referral storage contract
     */
    function _processReferralRebate(
        address user,
        uint256 totalFee,
        uint256 amount,
        string calldata referralCode,
        uint256 baseSettlementFeePercentage
    ) internal returns (uint256 referrerFee) {
        address referrer = referral.codeOwner(referralCode);
        if (
            referrer != user &&
            referrer != address(0) &&
            referrer.code.length == 0
        ) {
            bool isReferralValid = true;
            referrerFee = ((totalFee *
                referral.referrerTierDiscount(
                    referral.referrerTier(referrer)
                )) / (1e4 * 1e3));
            if (referrerFee > 0) {
                tokenX.safeTransfer(referrer, referrerFee);

                (uint256 formerUnitFee, , ) = _fees(
                    10 ** decimals(),
                    baseSettlementFeePercentage
                );
                emit UpdateReferral(
                    user,
                    referrer,
                    isReferralValid,
                    totalFee,
                    referrerFee,
                    (((formerUnitFee * amount) / 10 ** decimals()) - totalFee),
                    referralCode
                );
            }
        }
    }

    /**
     * @notice Calculates the discount to be applied on settlement fee based on
     * referrer tiers
     */
    function _getReferralDiscount(
        address referrer,
        address user
    ) public view returns (uint256 referralDiscount) {
        uint256 maxStep;
        if (
            referrer != user &&
            referrer != address(0) &&
            referrer.code.length == 0
        ) {
            uint8 step = referral.referrerTierStep(
                referral.referrerTier(referrer)
            );
            maxStep += step;
        }
        referralDiscount = (stepSize * maxStep);
    }

    /**
     * @notice Returns the discounted settlement fee
     */
    function getSettlementFeePercentage(
        address referrer,
        address user,
        uint256 baseSettlementFeePercentage
    ) public view returns (uint256 settlementFeePercentage) {
        settlementFeePercentage = baseSettlementFeePercentage;
        uint256 referralDiscount = _getReferralDiscount(referrer, user);
        settlementFeePercentage =
            settlementFeePercentage -
            referralDiscount -
            IBooster(config.boosterContract()).getBoostPercentage(
                user,
                address(tokenX)
            );
    }
}
