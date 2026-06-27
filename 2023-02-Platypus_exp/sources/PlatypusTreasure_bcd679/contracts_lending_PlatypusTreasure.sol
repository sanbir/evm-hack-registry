// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol';
import '@rari-capital/solmate/src/utils/SafeTransferLib.sol';
import '@rari-capital/solmate/src/utils/FixedPointMathLib.sol';
import '@rari-capital/solmate/src/tokens/ERC20.sol';

import '../interfaces/IUSP.sol';
import '../interfaces/IPriceOracleGetter.sol';
import '../interfaces/IMasterPlatypusV4.sol';
import '../interfaces/IPool.sol';

interface LiquidationCallback {
    function callback(
        uint256 uspAmount,
        uint256 collateralAmount,
        address initiator,
        bytes calldata data
    ) external;
}

/**
 * @title PlatypusTreasure
 * @notice Platypuses can make use of their collateral to mint USP
 * @dev If the user's health factor is below 1, anyone can liquidate his/her position.
 * Protocol will charge debt interest from borrowers and protocol revenue from liquidation.
 */
contract PlatypusTreasure is OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /**
     * Structs
     */

    /// @notice A struct for treasure settings
    struct MarketSetting {
        IAsset uspLp; // USP lp address of main pool
        uint32 mininumBorrowAmount; // minimum USP borrow amount in whole token. 9 digits.
        uint8 k; // param for dynamic interest rate: c^k / 100
        bool borrowPaused; // pause USP borrowing for all collaterals
        bool liquidationPaused;
        uint16 kickIncentive; // keeper incentive. USP amount in whole token.
    }

    /// @notice A struct for collateral settings
    struct CollateralSetting {
        /* storage slot (read-only) */
        // borrow, repay
        uint40 borrowCap; // USP borrow cap in whole token. 12 digits.
        uint16 collateralFactor; // collateral factor; base 10000
        uint16 borrowFee; // fees that will be charged upon minting USP (0.3% in USP); base 10000
        bool isStable; // we perform additional check to stables: borrowing USP is now allowed when it is about to depeg
        // liquidation
        uint16 liquidationThreshold; // collateral liquidation threshold (greater than `collateralFactor`); base 10000
        uint16 liquidationPenalty; // liquidation penalty for liquidators. base 10000
        uint16 auctionStep; // price of the auction decrease per `auctionStep` seconds to `auctionFactor`
        uint16 auctionFactor; // base 10000
        bool liquidationPaused;
        // others
        uint8 decimals; // cache of decimal of the collateral. also used to check if collateral exists
        bool isLp;
        // 88 bits unused
        /* storage slot */
        uint128 borrowedShare; // borrowed USP share. 20.18 fixed point integer
        /* LP infos */
        IMasterPlatypusV4 masterPlatypus; // MasterPlatypus Address
        uint8 pid; // cache of pid in the master platypus
        // uint256 uspToRaise; // USP amount that should be filled by liquidation
    }

    /// @notice A struct for users collateral position
    struct Position {
        /* storage slot */
        uint128 debtShare;
        // non-LP infos
        // don't read this storage directly, instead, read `_getCollateralAmount()`
        uint128 collateralAmount;
    }

    /// @notice A struct to preview a user's collateral position; external view-only
    struct PositionView {
        uint256 collateralAmount;
        uint256 collateralUSD;
        uint256 borrowLimitUSP;
        uint256 liquidateLimitUSP;
        uint256 debtAmountUSP;
        uint256 debtShare;
        uint256 healthFactor; // `healthFactor` is 0 if `debtAmountUSP` is 0
        bool liquidable;
    }

    struct Auction {
        // storage slot
        uint128 uspAmount; // USP to raise
        uint128 collateralAmount; // collateral that is being liquidated
        // storage slot
        ERC20 token; // address collateral
        uint48 index; // index in activeAuctions
        uint40 startTime; // starting time of the auction
        // storage slot
        address user; // liquidatee
        uint96 startPrice; // starting price of the auction. 10.18 fixed point
    }

    /**
     * Events
     */

    /// @notice Add collateral token
    event AddCollateralToken(ERC20 indexed token);
    /// @notice Update collateral token setting
    event SetCollateralToken(ERC20 indexed token, CollateralSetting setting);

    /// @notice An event thats emitted when fee is collected at minting, interest accrual and liquidation
    event Accrue(uint256 interest);
    /// @notice An event thats emitted when user deposits collateral
    event AddCollateral(address indexed user, ERC20 indexed token, uint256 amount);
    /// @notice An event thats emitted when user withdraws collateral
    event RemoveCollateral(address indexed user, ERC20 indexed token, uint256 amount);
    /// @notice An event thats emitted when user borrows USP
    event Borrow(address indexed user, ERC20 indexed collateral, uint256 uspAmount);
    /// @notice An event thats emitted when user repays USP
    event Repay(address indexed user, ERC20 indexed collateral, uint256 uspAmount);

    event StartAuction(
        uint256 indexed id,
        address indexed user,
        ERC20 indexed token,
        uint256 collateralAmount,
        uint256 uspAmount
    );
    event BuyCollateral(
        uint256 indexed id,
        address indexed user,
        ERC20 indexed token,
        uint256 collateralAmount,
        uint256 uspAmount
    );
    event BadDebt(uint256 indexed id, address indexed user, ERC20 indexed token, uint256 amount);

    /*///////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error PlatypusTreasure_ZeroAddress();
    error PlatypusTreasure_InvalidMasterPlatypus();
    error PlatypusTreasure_InvalidRatio();
    error PlatypusTreasure_InvalidPid();
    error PlatypusTreasure_InvalidToken();
    error PlatypusTreasure_InvalidAmount();
    error PlatypusTreasure_MinimumBorrowAmountNotSatisfied();
    error PlatypusTreasure_ExceedCollateralFactor();
    error PlatypusTreasure_ExceedCap();
    error PlatypusTreasure_ExceedHalfRepayLimit();
    error PlatypusTreasure_NotLiquidable();
    error PlatypusTreasure_BorrowPaused();
    error PlatypusTreasure_BorrowDisallowed();
    error PlatypusTreasure_InvalidMarketSetting();

    error Liquidation_Paused();
    error Liquidation_Invalid_Auction_Id();
    error Liquidation_Exceed_Max_Price(uint256 currentPrice);
    error Liquidation_Liquidator_Should_Take_All_Collateral();

    error Uint96_Overflow();
    error Uint112_Overflow();
    error Uint128_Overflow();

    /**
     * Storage
     */
    /// @notice Platypus Treasure settings
    MarketSetting public marketSetting;
    /// @notice Collateral price oracle address (returns price in usd: 8 decimals)
    IPriceOracleGetter public oracle;

    /// @notice collateral tokens in array
    ERC20[] public collateralTokens;
    /// @notice collateral settings
    mapping(ERC20 => CollateralSetting) public collateralSettings; // token => collateral setting
    /// @notice users collateral position
    mapping(ERC20 => mapping(address => Position)) internal userPositions; // collateral => user => position

    /* storage slot for _accrue() */
    /// @notice total borrowed amount accrued so far - 15.18 fixed point integer
    uint112 public totalDebtAmount;
    /// @notice total protocol fees accrued so far - 15.18 fixed point integer
    uint112 public feesToBeCollected;
    /// @notice last time of debt accrued
    uint32 public lastAccrued;

    /// @notice address that should receive liquidation fee, interest and USP minting fee
    address public feeTo;
    /// @notice total borrowed portion
    uint128 public totalDebtShare;
    /// @notice Amount of USP needed to cover debt + fees of active auctions
    uint128 public unbackedUspAmount;

    /// @notice USP token address
    IUSP public usp;
    uint48 public totalAuctions;

    /// @notice a list of active auctions
    /// @dev each slot is able to store 5 activeAuctions
    uint48[] public activeAuctions;
    mapping(uint256 => Auction) public auctions; // id => auction data

    /**
     * Constructor, Modifers, Getters and Setters
     */

    /**
     * @notice Initializer.
     * @param _usp USP token address
     * @param _oracle collateral token price oracle
     * @param _marketSetting treasure settings
     */
    function initialize(
        IUSP _usp,
        IPriceOracleGetter _oracle,
        MarketSetting calldata _marketSetting,
        address _feeTo
    ) external initializer {
        if (address(_usp) == address(0)) revert PlatypusTreasure_ZeroAddress();
        if (address(_oracle) == address(0)) revert PlatypusTreasure_ZeroAddress();
        if (_feeTo == address(0)) revert PlatypusTreasure_ZeroAddress();
        if (_marketSetting.k == 0 || _marketSetting.k > 10 || address(_marketSetting.uspLp) == address(0))
            revert PlatypusTreasure_InvalidMarketSetting();

        __Ownable_init();
        __ReentrancyGuard_init_unchained();

        usp = _usp;
        oracle = _oracle;
        marketSetting = _marketSetting;
        feeTo = _feeTo;
    }

    /**
     * @notice returns the number of all collateral tokens
     * @return number of collateral tokens
     */
    function getCollateralTokens() external view returns (ERC20[] memory) {
        return collateralTokens;
    }

    /**
     * @notice returns the number of all collateral tokens
     * @return number of collateral tokens
     */
    function collateralTokensLength() external view returns (uint256) {
        return collateralTokens.length;
    }

    /**
     * @dev pause borrow
     */
    function pauseBorrow() external onlyOwner {
        marketSetting.borrowPaused = true;
    }

    /**
     * @dev unpause borrow
     */
    function unpauseBorrow() external onlyOwner {
        marketSetting.borrowPaused = false;
    }

    /**
     * @notice Update interest param k
     * @dev only owner can call this function
     */
    function setInterestParam(uint8 _k) external onlyOwner {
        if (_k == 0 || _k > 10) revert PlatypusTreasure_InvalidMarketSetting();
        marketSetting.k = _k;
    }

    function setkickIncentive(uint16 _kickIncentive) external onlyOwner {
        marketSetting.kickIncentive = _kickIncentive;
    }

    /**
     * @notice Update mininumBorrowAmount
     * @dev only owner can call this function
     */
    function setMinimumBorrowAmount(uint32 _mininumBorrowAmount) external onlyOwner {
        marketSetting.mininumBorrowAmount = _mininumBorrowAmount;
    }

    /**
     * @notice Stops `startAuction` for all collaterals
     */
    function pauseAllLiquidations() external onlyOwner {
        marketSetting.liquidationPaused = true;
    }

    /**
     * @notice Resume `startAuction` for all collaterals
     */
    function resumeAllLiquidations() external onlyOwner {
        marketSetting.liquidationPaused = false;
    }

    /**
     * @notice Stops `startAuction`
     */
    function pauseLiquidations(ERC20 _token) external onlyOwner {
        _checkCollateralExist(_token);
        collateralSettings[_token].liquidationPaused = true;
    }

    /**
     * @notice Resume `startAuction`
     */
    function resumeLiquidations(ERC20 _token) external onlyOwner {
        _checkCollateralExist(_token);
        collateralSettings[_token].liquidationPaused = false;
    }

    /**
     * @notice add or update LP collateral setting
     * @dev only owner can call this function
     * @param _token collateral token address
     * @param _borrowCap borrow cap in whole token
     * @param _collateralFactor borrow limit
     * @param _borrowFee borrow fee of USP
     * @param _liquidationThreshold liquidation threshold rate
     * @param _liquidationPenalty liquidation penalty
     * @param _masterPlatypus address of master platypus
     */
    function setLpCollateralToken(
        ERC20 _token,
        uint40 _borrowCap,
        uint16 _collateralFactor,
        uint16 _borrowFee,
        bool _isStable,
        uint16 _liquidationThreshold,
        uint16 _liquidationPenalty,
        uint16 _auctionStep,
        uint16 _auctionFactor,
        IMasterPlatypusV4 _masterPlatypus
    ) external onlyOwner {
        if (address(_token) == address(0)) revert PlatypusTreasure_ZeroAddress();
        if (
            _collateralFactor >= 10000 ||
            _liquidationThreshold >= 10000 ||
            _liquidationPenalty >= 10000 ||
            _borrowFee >= 10000 ||
            _liquidationThreshold < _collateralFactor ||
            _auctionStep == 0 ||
            _auctionFactor <= 1000
        ) revert PlatypusTreasure_InvalidRatio();

        if (address(_masterPlatypus) == address(0)) revert PlatypusTreasure_ZeroAddress();
        if (address(_masterPlatypus.platypusTreasure()) != address(this))
            revert PlatypusTreasure_InvalidMasterPlatypus();

        uint256 pid = _masterPlatypus.getPoolId(address(_token));
        if (pid > type(uint8).max) revert PlatypusTreasure_InvalidPid();

        // check if collateral exists
        bool isNewSetting = collateralSettings[_token].decimals == 0;

        // add a new collateral
        collateralSettings[_token] = CollateralSetting({
            borrowCap: _borrowCap,
            collateralFactor: _collateralFactor,
            borrowFee: _borrowFee,
            isStable: _isStable,
            liquidationThreshold: _liquidationThreshold,
            liquidationPenalty: _liquidationPenalty,
            auctionStep: _auctionStep,
            auctionFactor: _auctionFactor,
            liquidationPaused: collateralSettings[_token].liquidationPaused,
            decimals: ERC20(_token).decimals(),
            isLp: true,
            borrowedShare: collateralSettings[_token].borrowedShare,
            masterPlatypus: _masterPlatypus,
            pid: uint8(pid)
        });

        if (isNewSetting) {
            collateralTokens.push(_token);
            emit AddCollateralToken(_token);
        }
        emit SetCollateralToken(_token, collateralSettings[_token]);
    }

    /**
     * @notice add or update LP collateral setting
     * @dev only owner can call this function
     * @param _token collateral token address
     * @param _borrowCap borrow cap in whole token
     * @param _collateralFactor borrow limit
     * @param _borrowFee borrow fee of USP
     * @param _liquidationThreshold liquidation threshold rate
     * @param _liquidationPenalty liquidation penalty
     */
    function setRawCollateralToken(
        ERC20 _token,
        uint40 _borrowCap,
        uint16 _collateralFactor,
        uint16 _borrowFee,
        bool _isStable,
        uint16 _liquidationThreshold,
        uint16 _liquidationPenalty,
        uint16 _auctionStep,
        uint16 _auctionFactor
    ) external onlyOwner {
        if (address(_token) == address(0)) revert PlatypusTreasure_ZeroAddress();
        if (
            _collateralFactor >= 10000 ||
            _liquidationThreshold >= 10000 ||
            _liquidationPenalty >= 10000 ||
            _borrowFee >= 10000 ||
            _borrowFee == 0 ||
            _liquidationThreshold < _collateralFactor ||
            _auctionStep == 0 ||
            _auctionFactor <= 1000
        ) revert PlatypusTreasure_InvalidRatio();

        // check if collateral exists
        bool isNewSetting = collateralSettings[_token].decimals == 0;

        // add a new collateral
        collateralSettings[_token] = CollateralSetting({
            borrowCap: _borrowCap,
            collateralFactor: _collateralFactor,
            borrowFee: _borrowFee,
            isStable: _isStable,
            liquidationThreshold: _liquidationThreshold,
            liquidationPenalty: _liquidationPenalty,
            auctionStep: _auctionStep,
            auctionFactor: _auctionFactor,
            liquidationPaused: collateralSettings[_token].liquidationPaused,
            decimals: ERC20(_token).decimals(),
            isLp: false,
            borrowedShare: collateralSettings[_token].borrowedShare,
            masterPlatypus: IMasterPlatypusV4(address(0)),
            pid: 0
        });

        if (isNewSetting) {
            collateralTokens.push(_token);
            emit AddCollateralToken(_token);
        }
        emit SetCollateralToken(_token, collateralSettings[_token]);
    }

    /**
     * Public/External Functions
     */

    /**
     * @notice collect protocol fees accrued so far
     * @dev safe from reentrancy
     */
    function collectFee() external returns (uint256 feeCollected) {
        _accrue();

        // collect protocol fees in USP
        feeCollected = feesToBeCollected;
        feesToBeCollected = 0;
        usp.mint(feeTo, feeCollected);
    }

    /**
     * @notice Add non-LP tokens as collateral, e.g PTP or AVAX
     * @dev Tokens will be stored in this contract, won't go to master platypus
     * Follows Checks-Effects-Interactions
     * @param _token address of collateral token
     * @param _amount collateral amounts to deposit
     */
    function addCollateral(ERC20 _token, uint256 _amount) public {
        CollateralSetting storage setting = collateralSettings[_token];
        // check if collateral exists and is valid
        _checkCollateralExist(_token);
        if (setting.isLp) revert PlatypusTreasure_InvalidToken();
        if (_amount == 0) revert PlatypusTreasure_InvalidAmount();

        // update collateral position
        Position storage position = userPositions[_token][msg.sender];
        position.collateralAmount += toUint128(_amount);

        emit AddCollateral(msg.sender, _token, _amount);
        ERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
    }

    /**
     * @notice Remove non-LP collaterals, e.g PTP or AVAX
     * @dev Transfer collateral tokens to the user
     * Follows Checks-Effects-Interactions
     * @param _token address of collateral token
     * @param _amount collateral amounts to withdraw
     */
    function removeCollateral(ERC20 _token, uint256 _amount) public {
        CollateralSetting storage setting = collateralSettings[_token];
        // check if collateral exists and is valid
        _checkCollateralExist(_token);
        if (setting.isLp) revert PlatypusTreasure_InvalidToken();
        if (_amount == 0) revert PlatypusTreasure_InvalidAmount();

        // update collateral position
        Position storage position = userPositions[_token][msg.sender];
        if (_amount > position.collateralAmount) revert PlatypusTreasure_InvalidAmount();
        position.collateralAmount -= toUint128(_amount);

        (bool solvent, ) = _isSolvent(msg.sender, _token, true);
        if (!solvent) revert PlatypusTreasure_ExceedCollateralFactor();

        emit RemoveCollateral(msg.sender, _token, _amount);
        ERC20(_token).safeTransfer(msg.sender, _amount);
    }

    /**
     * @notice borrow USP
     * @dev user can call this function after depositing his/her collateral
     * Follows Checks-Effects-Interactions
     * @param _token collateral token address
     * @param _borrowAmount USP amount to borrow
     */
    function borrow(ERC20 _token, uint256 _borrowAmount) public {
        if (marketSetting.borrowPaused == true) revert PlatypusTreasure_BorrowPaused();
        if (_borrowAmount == 0) revert PlatypusTreasure_InvalidAmount();
        CollateralSetting storage setting = collateralSettings[_token];
        // check if collateral exists
        _checkCollateralExist(_token);

        _accrue();

        // calculate borrow limit in USD
        uint256 borrowLimit = _borrowLimitUSP(msg.sender, _token);
        // calculate debt amount in USP
        uint256 debtAmount = _debtAmountUSP(msg.sender, _token);

        // check if the position exceeds borrow limit
        if (debtAmount + _borrowAmount > borrowLimit) revert PlatypusTreasure_ExceedCollateralFactor();
        // check if it reaches minimum borrow amount
        if (debtAmount + _borrowAmount < uint256(marketSetting.mininumBorrowAmount) * 1e18) {
            revert PlatypusTreasure_MinimumBorrowAmountNotSatisfied();
        }
        // if the stablecoin is about to unpeg (p < 0.98), minting is disallowed
        if (setting.isStable) {
            uint256 oneUnit = 10**collateralSettings[_token].decimals;
            uint256 price = _tokenPriceUSD(_token, oneUnit);
            if (price < 98e16) {
                revert PlatypusTreasure_BorrowDisallowed();
            }
        }

        // calculate USP borrow fee
        uint256 borrowFee = (_borrowAmount * setting.borrowFee) / 10000;
        feesToBeCollected += toUint112(borrowFee);

        // update collateral position
        uint256 borrowShare = totalDebtShare == 0 ? _borrowAmount : (_borrowAmount * totalDebtShare) / totalDebtAmount;
        userPositions[_token][msg.sender].debtShare += toUint128(borrowShare);
        setting.borrowedShare += toUint128(borrowShare);
        totalDebtShare += toUint128(borrowShare);
        totalDebtAmount += toUint112(_borrowAmount);

        // check if the position exceeds borrow cap of this collateral
        uint256 totalBorrowedUSP = (uint256(setting.borrowedShare) * uint256(totalDebtAmount)) /
            uint256(totalDebtShare);
        if (totalBorrowedUSP > uint256(setting.borrowCap) * 1e18) revert PlatypusTreasure_ExceedCap();

        emit Borrow(msg.sender, _token, _borrowAmount);
        emit Accrue(borrowFee);

        // mint USP to user
        usp.mint(msg.sender, _borrowAmount - borrowFee);
    }

    /**
     * @notice repay debt with USP. The caller is suggested to increase _repayAmount by 0.01 if
     * he wants to repay all of this USP in case interest accrus
     * @dev user can call this function after approving his/her USP amount to repay.
     * Follows Checks-Effects-Interactions
     * @param _token collateral token address
     * @param _repayAmount USP amount to repay
     * @return repayShare
     */
    function repay(ERC20 _token, uint256 _repayAmount) public nonReentrant returns (uint256) {
        CollateralSetting storage setting = collateralSettings[_token];
        // check if collateral exists
        _checkCollateralExist(_token);
        if (_repayAmount == 0) revert PlatypusTreasure_InvalidAmount();

        _accrue();

        Position storage position = userPositions[_token][msg.sender];

        // calculate debt amount in USD
        uint256 debtAmount = _debtAmountUSP(msg.sender, _token);

        uint256 repayShare;
        if (_repayAmount >= debtAmount) {
            // only pays for the debt and returns remainings
            _repayAmount = debtAmount;
            repayShare = position.debtShare;
        } else {
            repayShare = (_repayAmount * totalDebtShare) / totalDebtAmount;
        }

        // check mininumBorrowAmount
        if (
            debtAmount - _repayAmount > 0 &&
            debtAmount - _repayAmount < uint256(marketSetting.mininumBorrowAmount) * 1e18
        ) {
            revert PlatypusTreasure_MinimumBorrowAmountNotSatisfied();
        }

        // update user's collateral position
        position.debtShare -= toUint128(repayShare);

        // update total debt
        totalDebtShare -= toUint128(repayShare);
        totalDebtAmount -= toUint112(_repayAmount);
        setting.borrowedShare -= toUint128(repayShare);

        emit Repay(msg.sender, _token, _repayAmount);

        // burn repaid USP
        usp.burnFrom(msg.sender, _repayAmount);

        return repayShare;
    }

    /**
     * Liquidation Module
     */

    /// @notice Return the number of active auctions
    function activeAuctionLength() external view returns (uint256) {
        return activeAuctions.length;
    }

    /// @notice Return the entire array of active auctions
    function getActiveAuctions() external view returns (uint48[] memory) {
        return activeAuctions;
    }

    /// @notice Burn USP to fill unbacked USP
    /// @dev Can be call by any party
    function fillUnbackedUsp(uint128 _amount) external {
        usp.burnFrom(msg.sender, _amount);
        unbackedUspAmount -= _amount;
    }

    /**
     * @notice Liquidate a position and kickstart a Dutch auction to sell collaterals for USP.
     * The entire position will be liquidated but it can be partially filled as stated in `buyCollateral()`.
     * Liquidation penalty is included in the debt amount. The starting price of the auction is read from
     * oracle and is increased percentage-wise by `buf` (withdrawal fee for LP is
     * ignored in case of flash-loan). The price decreases as a function of time defined by `calculatePrice()`.
     *
     * @dev It checks
     * - liquidation isn't paused
     * - the position is default
     * It performs several actions:
     * - (pushes the bad debt into the debt queue)
     * - initiates the auction (debt amountinclude penalty, the price)
     * - remove collateral from the position (and masterPlatypus is needed)
     * - adds the bad debt plus the liquidation penalty to accumulator
     * - sends an incentive denominated in USP to the keeper (`kickIncentive` + 0.1% of USP to raise)
     */
    function startAuction(
        address _user,
        ERC20 _token,
        address _incentiveReceiver
    ) public nonReentrant returns (uint256 auctionId) {
        /********** Checks **********/
        CollateralSetting storage collateral = collateralSettings[_token];
        if (marketSetting.liquidationPaused || collateral.liquidationPaused) revert Liquidation_Paused();

        _checkCollateralExist(_token);

        _accrue();

        uint256 debtAmount = _debtAmountUSP(_user, _token);
        bool liquidable = debtAmount > 0 && debtAmount > _liquidateLimitUSP(_user, _token);

        if (!liquidable) revert PlatypusTreasure_NotLiquidable();

        /********** Grab collateral from the treasure **********/

        Position storage position = userPositions[_token][_user];
        uint256 collateralAmount = _getCollateralAmount(_token, _user);

        // if collateral is lp, this function withdraws the lp from masterplatypus to the treasure
        _grabCollateral(_user, _token, collateralAmount, position.debtShare);

        /********** Initiate Auction **********/

        uint256 uspToRaise = (debtAmount * (10000 + collateral.liquidationPenalty)) / 10000;

        // incentives for kick-starting the auction = `kickIncentive` + 0.1% of USP to raise
        // Important note: the incentive + liquidation reward should remain less than the minimum
        // liquidation penalty by some margin of safety so that the system is unlikely to accrue a deficit
        uint256 incentive = marketSetting.kickIncentive * 1e18 + uspToRaise / 1000;
        unbackedUspAmount += toUint128(uspToRaise + incentive);

        // add liquidation penalty to protocol income
        feesToBeCollected += toUint112(uspToRaise - debtAmount);

        auctionId = _initiateAuction(_user, _token, toUint128(collateralAmount), toUint128(uspToRaise));

        // mint incentive to keeper
        usp.mint(_incentiveReceiver, incentive);

        emit StartAuction(auctionId, _user, _token, collateralAmount, uspToRaise);
        emit Accrue(uspToRaise - debtAmount);
    }

    /**
     * @notice remove collateral from the position to prepare for liquidation
     */
    function _grabCollateral(
        address _user,
        ERC20 _token,
        uint256 collateralAmount,
        uint256 debtShare
    ) internal {
        CollateralSetting storage collateral = collateralSettings[_token];
        Position storage position = userPositions[_token][_user];

        if (collateral.isLp) {
            // withdraw from masterPlatypus if it is an LP token
            collateral.masterPlatypus.liquidate(collateral.pid, _user, collateralAmount);
        } else {
            position.collateralAmount -= toUint128(collateralAmount);
        }

        position.debtShare -= toUint128(debtShare);

        uint256 debtAmount = (debtShare * totalDebtAmount) / totalDebtShare;

        totalDebtShare -= toUint128(debtShare);
        totalDebtAmount -= toUint112(debtAmount);
        collateral.borrowedShare -= toUint128(debtShare);
    }

    /**
     * @dev It performs the following action
     * - increments a counter and assigns a unique numerical id to the new auction
     * - inserts the id into a list tracking active auctions
     * - creates a structure to record the parameters of the auction
     */
    function _initiateAuction(
        address _user,
        ERC20 _token,
        uint128 _collateralAmount,
        uint128 _uspAmount
    ) internal returns (uint48 id) {
        id = ++totalAuctions;
        activeAuctions.push(id);

        uint256 oneUnit = 10**collateralSettings[_token].decimals;

        // For starting price
        // collateral factor * (1 + penalty) * (1 + buffer) should be < 100% to left some profit margin for liquidator
        auctions[id] = Auction({
            collateralAmount: _collateralAmount,
            startTime: uint40(block.timestamp),
            startPrice: toUint96(_tokenPriceUSD(_token, oneUnit)),
            index: uint48(activeAuctions.length - 1),
            token: _token,
            user: _user,
            uspAmount: _uspAmount
        });
    }

    /**
     * @notice Buy collateral at the current price as given by `calculatePrice()`. Flash lending of collateral
     * is supported but `msg.sender` should have prepared USP and approved this contract `uspAmount` of USP
     * @dev Following scenarios can happen when bidding on auctions
     * - Settling all debt while buying full collateral up for sale
     * - Settling all debt while buying only a part of the collateral up for sale
     * - Settling the debt only partially while buying the full collateral up for sale (bad debt)
     * - Settling the debt only partially for a part of the collateral up for sale (partial liquidation)
     * To avoid leaving a dust amount, remaining USP debt should be greater than `mininumBorrowAmount`
     */
    function buyCollateral(
        uint256 id,
        uint256 maxCollateralAmount,
        uint256 maxPrice,
        address who,
        bytes memory data
    ) public nonReentrant returns (uint256 bidCollateralAmount, uint256 uspAmount) {
        // Note: there is no auction reset

        /********** Checks **********/

        Auction memory auction = auctions[id];
        if (auction.collateralAmount == 0) revert Liquidation_Invalid_Auction_Id();

        uint256 price = calculatePrice(auction.token, auction.startPrice, block.timestamp - auction.startTime);
        if (maxPrice < price) revert Liquidation_Exceed_Max_Price(price);

        /********** Calculate repay amount **********/

        uint256 collateralToSell = auction.collateralAmount;
        uint256 uspToRaise = auction.uspAmount;
        uint256 oneUnit = 10**collateralSettings[auction.token].decimals;

        // purchase as much collateral as possible
        bidCollateralAmount = collateralToSell < maxCollateralAmount ? collateralToSell : maxCollateralAmount;
        uspAmount = (price * bidCollateralAmount) / oneUnit;

        if (uspAmount > uspToRaise) {
            // Don't collect more USP than the debt
            uspAmount = uspToRaise;
            bidCollateralAmount = (uspAmount * oneUnit) / price;
        } else if (uspAmount < uspToRaise && bidCollateralAmount < collateralToSell) {
            // Leave at least `minimumRemainingUsp` to avoid dust amount in the debt
            // minimumRemainingUsp = debt floot * (1 + liquidation penalty)
            // `x * 1e14` =  `x / 10000 * 1e14`
            uint256 minimumRemainingUsp = (marketSetting.mininumBorrowAmount *
                (uint256(10000) + collateralSettings[auction.token].liquidationPenalty)) * 1e14;
            if (uspToRaise - uspAmount < minimumRemainingUsp) {
                if (uspToRaise <= minimumRemainingUsp) revert Liquidation_Liquidator_Should_Take_All_Collateral();

                uspAmount = uspToRaise - minimumRemainingUsp;
                bidCollateralAmount = (uspAmount * oneUnit) / price;
            }
        }

        /********** Execute repay with flash lending of collateral **********/

        // send collateral to `who`
        ERC20(auction.token).safeTransfer(who, bidCollateralAmount);

        // Do external call if data is defined
        if (data.length > 0) {
            // The callee can swap collateral to USP in the callback
            // Caution: Ensure this contract isn't authorized over the callee
            LiquidationCallback(who).callback(uspAmount, bidCollateralAmount, msg.sender, data);
        }

        // get collaterals, msg.sender should approve USP spending
        usp.burnFrom(msg.sender, uspAmount);

        /********** Update states **********/

        // remaining USP to raise and remaining collateral to sell
        collateralToSell -= bidCollateralAmount;
        uspToRaise -= uspAmount;

        // remove USP out of liquidation
        // collateralSettings[auction.token].uspToRaise -= uspAmount;
        unbackedUspAmount -= toUint128(uspAmount);

        if (collateralToSell == 0) {
            if (uspToRaise > 0) {
                // Bad debt: remove remaining `uspToRaise` from collateral setting
                // Note: If there's USP left to raise, we could spread it over all borrowers
                // or use protocol fee to fill it
                // collateralSettings[auction.token].uspToRaise -= uspToRaise;
                emit BadDebt(id, auction.user, auction.token, uspToRaise);
            }
            _removeAuction(id);
        } else if (uspToRaise == 0) {
            // All USP is repaid, return remaining collateral to the user
            ERC20(auction.token).safeTransfer(auction.user, collateralToSell);
            _removeAuction(id);
        } else {
            // update storage
            auctions[id].uspAmount = uint128(uspToRaise);
            auctions[id].collateralAmount = uint128(collateralToSell);
        }

        emit BuyCollateral(id, auction.user, auction.token, bidCollateralAmount, uspAmount);
    }

    /**
     * @notice Calculate the collateral price of a liquidation given startPrice and timeElapsed.
     * Stairstep Exponential Decrease:
     * - multiply the price by `auctionFactor` for every `auctionStep` seconds pass
     */
    function calculatePrice(
        ERC20 _token,
        uint256 _startPrice,
        uint256 _timeElapsed
    ) public view returns (uint256) {
        CollateralSetting storage collateral = collateralSettings[_token];

        uint256 discountFactor = FixedPointMathLib.rpow(
            (uint256(collateral.auctionFactor) * 1e18) / 10000,
            _timeElapsed / collateral.auctionStep,
            1e18
        );

        return (discountFactor * _startPrice) / 1e18;
    }

    /**
     * @notice Return the current unit price of an active auction
     * @dev Returned price is 0 if it is not an active auction
     */
    function calculatePriceOfAuctions(uint256[] calldata ids) external view returns (uint256[] memory prices) {
        uint256 len = ids.length;
        prices = new uint256[](len);

        for (uint256 i; i < len; ++i) {
            uint256 id = ids[i];

            Auction memory auction = auctions[id];
            if (auction.collateralAmount != 0) {
                prices[i] = calculatePrice(auction.token, auction.startPrice, block.timestamp - auction.startTime);
            }
        }
    }

    function _removeAuction(uint256 id) internal {
        // remove the auction from `activeAuctions` and replace it with the last auction
        uint48 lastId = activeAuctions[activeAuctions.length - 1];
        if (id != lastId) {
            uint48 indexToRemove = auctions[id].index;
            activeAuctions[indexToRemove] = lastId;
            auctions[lastId].index = indexToRemove;
        }
        activeAuctions.pop();
        delete auctions[id];
    }

    /**
     * Helper Functions
     */

    uint8 constant ACTION_ADD_COLLATERAL = 1;
    uint8 constant ACTION_REMOVE_COLLATERAL = 2;
    uint8 constant ACTION_BORROW = 3;
    uint8 constant ACTION_REPAY = 4;
    uint8 constant ACTION_START_AUCTION = 5;
    uint8 constant ACTION_BUY_COLLATERAL = 6;

    /// @notice Executes a set of actions
    /// @dev This function should not accept arbitrary call as the contract is able to liquidate LPs in MasterPlatypus
    function cook(uint8[] calldata actions, bytes[] calldata datas) external {
        for (uint256 i; i < actions.length; ++i) {
            uint8 action = actions[i];
            if (action == ACTION_ADD_COLLATERAL) {
                (ERC20 _token, uint256 _amount) = abi.decode(datas[i], (ERC20, uint256));
                addCollateral(_token, _amount);
            } else if (action == ACTION_REMOVE_COLLATERAL) {
                (ERC20 _token, uint256 _amount) = abi.decode(datas[i], (ERC20, uint256));
                removeCollateral(_token, _amount);
            } else if (action == ACTION_BORROW) {
                (ERC20 _token, uint256 _borrowAmount) = abi.decode(datas[i], (ERC20, uint256));
                borrow(_token, _borrowAmount);
            } else if (action == ACTION_REPAY) {
                (ERC20 _token, uint256 _repayAmount) = abi.decode(datas[i], (ERC20, uint256));
                repay(_token, _repayAmount);
            } else if (action == ACTION_START_AUCTION) {
                (address _user, ERC20 _token, address _incentiveReceiver) = abi.decode(
                    datas[i],
                    (address, ERC20, address)
                );
                startAuction(_user, _token, _incentiveReceiver);
            } else if (action == ACTION_BUY_COLLATERAL) {
                (uint256 id, uint256 maxCollateralAmount, uint256 maxPrice, address who, bytes memory data) = abi
                    .decode(datas[i], (uint256, uint256, uint256, address, bytes));
                buyCollateral(id, maxCollateralAmount, maxPrice, who, data);
            }
        }
    }

    /**
     * @notice returns a user's collateral position
     * @return position this includes a user's collateral, debt, liquidation data.
     */
    function positionView(address _user, ERC20 _token) external view returns (PositionView memory) {
        Position memory position = userPositions[_token][_user];

        (bool solvent, ) = _isSolvent(_user, _token, false);
        uint256 collateralAmount = _getCollateralAmount(_token, _user);
        uint256 liquidateLimitUSP = _liquidateLimitUSP(_user, _token);
        uint256 debtAmountUSP = _debtAmountUSP(_user, _token);
        // `healthFactor` is 0 if `debtAmountUSP` is 0
        uint256 healthFactor = debtAmountUSP == 0 ? 0 : (liquidateLimitUSP * 1e18) / debtAmountUSP;

        return
            PositionView({
                collateralAmount: collateralAmount,
                collateralUSD: _tokenPriceUSD(_token, collateralAmount),
                borrowLimitUSP: _borrowLimitUSP(_user, _token),
                liquidateLimitUSP: liquidateLimitUSP,
                debtAmountUSP: debtAmountUSP,
                debtShare: position.debtShare,
                healthFactor: healthFactor,
                liquidable: !solvent
            });
    }

    /**
     * @notice return available amount to borrow for this collateral
     * @param _token collateral token address
     * @return uint256 available amount to borrow
     */
    function availableUSP(ERC20 _token) external view returns (uint256) {
        CollateralSetting storage setting = collateralSettings[_token];
        uint256 outstandingLoan = totalDebtShare == 0
            ? 0
            : (uint256(setting.borrowedShare) * uint256(totalDebtAmount)) / uint256(totalDebtShare);
        if (uint256(setting.borrowCap) * 1e18 > outstandingLoan) {
            return uint256(setting.borrowCap) * 1e18 - outstandingLoan;
        }
        return 0;
    }

    /**
     * @notice Return the unit price of LP token
     * It should equal to the underlying token price adjusted by the exchange rate
     */
    function getLPUnitPrice(IAsset _lp) external view returns (uint256) {
        return _getLPUnitPrice(_lp);
    }

    /**
     * @notice function to check if user's collateral position is solvent
     * @dev returns (true, 0) if the token is not a valid collateral
     * @param _user address of the user
     * @param _token address of the token
     * @param _open open a position or close a position
     * @return solvent
     * @return debtAmount total debt amount including interests
     */
    function isSolvent(
        address _user,
        ERC20 _token,
        bool _open
    ) external view returns (bool solvent, uint256 debtAmount) {
        return _isSolvent(_user, _token, _open);
    }

    /**
     * Internal Functions
     */

    function _checkCollateralExist(ERC20 _token) internal view {
        if (collateralSettings[_token].decimals == 0) revert PlatypusTreasure_InvalidToken();
    }

    /**
     * @notice _accrue debt interest
     * @dev Updates the contract's state by calculating the additional interest accrued since the last time
     */
    function _accrue() internal {
        uint256 interest = _interestSinceLastAccrue();

        // set last time accrued. unsafe cast is intended
        lastAccrued = uint32(block.timestamp);

        // plus interest
        totalDebtAmount += toUint112(interest);
        feesToBeCollected += toUint112(interest);

        emit Accrue(interest);
    }

    /**
     * @notice function to check if user's collateral position is solvent
     * @dev returns (true, 0) if the token is not a valid collateral
     * @param _user address of the user
     * @param _token address of the token
     * @param _open open a position or close a position
     * @return solvent
     * @return debtAmount total debt amount including interests
     */
    function _isSolvent(
        address _user,
        ERC20 _token,
        bool _open
    ) internal view returns (bool solvent, uint256 debtAmount) {
        uint256 debtShare = userPositions[_token][_user].debtShare;

        // fast path
        if (debtShare == 0) return (true, 0);

        // totalDebtShare > 0 as debtShare is non-zero
        debtAmount = (debtShare * (totalDebtAmount + _interestSinceLastAccrue())) / totalDebtShare;
        solvent = debtAmount <= (_open ? _borrowLimitUSP(_user, _token) : _liquidateLimitUSP(_user, _token));
    }

    /**
     * @notice function that returns the collateral lp tokens deposited on master platypus
     * @param _token collateral lp address
     * @param _user user address
     * @return uint of collateral amount
     */
    function _getCollateralAmount(ERC20 _token, address _user) internal view returns (uint256) {
        CollateralSetting storage setting = collateralSettings[_token];
        if (setting.isLp) {
            return setting.masterPlatypus.getUserInfo(setting.pid, _user).amount;
        } else {
            return userPositions[_token][_user].collateralAmount;
        }
    }

    /**
     * @notice calculate additional interest accrued from last time
     * @return The interest accrued from last time
     */
    function _interestSinceLastAccrue() internal view returns (uint256) {
        // calculate elapsed time from last accrued at
        uint256 elapsedTime;
        unchecked {
            // underflow is intended
            elapsedTime = uint32(block.timestamp) - lastAccrued;
        }
        // Note: it is possible to make minimal interval between accrue in the future (e.g. 1h) to save gas
        if (elapsedTime == 0) return 0;

        // calculate interest based on elapsed time and interest rate
        return (elapsedTime * totalDebtAmount * _interestRate()) / 10000 / 365 days;
    }

    /**
     * @notice Return the dynamic interest rate based on the cov ratio of USP in main pool
     * @dev interest rate = c ^ k / 100
     * @return InterestRate e.g 1500 = 15%, base 10000
     */
    function _interestRate() internal view returns (uint256) {
        IAsset uspLp = marketSetting.uspLp;
        uint256 liability = uspLp.liability();
        if (liability == 0) return 0;

        uint256 covRatio = (uspLp.cash() * 1e18) / liability;
        // Interest rate has 1e18 * 1e2 decimals => interest rate / 100 / 1e18 * 10000 => / 1e16
        uint256 interestRate = covRatio.rpow(marketSetting.k, 1e18) / 1e16;
        // cap interest rate by 1000%
        return interestRate <= 100000 ? interestRate : 100000;
    }

    /**
     * @notice External view function that returns dynamic interest rates from the cov ratio of USP in the main pool
     * @dev interest rate = c ^ k / 100
     * @return InterestRate e.g 15% = 1500, base 10000
     */
    function currentInterestRate() external view returns (uint256) {
        return _interestRate();
    }

    /**
     * @notice Return the price of LP token
     * It should equal to the underlying token price adjusted by the exchange rate
     */
    function _getLPUnitPrice(IAsset _lp) internal view returns (uint256) {
        uint256 underlyingTokenPrice = oracle.getAssetPrice(IAsset(_lp).underlyingToken());
        uint256 totalSupply = IAsset(_lp).totalSupply();

        if (totalSupply == 0) {
            return underlyingTokenPrice;
        } else {
            // Note: Withdrawal loss is not considered here. And it should not been taken into consideration for
            // liquidation criteria.
            return (underlyingTokenPrice * IAsset(_lp).liability()) / totalSupply;
        }
    }

    /**
     * @notice returns the USD price of given token amount in 18 d.p
     * @param _token collateral token address
     * @param _amount token amount
     * @return The USD amount in 18 decimals
     */
    function _tokenPriceUSD(ERC20 _token, uint256 _amount) internal view returns (uint256) {
        CollateralSetting storage setting = collateralSettings[_token];
        uint256 unitPrice;
        if (setting.isLp) {
            unitPrice = _getLPUnitPrice(IAsset(address(_token)));
        } else {
            unitPrice = oracle.getAssetPrice(address(_token));
        }
        // Convert to 18 decimals. Price quoted in USD has 8 decimals
        return (_amount * unitPrice * 1e10) / 10**(setting.decimals);
    }

    /**
     * @notice returns the borrow limit amount in USD
     * @param _user user address
     * @param _token collateral token address
     * @return uint256 The USD amount in 18 decimals
     */
    function _borrowLimitUSP(address _user, ERC20 _token) internal view returns (uint256) {
        uint256 amount = _getCollateralAmount(_token, _user);
        uint256 totalUSD = _tokenPriceUSD(_token, amount);
        return (totalUSD * collateralSettings[_token].collateralFactor) / 10000;
    }

    /**
     * @notice returns the liquidation threshold amount in USD
     * @param _user user address
     * @param _token collateral token address
     * @return The USD amount in 18 decimals
     */
    function _liquidateLimitUSP(address _user, ERC20 _token) internal view returns (uint256) {
        uint256 amount = _getCollateralAmount(_token, _user);
        uint256 totalUSD = _tokenPriceUSD(_token, amount);
        return (totalUSD * collateralSettings[_token].liquidationThreshold) / 10000;
    }

    /**
     * @notice returns the debt amount in USD
     * @dev interest is skipped due to gas
     * @param _user user address
     * @param _token collateral token address
     * @return The USD amount in 18 decimals
     */
    function _debtAmountUSP(address _user, ERC20 _token) internal view returns (uint256) {
        if (totalDebtShare == 0) return 0;
        return
            (uint256(userPositions[_token][_user].debtShare) * (totalDebtAmount + _interestSinceLastAccrue())) /
            totalDebtShare;
    }

    function toUint96(uint256 val) internal pure returns (uint96) {
        if (val > type(uint96).max) revert Uint96_Overflow();
        return uint96(val);
    }

    function toUint112(uint256 val) internal pure returns (uint112) {
        if (val > type(uint112).max) revert Uint112_Overflow();
        return uint112(val);
    }

    function toUint128(uint256 val) internal pure returns (uint128) {
        if (val > type(uint128).max) revert Uint128_Overflow();
        return uint128(val);
    }
}
