// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {LibClone} from "solady/utils/LibClone.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {LibString} from "solady/utils/LibString.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {ENS} from "./interfaces/ENS.sol";
import {BondingCurve} from "./BondingCurve.sol";
import {StackToken} from "./StackToken.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";
import {IStackMarket} from "./interfaces/IStackMarket.sol";
import {Receiver} from "../lib/solady/src/accounts/Receiver.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/**
 * @title StackMarket
 * @notice A market system for personalized tokens with hybrid liquidity
 * @dev Implements a dual-phase market system:
 *      Phase 1: Bonding curve for initial price discovery
 *      Phase 2: Uniswap V3 for mature market trading
 * @author stack.so
 */
contract StackMarket is IStackMarket, Ownable, ReentrancyGuard, Receiver {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         CONSTANTS                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Token supply configuration
    uint256 public constant TOTAL_SUPPLY = 10_000_000 ether; // 10M tokens
    uint256 public constant OWNER_ALLOCATION = 3_000_000 ether; // 30% of supply

    /// @notice Fee structure in basis points
    uint256 public constant PROTOCOL_FEE_BPS = 100; // 1%
    uint256 public constant OWNER_FEE_BPS = 50; // 0.5%
    uint256 public constant REFERRAL_FEE_BPS = 50; // 0.5%
    uint256 public constant TOTAL_FEE_BPS = PROTOCOL_FEE_BPS + OWNER_FEE_BPS + REFERRAL_FEE_BPS;

    /// @notice Market parameters
    uint256 public constant MIN_TRADE_SIZE = 0.0000001 ether;
    uint256 public constant GRADUATION_THRESHOLD = 50; // 50%
    uint256 public constant VESTING_PERIOD = 365 days;

    /// @notice Uniswap configuration
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    uint24 public constant POOL_FEE = 500; // 0.05%
    int24 public constant TICK_LOWER = -887200;
    int24 public constant TICK_UPPER = 887200;

    /// @notice ENS configuration
    address public constant ENS_REGISTRY = 0xB94704422c2a1E396835A571837Aa5AE53285a95;
    bytes32 public constant BASE_NODE = 0xff1e3c0eb00ec714e34b6114125fbde1dea2f24a72fbf672e7b7fd5690328e10;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          STORAGE                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Market state for each account
    struct AccountState {
        uint96 ownerDistribution; // Vested tokens distributed to owner
        uint96 ethLiquidity; // ETH available in bonding curve
        uint64 vestingStart; // Timestamp when vesting began
        bool graduated; // Whether token has moved to Uniswap
        address pool; // Uniswap V3 pool address
    }

    /// @notice Protocol configuration
    address public feeRecipient;
    address public immutable tokenImplementation;
    bytes32 private immutable implementationCodeHash;
    INonfungiblePositionManager public immutable positionManager;
    ISwapRouter public immutable swapRouter;

    /// @notice Account states
    mapping(address => AccountState) private accountStates;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CONSTRUCTOR                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Initializes the market with the initial owner and Uniswap configuration
     * @param initialOwner The owner of the market
     * @param _positionManager The Uniswap V3 position manager
     * @param _swapRouter The Uniswap V3 swap router
     */
    constructor(address initialOwner, address _positionManager, address _swapRouter) {
        tokenImplementation = address(new StackToken());
        implementationCodeHash = LibClone.initCodeHash(tokenImplementation);

        positionManager = INonfungiblePositionManager(_positionManager);
        swapRouter = ISwapRouter(_swapRouter);
        feeRecipient = initialOwner;

        _initializeOwner(initialOwner);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      TOKEN CREATION                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Creates a token with the account address as the name and symbol
     * @param account The account whose tokens to create
     * @return The address of the newly created token
     */
    function create(address account) external payable nonReentrant returns (address) {
        string memory label = LibString.toHexString(account);
        return _createToken(label, label, account);
    }

    /**
     * @notice Creates a token with custom name and symbol (creator must be account)
     * @param name The name of the token
     * @param symbol The symbol of the token
     * @param account The account whose tokens to create
     * @return The address of the newly created token
     */
    function create(string calldata name, string calldata symbol, address account)
        external
        payable
        nonReentrant
        returns (address)
    {
        if (msg.sender != account) revert StackMarket__InvalidCreator();
        return _createToken(name, symbol, account);
    }

    /**
     * @notice Creates a token using an ENS name
     * @param label The ENS label to use for the token
     * @param account The account whose tokens to create
     * @return The address of the newly created token
     */
    function create(string calldata label, address account) external payable nonReentrant returns (address) {
        if (ENS(ENS_REGISTRY).owner(_getENSNode(label)) != account) {
            revert StackMarket__InvalidBaseName();
        }
        return _createToken(_labelToName(label), _labelToSymbol(label), account);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     TRADING FUNCTIONS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Purchase tokens with ETH
     * @param account The account whose tokens to buy
     * @param minTokens Minimum amount of tokens to receive
     * @param sqrtPriceLimitX96 Maximum price for the trade
     */
    function buy(address account, uint256 minTokens, uint160 sqrtPriceLimitX96) external payable nonReentrant {
        _buyFor(account, minTokens, msg.sender, sqrtPriceLimitX96, address(0));
    }

    /**
     * @notice Purchase tokens for a specific recipient
     * @param account The account whose tokens to buy
     * @param minTokens Minimum amount of tokens to receive
     * @param recipient The recipient of the tokens
     * @param sqrtPriceLimitX96 Maximum price for the trade
     */
    function buyFor(address account, uint256 minTokens, address recipient, uint160 sqrtPriceLimitX96)
        external
        payable
        nonReentrant
    {
        _buyFor(account, minTokens, recipient, sqrtPriceLimitX96, address(0));
    }

    /**
     * @notice Purchase tokens with referral
     * @param account The account whose tokens to buy
     * @param minTokens Minimum amount of tokens to receive
     * @param recipient The recipient of the tokens
     * @param referrer The referrer for the trade
     * @param sqrtPriceLimitX96 Maximum price for the trade
     */
    function referredBuyFor(
        address account,
        uint256 minTokens,
        address recipient,
        address referrer,
        uint160 sqrtPriceLimitX96
    ) external payable nonReentrant {
        _buyFor(account, minTokens, recipient, sqrtPriceLimitX96, referrer);
    }

    /**
     * @notice Sell tokens for ETH
     * @param account The account whose tokens to sell
     * @param tokenAmount Amount of tokens to sell
     * @param minEth Minimum amount of ETH to receive
     * @param sqrtPriceLimitX96 Maximum price for the trade
     */
    function sell(address account, uint256 tokenAmount, uint256 minEth, uint160 sqrtPriceLimitX96)
        external
        nonReentrant
    {
        _sellTo(msg.sender, account, tokenAmount, minEth, sqrtPriceLimitX96, address(0));
    }

    /**
     * @notice Sell tokens with a specific recipient for ETH
     * @param recipient The recipient of the ETH
     * @param account The account whose tokens to sell
     * @param tokenAmount Amount of tokens to sell
     * @param minEth Minimum amount of ETH to receive
     * @param sqrtPriceLimitX96 Maximum price for the trade
     */
    function sellTo(address recipient, address account, uint256 tokenAmount, uint256 minEth, uint160 sqrtPriceLimitX96)
        external
        nonReentrant
    {
        _sellTo(recipient, account, tokenAmount, minEth, sqrtPriceLimitX96, address(0));
    }

    /**
     * @notice Sell tokens with referral
     * @param recipient The recipient of the ETH
     * @param account The account whose tokens to sell
     * @param tokenAmount Amount of tokens to sell
     * @param minEth Minimum amount of ETH to receive
     * @param referrer The referrer for the trade
     * @param sqrtPriceLimitX96 Maximum price for the trade
     */
    function referredSellTo(
        address recipient,
        address account,
        uint256 tokenAmount,
        uint256 minEth,
        address referrer,
        uint160 sqrtPriceLimitX96
    ) external nonReentrant {
        _sellTo(recipient, account, tokenAmount, minEth, sqrtPriceLimitX96, referrer);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       PRICE QUOTES                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Gets the token buy quote in ETH
     * @param account The account whose tokens to quote
     * @param tokenAmount Amount of tokens to buy
     * @return Price in ETH for the token amount
     */
    function getTokenBuyQuote(address account, uint256 tokenAmount) external view returns (uint256) {
        uint256 progression = getBondingCurveProgression(account);
        if (progression == 0) {
            return BondingCurve.getTokenBuyQuote(progression, tokenAmount);
        }

        if (accountStates[account].graduated) {
            revert IStackMarket.StackMarket__Graduated();
        }

        uint256 ethAmount = BondingCurve.getTokenBuyQuote(progression, tokenAmount);
        return ethAmount + (ethAmount * TOTAL_FEE_BPS) / 10000;
    }

    /**
     * @notice Gets the token sell quote in ETH
     * @param account The account whose tokens to quote
     * @param ethAmount Amount of ETH to quote
     * @return Amount of ETH that would be received
     */
    function getEthSellQuote(address account, uint256 ethAmount) external view returns (uint256) {
        uint256 progression = getBondingCurveProgression(account);
        if (progression == 0) return 0;

        if (accountStates[account].graduated) {
            revert IStackMarket.StackMarket__Graduated();
        }

        return BondingCurve.getEthSellQuote(progression, ethAmount - (ethAmount * TOTAL_FEE_BPS) / 10000);
    }

    /**
     * @notice Gets the token sell quote in ETH
     * @param account The account whose tokens to quote
     * @param tokenAmount Amount of tokens to quote
     * @return Amount of ETH that would be received
     */
    function getTokenSellQuote(address account, uint256 tokenAmount) external view returns (uint256) {
        uint256 progression = getBondingCurveProgression(account);
        if (progression == 0) return 0;
        if (accountStates[account].graduated) {
            revert IStackMarket.StackMarket__Graduated();
        }
        uint256 ethAmount = BondingCurve.getTokenSellQuote(progression, tokenAmount);
        return ethAmount - (ethAmount * TOTAL_FEE_BPS) / 10000;
    }

    /**
     * @notice Gets the token buy quote in ETH
     * @param account The account whose tokens to quote
     * @param ethAmount Amount of ETH to quote
     * @return Amount of tokens that would be received
     */
    function getEthBuyQuote(address account, uint256 ethAmount) external view returns (uint256) {
        uint256 progression = getBondingCurveProgression(account);
        if (progression == 0) {
            return BondingCurve.getEthBuyQuote(progression, ethAmount);
        }
        if (accountStates[account].graduated) {
            revert IStackMarket.StackMarket__Graduated();
        }

        return BondingCurve.getEthBuyQuote(progression, ethAmount - (ethAmount * TOTAL_FEE_BPS) / 10000);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      UTILITY FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Gets the token contract for an account
     * @param account The account to query
     * @return The associated StackToken contract
     */
    function getAccountToken(address account) public view returns (address payable) {
        return payable(
            LibClone.predictDeterministicAddress(
                implementationCodeHash, keccak256(abi.encodePacked(account)), address(this)
            )
        );
    }

    /**
     * @notice Gets comprehensive market data for an account
     * @param account The account whose token to query
     * @return MarketData struct containing market information
     */
    function getMarketData(address account) external view returns (MarketData memory) {
        address tokenAddress = getAccountToken(account);
        if (!_tokenExists(tokenAddress)) {
            return MarketData({
                owner: address(0),
                token: address(0),
                uniswapPool: address(0),
                bondingCurveProgression: 0,
                bondingCurvePrice: 0,
                marketEthLiquidity: 0,
                distributedToOwner: 0,
                vestingStartedAt: 0,
                uniswapPoolPriceX96: 0,
                bondingCurveProgressionPercent: 0,
                isGraduated: false
            });
        }

        AccountState memory info = accountStates[account];
        uint256 progression = getBondingCurveProgression(account);
        uint16 progressionPercent = uint16(getBondingCurveProgressionPercent(account)); // Ensure it fits in uint16
        uint256 bondingCurvePrice = BondingCurve.getTokenBuyQuote(progression, 1 ether);
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(info.pool).slot0();

        return MarketData({
            owner: account,
            token: tokenAddress,
            uniswapPool: info.pool,
            bondingCurveProgression: progression,
            bondingCurvePrice: bondingCurvePrice,
            marketEthLiquidity: info.ethLiquidity,
            distributedToOwner: info.ownerDistribution,
            vestingStartedAt: info.vestingStart,
            uniswapPoolPriceX96: sqrtPriceX96,
            bondingCurveProgressionPercent: progressionPercent,
            isGraduated: info.graduated
        });
    }

    function getAccountPool(address account) external view returns (address) {
        return accountStates[account].pool;
    }

    function isGraduated(address account) external view returns (bool) {
        return accountStates[account].graduated;
    }

    function getOwnerDistribution(address account) external view returns (uint256) {
        return accountStates[account].ownerDistribution;
    }

    function getVestingStart(address account) external view returns (uint256) {
        return accountStates[account].vestingStart;
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        feeRecipient = _feeRecipient;
    }

    /**
     * @dev Distributes owner tokens based on vesting schedule
     */
    function distributeOwnerTokens(address account) public nonReentrant {
        _distributeOwnerTokens(account);
    }

    /**
     * @dev Utility function to get bonding curve progression
     */
    function getBondingCurveProgression(address account) public view returns (uint256) {
        address tokenAddr = getAccountToken(account);
        if (!_tokenExists(tokenAddr)) return 0;

        AccountState storage info = accountStates[account];

        return TOTAL_SUPPLY - (StackToken(payable(tokenAddr)).balanceOf(address(this)) + info.ownerDistribution);
    }

    /**
     * @dev Utility function to get bonding curve progression percentage
     */
    function getBondingCurveProgressionPercent(address account) public view returns (uint256) {
        return (getBondingCurveProgression(account) * 100) / TOTAL_SUPPLY;
    }

    /**
     * @notice Gets the current market balance of tokens
     * @param account The account to query
     * @return Available token balance in the market
     */
    function marketBalance(address account) external view returns (uint256) {
        return TOTAL_SUPPLY - OWNER_ALLOCATION - getBondingCurveProgression(account);
    }

    /**
     * @notice Gets the current ETH liquidity for an account
     * @param account The account to query
     * @return Current ETH liquidity
     */
    function ethLiquidity(address account) external view returns (uint256) {
        return accountStates[account].ethLiquidity;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    INTERNAL FUNCTIONS         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _createToken(string memory name, string memory symbol, address account)
        internal
        returns (address payable tokenAddress)
    {
        tokenAddress = payable(LibClone.cloneDeterministic(tokenImplementation, keccak256(abi.encodePacked(account))));
        StackToken(tokenAddress).initialize(name, symbol, account);

        accountStates[account] = AccountState({
            ownerDistribution: 0,
            ethLiquidity: 0,
            vestingStart: uint64(block.timestamp),
            graduated: false,
            pool: _initializeUniswapPool(tokenAddress)
        });

        emit TokenCreated(tokenAddress, account, msg.sender);

        if (msg.value > 0) {
            // There are no fees if buying during creation, to boost initial liquidity.
            _executeBondingCurveSwap(account, msg.value, 0, msg.sender);
        }
    }

    /**
     * @dev Handles token purchase logic
     */
    function _buyFor(address account, uint256 minTokens, address recipient, uint160 sqrtPriceLimitX96, address referrer)
        internal
    {
        // Allow small trades to return without reverting, esp. for the case of fallback functions.
        if (msg.value < MIN_TRADE_SIZE) return;
        if (recipient == address(0)) revert StackMarket__RecipientIsNull();

        (uint256 protocolFee, uint256 ownerFee, uint256 referralFee) = calculateFees(msg.value, referrer);
        uint256 netAmount = msg.value - protocolFee - ownerFee - referralFee;

        if (accountStates[account].graduated) {
            _executeUniswapSwap(getAccountToken(account), netAmount, minTokens, recipient, sqrtPriceLimitX96);
        } else {
            _executeBondingCurveSwap(account, netAmount, minTokens, recipient);
        }

        _distributeFees(account, protocolFee, ownerFee, referrer, referralFee);
        _distributeOwnerTokens(account);
    }

    /**
     * @dev Handles token selling logic
     */
    function _sellTo(
        address recipient,
        address account,
        uint256 tokenAmount,
        uint256 minEth,
        uint160 sqrtPriceLimitX96,
        address referrer
    ) internal {
        if (recipient == address(0)) revert StackMarket__RecipientIsNull();

        address payable tokenAddress = getAccountToken(account);
        if (!_tokenExists(tokenAddress)) revert StackMarket__TokenNotFound();

        StackToken token = StackToken(tokenAddress);
        if (token.balanceOf(msg.sender) < tokenAmount) {
            revert StackMarket__InsufficientBalance();
        }

        uint256 ethToSend;

        if (accountStates[account].graduated) {
            ethToSend = _executeUniswapSell(token, tokenAmount, minEth, sqrtPriceLimitX96);
        } else {
            ethToSend = _executeBondingCurveSell(account, token, tokenAmount, minEth);
        }

        _distributeSaleProceeds(account, recipient, referrer, ethToSend);
        _distributeOwnerTokens(account);
    }

    /**
     * @dev Executes a bonding curve swap for token purchase
     */
    function _executeBondingCurveSwap(address account, uint256 netAmount, uint256 minTokens, address recipient)
        internal
    {
        address tokenAddress = getAccountToken(account);
        uint256 tokensReceived;
        uint256 ethUsed;
        uint256 quote = _getBondingCurveQuote(account, netAmount);
        if (quote < minTokens) revert StackMarket__InsufficientLiquidity();

        uint256 marketBal = this.marketBalance(account);
        if (quote <= marketBal) {
            tokensReceived = quote;
            ethUsed = netAmount;
        } else {
            tokensReceived = marketBal;
            ethUsed = BondingCurve.getTokenBuyQuote(getBondingCurveProgression(account), marketBal);
            _handleRefund(ethUsed);
        }

        accountStates[account].ethLiquidity += uint96(ethUsed);
        StackToken(payable(tokenAddress)).transfer(recipient, tokensReceived);

        emit TokensPurchased(recipient, tokenAddress, ethUsed, tokensReceived, _checkAndExecuteGraduation(account));
    }

    /**
     * @dev Executes a bonding curve swap for token sale
     */
    function _executeBondingCurveSell(address account, StackToken token, uint256 tokenAmount, uint256 minEth)
        internal
        returns (uint256 ethToSend)
    {
        ethToSend = BondingCurve.getTokenSellQuote(getBondingCurveProgression(account), tokenAmount);

        if (ethToSend < minEth) revert StackMarket__InsufficientPayment();
        if (ethToSend > accountStates[account].ethLiquidity) {
            revert StackMarket__InsufficientLiquidity();
        }
        if (ethToSend < MIN_TRADE_SIZE) revert StackMarket__TradeTooSmall();
        if (token.allowance(msg.sender, address(this)) < tokenAmount) {
            revert StackMarket__InsufficientAllowance();
        }
        accountStates[account].ethLiquidity -= uint96(ethToSend);
        token.transferFrom(msg.sender, address(this), tokenAmount);
        emit TokensSold(msg.sender, address(token), ethToSend, tokenAmount, false);
    }

    function _distributeOwnerTokens(address account) internal {
        AccountState storage info = accountStates[account];
        if (info.ownerDistribution >= OWNER_ALLOCATION) return;
        if (info.vestingStart == 0) return;

        uint256 timePassed = block.timestamp - info.vestingStart;

        if (timePassed > VESTING_PERIOD) {
            timePassed = VESTING_PERIOD;
        }

        uint256 amountToDistribute = (OWNER_ALLOCATION * timePassed) / VESTING_PERIOD;
        uint256 amountToTransfer = amountToDistribute - info.ownerDistribution;

        if (amountToTransfer == 0) return;

        info.ownerDistribution = uint96(amountToDistribute);
        StackToken(getAccountToken(account)).transfer(account, amountToTransfer);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:°•.°•.*•´.*:˚.°*/
    /*                    LIQUIDITY MANAGEMENT                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.••*.+°.•°.*°.˚*/

    /**
     * @dev Initializes Uniswap V3 pool for a token
     */
    function _initializeUniswapPool(address tokenAddress) internal returns (address) {
        address token0 = tokenAddress < WETH ? tokenAddress : WETH;
        address token1 = tokenAddress < WETH ? WETH : tokenAddress;

        uint160 sqrtPriceX96 = token0 == WETH
            ? 35431911422859141528926554161152 // sqrt(2_000_000/10) * 2^96
            : 177159557114295724950945792; // sqrt(10/2_000_000) * 2^96

        return positionManager.createAndInitializePoolIfNecessary(token0, token1, POOL_FEE, sqrtPriceX96);
    }

    /**
     * @dev Executes a Uniswap V3 swap for token purchase
     */
    function _executeUniswapSwap(
        address tokenAddress,
        uint256 netAmount,
        uint256 minTokens,
        address recipient,
        uint160 sqrtPriceLimitX96
    ) internal returns (uint256 tokensReceived) {
        IWETH(WETH).deposit{value: netAmount}();
        IWETH(WETH).approve(address(swapRouter), netAmount);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: tokenAddress,
            fee: POOL_FEE,
            recipient: recipient,
            amountIn: netAmount,
            amountOutMinimum: minTokens,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        tokensReceived = swapRouter.exactInputSingle(params);
        IWETH(WETH).approve(address(swapRouter), 0);

        emit TokensPurchased(recipient, tokenAddress, netAmount, tokensReceived, true);
    }

    /**
     * @dev Executes a Uniswap V3 swap for token sale
     */
    function _executeUniswapSell(StackToken token, uint256 tokenAmount, uint256 minEth, uint160 sqrtPriceLimitX96)
        internal
        returns (uint256 ethReceived)
    {
        if (token.allowance(msg.sender, address(this)) < tokenAmount) {
            revert StackMarket__InsufficientAllowance();
        }
        token.transferFrom(msg.sender, address(this), tokenAmount);
        token.approve(address(swapRouter), tokenAmount);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(token),
            tokenOut: WETH,
            fee: POOL_FEE,
            recipient: address(this),
            amountIn: tokenAmount,
            amountOutMinimum: minEth,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        ethReceived = swapRouter.exactInputSingle(params);
        token.approve(address(swapRouter), 0);
        IWETH(WETH).withdraw(ethReceived);
        emit TokensSold(msg.sender, address(token), ethReceived, tokenAmount, true);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*´.°:°•°:*/
    /*                    GRADUATION MECHANICS          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•´+°.•*/

    /**
     * @dev Handles graduation to Uniswap V3
     */
    function _checkAndExecuteGraduation(address account) internal returns (bool) {
        if (getBondingCurveProgressionPercent(account) >= GRADUATION_THRESHOLD) {
            return _executeGraduation(account);
        }
        return false;
    }

    /**
     * @dev Executes the graduation process
     */
    function _executeGraduation(address account) internal returns (bool) {
        StackToken token = StackToken(getAccountToken(account));
        AccountState storage info = accountStates[account];

        uint256 marketTokens = this.marketBalance(account);
        uint256 marketEth = info.ethLiquidity;

        if (marketEth > address(this).balance) {
            revert StackMarket__InsufficientEthForGraduation();
        }

        IWETH(WETH).deposit{value: marketEth}();
        _approveUniswapTokens(token, marketTokens, marketEth);

        (bool isWethToken0, address token0, address token1, uint256 amount0, uint256 amount1) =
            _getUniswapPoolParams(address(token), marketTokens, marketEth);

        return _createUniswapPosition(account, isWethToken0, token0, token1, amount0, amount1);
    }

    function _emitTokenGraduated(address token, address account, bool isWethToken0, uint256 amount0, uint256 amount1)
        internal
    {
        emit TokenGraduated(token, account, isWethToken0 ? amount0 : amount1, isWethToken0 ? amount1 : amount0);
    }

    function _emitLiquidityAdditionAttempted(
        address token,
        bool isWethToken0,
        uint256 amount0,
        uint256 amount1,
        string memory reason
    ) internal {
        emit LiquidityAdditionAttempted(
            token, isWethToken0 ? amount0 : amount1, isWethToken0 ? amount1 : amount0, reason
        );
    }

    /**
     * @dev Creates Uniswap V3 position
     */
    function _createUniswapPosition(
        address account,
        bool isWethToken0,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1
    ) internal returns (bool) {
        AccountState storage info = accountStates[account];
        address pool = info.pool;
        _adjustPoolPrice(pool, amount0, amount1);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: POOL_FEE,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: (amount0 * 90) / 100, // Allow 10% slippage
            amount1Min: (amount1 * 90) / 100, // Allow 10% slippage
            recipient: address(this),
            deadline: block.timestamp
        });

        // This will revert if price is too far out of range
        try positionManager.mint(params) returns (
            uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used
        ) {
            info.graduated = true;
            info.ethLiquidity = 0;
            _emitTokenGraduated(getAccountToken(account), account, isWethToken0, amount0Used, amount1Used);
            return true;
        } catch Error(string memory reason) {
            // Emit detailed failure reason
            _emitLiquidityAdditionAttempted(getAccountToken(account), isWethToken0, amount0, amount1, reason);
        } catch (bytes memory) {
            // Handle low-level errors
            _emitLiquidityAdditionAttempted(getAccountToken(account), isWethToken0, amount0, amount1, "Low level error");
        }
        return false;
    }

    /**
     * @dev Utility functions for string manipulation
     */
    function _labelToName(string memory str) internal pure returns (string memory) {
        bytes memory bStr = bytes(str);
        bStr[0] = bytes1(uint8(bStr[0]) - 32);
        return string(bStr);
    }

    function _labelToSymbol(string memory str) internal pure returns (string memory) {
        return LibString.upper(str);
    }

    /**
     * @dev Handles ETH refunds
     */
    function _handleRefund(uint256 ethUsed) internal {
        uint256 refund = msg.value - ethUsed;
        if (refund > 0) {
            SafeTransferLib.safeTransferETH(msg.sender, refund);
        }
    }

    /**
     * @dev Adjusts Uniswap V3 pool price to desired level before minting position
     * @param pool Address of the Uniswap V3 pool
     * @param amount0 Amount of token0 to adjust price
     *
     */
    function _adjustPoolPrice(address pool, uint256 amount0, uint256 amount1) internal returns (bool) {
        // Get current price from pool
        (uint160 currentSqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();

        uint256 priceRatio = (amount1 * 1e18) / amount0;
        uint256 sqrtPrice = FixedPointMathLib.sqrt(priceRatio);
        uint160 targetSqrtPriceX96 = uint160(((2 ** 96) * sqrtPrice) / 1e9);

        // Only swap if price needs adjustment
        if (currentSqrtPriceX96 != targetSqrtPriceX96) {
            bool zeroForOne = currentSqrtPriceX96 > targetSqrtPriceX96;

            // Swap to adjust price to target
            try IUniswapV3Pool(pool).swap(
                address(this), // recipient
                zeroForOne, // direction
                100, // small amount to move price
                targetSqrtPriceX96,
                "" // callback data
            ) {
                return true;
            } catch Error(string memory reason) {
                emit InitialSwapFailed(pool, currentSqrtPriceX96, targetSqrtPriceX96, reason);
            } catch (bytes memory) {
                emit InitialSwapFailed(pool, currentSqrtPriceX96, targetSqrtPriceX96, "Low level error");
            }
        }
        return false;
    }

    /**
     * @dev Utility to approve tokens for Uniswap
     */
    function _approveUniswapTokens(StackToken token, uint256 tokenAmount, uint256 ethAmount) internal {
        IWETH(WETH).approve(address(positionManager), ethAmount);
        token.approve(address(positionManager), tokenAmount);
    }

    /**
     * @dev Gets sorted token addresses and amounts for Uniswap pool
     */
    function _getUniswapPoolParams(address tokenAddress, uint256 tokenAmount, uint256 ethAmount)
        internal
        pure
        returns (bool isWethToken0, address token0, address token1, uint256 amount0, uint256 amount1)
    {
        isWethToken0 = WETH < tokenAddress;
        token0 = isWethToken0 ? WETH : tokenAddress;
        token1 = isWethToken0 ? tokenAddress : WETH;
        amount0 = isWethToken0 ? ethAmount : tokenAmount;
        amount1 = isWethToken0 ? tokenAmount : ethAmount;
    }

    /**
     * @dev Gets quote from bonding curve for buy
     * @param account Account to get quote for
     * @param netAmount Amount of ETH to quote
     * @return quote Amount of tokens that would be received
     */
    function _getBondingCurveQuote(address account, uint256 netAmount) internal view returns (uint256 quote) {
        uint256 progression = getBondingCurveProgression(account);
        quote = BondingCurve.getEthBuyQuote(progression, netAmount);
    }

    /**
     * @dev Calculates protocol and owner fees
     * @param tradeSize Size of trade to calculate fees for
     * @return protocolFee Fee for protocol
     * @return ownerFee Fee for owner
     */
    function calculateFees(uint256 tradeSize, address referrer)
        public
        pure
        returns (uint256 protocolFee, uint256 ownerFee, uint256 referralFee)
    {
        unchecked {
            uint256 totalFee = (tradeSize * TOTAL_FEE_BPS) / 10000;
            protocolFee = totalFee / 2;
            ownerFee = protocolFee / 2;
            if (referrer != address(0)) {
                referralFee = totalFee - protocolFee - ownerFee;
            } else {
                ownerFee = totalFee - protocolFee;
            }
        }
    }

    /**
     * @dev Distributes fees from a trade
     * @param account Account associated with trade
     * @param protocolFee Fee for protocol
     * @param ownerFee Fee for owner
     */
    function _distributeFees(
        address account,
        uint256 protocolFee,
        uint256 ownerFee,
        address referrer,
        uint256 referralFee
    ) internal {
        SafeTransferLib.safeTransferETH(feeRecipient, protocolFee);
        SafeTransferLib.safeTransferETH(account, ownerFee);
        if (referrer != address(0)) {
            SafeTransferLib.safeTransferETH(referrer, referralFee);
        }
    }

    /**
     * @dev Distributes proceeds from a sale
     * @param account Account associated with sale
     * @param recipient Recipient of proceeds
     * @param ethToSend Total ETH to distribute
     */
    function _distributeSaleProceeds(address account, address recipient, address referrer, uint256 ethToSend)
        internal
    {
        (uint256 protocolFee, uint256 ownerFee, uint256 referralFee) = calculateFees(ethToSend, referrer);
        uint256 ethToTransfer = ethToSend - protocolFee - ownerFee - referralFee;

        SafeTransferLib.safeTransferETH(recipient, ethToTransfer);
        SafeTransferLib.safeTransferETH(feeRecipient, protocolFee);
        SafeTransferLib.safeTransferETH(account, ownerFee);
        if (referrer != address(0)) {
            SafeTransferLib.safeTransferETH(referrer, referralFee);
        }
    }

    /**
     * @dev Gets ENS node for a label
     * @param label Label to get node for
     * @return Node hash
     */
    function _getENSNode(string calldata label) internal pure returns (bytes32) {
        bytes32 labelNode = keccak256(abi.encodePacked(label));
        return keccak256(abi.encodePacked(BASE_NODE, labelNode));
    }

    function _tokenExists(address tokenAddress) internal view returns (bool exists) {
        assembly {
            exists := gt(extcodesize(tokenAddress), 0)
        }
    }
}
