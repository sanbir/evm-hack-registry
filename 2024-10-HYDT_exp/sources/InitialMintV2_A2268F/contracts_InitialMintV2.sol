// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.19;

import "./interfaces/IControl.sol";
import "./interfaces/IHYDT.sol";

import "./libraries/DataFetcher.sol";
import "./libraries/SafeERC20.sol";
import "./libraries/SafeETH.sol";

import "./utils/Context.sol";

contract InitialMintV2 is Context {

    /* ========== STATE VARIABLES ========== */

    /// @dev Fixed time duration variables.
    uint128 private constant THREE_MONTHS_TIME = 7776000;
    uint128 private constant ONE_DAY_TIME = 86400;

    /// @notice The address of the Pancake Factory.
    address public constant PANCAKE_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;

    /// @notice The address of the Wrapped BNB token.
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    /// @notice The address of the relevant stable token.
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    /// @notice The total limit of USD allowed for purchasing HYDT with over the course of initial minting.
    uint128 public constant INITIAL_MINT_LIMIT = 30000000 * 1e18;
    /// @notice The daily limit of USD allowed for purchasing HYDT with during initial minting.
    uint128 public constant DAILY_INITIAL_MINT_LIMIT = 700000 * 1e18;

    /// @notice The address of the primary stable token.
    IHYDT public HYDT;
    /// @notice The address of the BNB reserve.
    address public RESERVE;

    /// @dev Storage of values regarding purchases of HYDT during initial minting.
    InitialMintValues private _initialMints;
    InitialMintValues private _dailyInitialMints;

    /// @dev Initialization variables.
    address private immutable _initializer;
    bool private _isInitialized;

    /* ========== STORAGE ========== */

    struct InitialMintValues {
        uint256 startTime;
        uint256 endTime;
        uint256 amount;
    }

    /* ========== EVENTS ========== */

    event InitialMint(address indexed user, uint256 amountBNB, uint256 amountHYDT, uint256 callingPrice);

    /* ========== CONSTRUCTOR ========== */

    constructor() {
        _initializer = _msgSender();
    }

    /* ========== INITIALIZE ========== */

    /**
     * @notice Initializes external dependencies and state variables.
     * @dev This function can only be called once.
     * @param control_ The address of the `Control` contract.
     * @param hydt_ The address of the `HYDT` contract.
     * @param reserve_ The address of the `Reserve` contract.
     * @param initialMintStartTime_ The unix timestamp at which initial minting will begin.
     */
    function initialize(address control_, address hydt_, address reserve_, uint256 initialMintStartTime_) external {
        require(_msgSender() == _initializer, "InitialMint: caller is not the initializer");
        require(!_isInitialized, "InitialMint: already initialized");

        require(control_ != address(0), "InitialMint: invalid Control address");
        require(hydt_ != address(0), "InitialMint: invalid HYDT address");
        require(reserve_ != address(0), "InitialMint: invalid Reserve address");
        HYDT = IHYDT(hydt_);
        RESERVE = reserve_;

        _initialMints.startTime = initialMintStartTime_;
        // _initialMints.endTime = 0;
        (, , _initialMints.amount) = IControl(control_).getInitialMints();

        _dailyInitialMints.startTime = initialMintStartTime_;
        _dailyInitialMints.endTime = initialMintStartTime_ + ONE_DAY_TIME;
        // _dailyInitialMints.amount = 0;

        _isInitialized = true;
    }

    /* ========== FUNCTIONS ========== */

    /**
     * @notice Gets total values for initial minting.
     * @return startTime The unix timestamp which denotes the start of initial minting.
     * @return amountUSD The amount in USD that has been transacted via inital minting in total.
     */
    function getInitialMints() external view returns (uint256 startTime, uint256 amountUSD) {
        startTime = _initialMints.startTime;
        amountUSD = _initialMints.amount;
    }

    /**
     * @notice Gets daily values for initial minting.
     * @return startTime The unix timestamp which denotes the start of the day.
     * @return endTime The unix timestamp which denotes the end of the day.
     * @return amountUSD The amount in USD that has been transacted via inital minting in said day.
     */
    function getDailyInitialMints() external view returns (uint256 startTime, uint256 endTime, uint256 amountUSD) {
        startTime = _dailyInitialMints.startTime;
        endTime = _dailyInitialMints.endTime;
        amountUSD = _dailyInitialMints.amount;

        if (block.timestamp > _dailyInitialMints.endTime) {
            (startTime, endTime) =
                _getNextDailyInitialMintTime(_dailyInitialMints.startTime, _dailyInitialMints.endTime);
            amountUSD = 0;
        }
    }

    /**
     * @dev Gets the start and end times for the next iteration of daily initial mints.
     */
    function _getNextDailyInitialMintTime(uint256 startTime, uint256 endTime) internal view returns (uint256, uint256) {
        uint256 numberOfDays = (block.timestamp - startTime) / ONE_DAY_TIME;
        return (
            startTime + (numberOfDays * ONE_DAY_TIME),
            endTime + (numberOfDays * ONE_DAY_TIME)
        );
    }

    /**
     * @notice Gets current HYDT price corresponding to the preferred pair.
     */
    function getCurrentPrice() public view returns (uint256) {
        address[] memory path = new address[](3);
        path[0] = address(HYDT);
        path[1] = WBNB;
        path[2] = USDT;
        uint256 amountIn = 1 * 1e18;
        uint256 price = DataFetcher.quoteRouted(PANCAKE_FACTORY, amountIn, path);
        return price;
    }

    /**
     * @notice Used to mint HYDT in return for BNB. All transfers will be made at 1 HYDT per USD at current BNB/USD rates.
     */
    function initialMint() external payable {
        require(msg.value > 0, "InitialMint: insufficient BNB amount");
        InitialMintValues storage initialMints = _initialMints;
        InitialMintValues storage dailyInitialMints = _dailyInitialMints;

        require(block.timestamp > initialMints.startTime, "InitialMint: initial mint not yet started");

        if (block.timestamp > dailyInitialMints.endTime) {
            (dailyInitialMints.startTime, dailyInitialMints.endTime) =
                _getNextDailyInitialMintTime(dailyInitialMints.startTime, dailyInitialMints.endTime);
            dailyInitialMints.amount = 0;
        }
        uint256 amount = DataFetcher.quote(PANCAKE_FACTORY, msg.value, WBNB, USDT);

        require(
            INITIAL_MINT_LIMIT >=
            initialMints.amount + amount,
            "InitialMint: invalid amount considering initial mint limit"
        );
        require(
            DAILY_INITIAL_MINT_LIMIT >=
            dailyInitialMints.amount + amount,
            "InitialMint: invalid amount considering daily initial mint limit"
        );
        initialMints.amount += amount;
        dailyInitialMints.amount += amount;
        SafeETH.safeTransferETH(RESERVE, msg.value);
        HYDT.mint(_msgSender(), amount);

        emit InitialMint(_msgSender(), msg.value, amount, 1 * 1e18);
    }
}
