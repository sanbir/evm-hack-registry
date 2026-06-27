// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.23;

import "./OwnableMaster.sol";

import "./InterfaceHub/IWETH.sol";
import "./InterfaceHub/IAaveHubLite.sol";
import "./InterfaceHub/IPositionNFTs.sol";
import "./InterfaceHub/IWiseSecurity.sol";
import "./InterfaceHub/IWiseOracleHub.sol";
import "./InterfaceHub/IFeeManagerLight.sol";

error DeadOracle();
error InvalidAction();
error InvalidCaller();
error PositionLocked();
error CollateralTooSmall();
error ZeroSharesAssigned();
error SharePriceDecreased();
error SharePriceIncreased();

contract WiseLendingDeclaration is OwnableMaster {

    event FundsDeposited(
        address indexed sender,
        uint256 indexed nftId,
        address indexed token,
        uint256 amount,
        uint256 shares,
        uint256 timestamp
    );

    event FundsSolelyDeposited(
        address indexed sender,
        uint256 indexed nftId,
        address indexed token,
        uint256 amount,
        uint256 timestamp
    );

    event FundsWithdrawn(
        address indexed sender,
        uint256 indexed nftId,
        address indexed token,
        uint256 amount,
        uint256 shares,
        uint256 timestamp
    );

    event FundsWithdrawnOnBehalf(
        address indexed sender,
        uint256 indexed nftId,
        address indexed token,
        uint256 amount,
        uint256 shares,
        uint256 timestamp
    );

    event FundsSolelyWithdrawn(
        address indexed sender,
        uint256 indexed nftId,
        address indexed token,
        uint256 amount,
        uint256 timestamp
    );

    event FundsSolelyWithdrawnOnBehalf(
        address indexed sender,
        uint256 indexed nftId,
        address indexed token,
        uint256 amount,
        uint256 timestamp
    );

    event FundsBorrowed(
        address indexed borrower,
        uint256 indexed nftId,
        address indexed token,
        uint256 amount,
        uint256 shares,
        uint256 timestamp
    );

    event FundsBorrowedOnBehalf(
        address indexed sender,
        uint256 indexed nftId,
        address indexed token,
        uint256 amount,
        uint256 shares,
        uint256 timestamp
    );

    event FundsReturned(
        address indexed sender,
        address indexed token,
        uint256 indexed nftId,
        uint256 totalPayment,
        uint256 totalPaymentShares,
        uint256 timestamp
    );

    constructor(
        address _master,
        address _wiseOracleHub,
        address _nftContract
    )
        OwnableMaster(
            _master
        )
    {
        if (_wiseOracleHub == ZERO_ADDRESS) {
            revert NoValue();
        }

        if (_nftContract == ZERO_ADDRESS) {
            revert NoValue();
        }

        WISE_ORACLE = IWiseOracleHub(
            _wiseOracleHub
        );

        WETH_ADDRESS = WISE_ORACLE.WETH_ADDRESS();

        WETH = IWETH(
            WETH_ADDRESS
        );

        POSITION_NFT = IPositionNFTs(
            _nftContract
        );

        FEE_MANAGER_NFT = POSITION_NFT.FEE_MANAGER_NFT();
    }

    function setSecurity(
        address _wiseSecurity
    )
        external
        onlyMaster
    {
        if (address(WISE_SECURITY) > ZERO_ADDRESS) {
            revert InvalidAction();
        }

        WISE_SECURITY = IWiseSecurity(
            _wiseSecurity
        );

        FEE_MANAGER = IFeeManagerLight(
            WISE_SECURITY.FEE_MANAGER()
        );

        AAVE_HUB_ADDRESS = WISE_SECURITY.AAVE_HUB();

        whiteListOnBehalf[AAVE_HUB_ADDRESS] = true;
    }

    /**
     * @dev Wrapper for wrapping
     * ETH call.
     */
    function _wrapETH(
        uint256 _value
    )
        internal
    {
        WETH.deposit{
            value: _value
        }();
    }

    /**
     * @dev Wrapper for unwrapping
     * ETH call.
     */
    function _unwrapETH(
        uint256 _value
    )
        internal
    {
        WETH.withdraw(
            _value
        );
    }

    function _sendValue(
        address _recipient,
        uint256 _amount
    )
        internal
    {
        if (address(this).balance < _amount) {
            revert InvalidAction();
        }

        sendingProgress = true;

        (bool success, ) = payable(_recipient).call{
            value: _amount
        }("");

        sendingProgress = false;

        if (success == false) {
            revert InvalidAction();
        }
    }

    // AaveHub address
    address internal AAVE_HUB_ADDRESS;

    // Wrapped ETH address
    address public immutable WETH_ADDRESS;

    // Wrapped ETH interface
    IWETH internal immutable WETH;

    // Nft id for feeManager
    uint256 immutable FEE_MANAGER_NFT;

    // WiseSecurity interface
    IWiseSecurity public WISE_SECURITY;

    // FeeManager interface
    IFeeManagerLight internal FEE_MANAGER;

    // NFT contract interface for positions
    IPositionNFTs public immutable POSITION_NFT;

    // OraceHub interface
    IWiseOracleHub public immutable WISE_ORACLE;

    // Structs ------------------------------------------

    struct LendingEntry {
        bool unCollateralized;
        uint256 shares;
    }

    struct BorrowRatesEntry {
        uint256 pole;
        uint256 deltaPole;
        uint256 minPole;
        uint256 maxPole;
        uint256 multiplicativeFactor;
    }

    struct AlgorithmEntry {
        bool increasePole;
        uint256 bestPole;
        uint256 maxValue;
        uint256 previousValue;
    }

    struct GlobalPoolEntry {
        uint256 totalPool;
        uint256 utilization;
        uint256 totalBareToken;
        uint256 poolFee;
    }

    struct LendingPoolEntry {
        uint256 pseudoTotalPool;
        uint256 totalDepositShares;
        uint256 collateralFactor;
    }

    struct BorrowPoolEntry {
        bool allowBorrow;
        uint256 pseudoTotalBorrowAmount;
        uint256 totalBorrowShares;
        uint256 borrowRate;
    }

    struct TimestampsPoolEntry {
        uint256 timeStamp;
        uint256 timeStampScaling;
    }

    struct CoreLiquidationStruct {
        uint256 nftId;
        uint256 nftIdLiquidator;
        address caller;
        address receiver;
        address tokenToPayback;
        address tokenToRecieve;
        uint256 paybackAmount;
        uint256 shareAmountToPay;
        uint256 maxFeeETH;
        uint256 baseRewardLiquidation;
        address[] lendTokens;
        address[] borrowTokens;
    }

    modifier onlyWhiteList() {
        _onlyWhiteList();
        _;
    }

    function _onlyWhiteList()
        private
        view
    {
        if (whiteListOnBehalf[msg.sender] == false) {
            revert InvalidCaller();
        }
    }

    /**
     * Allows to set whitelist contract
     */
    function setOnBehalf(
        address _contract,
        bool _status
    )
        external
        onlyMaster
    {
        whiteListOnBehalf[_contract] = _status;
    }

    // Reentrancy check - public for layer2's
    bool public sendingProgress;

    // Position mappings ------------------------------------------
    mapping(address => bool) internal whiteListOnBehalf;
    mapping(address => uint256) internal bufferIncrease;
    mapping(address => uint256) public maxDepositValueToken;

    mapping(uint256 => address[]) public positionLendTokenData;
    mapping(uint256 => address[]) public positionBorrowTokenData;

    mapping(uint256 => mapping(address => uint256)) public userBorrowShares;
    mapping(uint256 => mapping(address => uint256)) public pureCollateralAmount;
    mapping(uint256 => mapping(address => LendingEntry)) public userLendingData;

    // Owner -> PoolToken -> Spender -> Allowance Value
    mapping(address => mapping(address => mapping(address => uint256))) public allowance;

    // Struct mappings -------------------------------------
    mapping(address => BorrowRatesEntry) public borrowRatesData;
    mapping(address => AlgorithmEntry) public algorithmData;
    mapping(address => GlobalPoolEntry) public globalPoolData;
    mapping(address => LendingPoolEntry) public lendingPoolData;
    mapping(address => BorrowPoolEntry) public borrowPoolData;
    mapping(address => TimestampsPoolEntry) public timestampsPoolData;

    // Bool mappings -------------------------------------
    mapping(uint256 => bool) public positionLocked;
    mapping(address => bool) internal parametersLocked;
    mapping(address => bool) public verifiedIsolationPool;

    // Hash mappings -------------------------------------
    mapping(bytes32 => bool) internal hashMapPositionBorrow;
    mapping(bytes32 => bool) internal hashMapPositionLending;

    // PRECISION FACTORS ------------------------------------
    uint256 internal constant PRECISION_FACTOR_E16 = 1E16;
    uint256 internal constant PRECISION_FACTOR_E18 = 1E18;
    uint256 internal constant PRECISION_FACTOR_E36 = PRECISION_FACTOR_E18 * PRECISION_FACTOR_E18;

    // TIME CONSTANTS --------------------------------------
    uint256 internal constant ONE_YEAR = 52 weeks;
    uint256 internal constant THREE_HOURS = 3 hours;
    uint256 internal constant PRECISION_FACTOR_YEAR = PRECISION_FACTOR_E18 * ONE_YEAR;

    // Two months in seconds:
    // Norming change in pole value that it steps from min to max value
    // within two month (if nothing changes)
    uint256 internal constant NORMALISATION_FACTOR = 4838400;

    // Default boundary values for pool creation.
    uint256 internal constant LOWER_BOUND_MAX_RATE = 100 * PRECISION_FACTOR_E16;
    uint256 internal constant UPPER_BOUND_MAX_RATE = 300 * PRECISION_FACTOR_E16;

    // LASA CONSTANTS -------------------------
    uint256 internal constant THRESHOLD_SWITCH_DIRECTION = 90 * PRECISION_FACTOR_E16;
    uint256 internal constant THRESHOLD_RESET_RESONANCE_FACTOR = 75 * PRECISION_FACTOR_E16;
}
