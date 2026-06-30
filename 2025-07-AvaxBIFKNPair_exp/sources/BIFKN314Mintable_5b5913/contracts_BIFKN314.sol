// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./BIFKNERC20.sol";
import "./BIFKN314LP.sol";
import "./PreventAutoSwap.sol";
import "./interfaces/IBIFKN314FactoryV2.sol";
import "./interfaces/IBIFKN314CALLEE.sol";
import "./interfaces/IERC314Errors.sol";
import "./interfaces/IERC314Events.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title BIFKN314
 * @dev This is a contract that implements the core functionality of the BIFKN314 token.
 * The contract is used to create a token that can be used for liquidity provision and swapping.
 * It follows the Automated Market Maker (AMM) model using the constant product formula.
 * The contract allows users to add and remove liquidity, swap tokens, and perform flash swaps.
 * The contract also accrues fees and distributes them to the feeTo address.
 * The contract is initialized with a supply cap.
 * The contract also maintains a reference to the BIFKN314LP contract for LP token management.
 * The contract allows for a factory address of address(0) to be set, which will disable fee distribution.
 * The contract owner can set the trading fee rate, maximum wallet percentage, and metadata URI.
 * The contract owner can also enable trading, set the fee collector address, and claim accrued trading fees.
 */

contract BIFKN314 is
    BIFKNERC20,
    ReentrancyGuard,
    PreventAutoSwap,
    IERC314Errors,
    IERC314Events
{
    using Math for uint256;

    /**
     * @dev Represents the address constant for the dead address.
     * The dead address is a predefined address with all zeros, used to represent
     * an address that is no longer in use or has been destroyed.
     */
    address public constant DEAD_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    /**
     * @dev The minimum liquidity required for a transaction.
     */
    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;

    /**
     * @dev The SCALE_FACTOR constant represents the scaling factor used in the contract.
     * It is set to 10000.
     */
    uint256 public constant SCALE_FACTOR = 10000;

    /**
     * @dev The MAX_FEE_RATE constant represents the maximum fee rate that can be set.
     * It is set to 500, which corresponds to a fee rate of 5%.
     */
    uint256 public constant MAX_FEE_RATE = 500; // 5% fee

    /**
     * @dev Represents the metadata URI for the contract.
     */
    string public metadataURI;

    /**
     * @dev Represents the LP token contract for the BIFKN314 contract.
     */
    BIFKN314LP public liquidityToken;

    /**
     * @dev A public boolean variable that indicates whether the contract is initialized or not.
     */
    bool public isInitialized;

    /**
     * @dev A boolean variable indicating whether trading is enabled or not.
     * Once trading is enabled, it cannot be disabled.
     * Trading must be enabled before users can swap tokens.
     * Trading can only be enabled by the contract owner.
     * Trading is disabled by default.
     */
    bool public tradingEnabled;

    /**
     * @dev A mapping that stores whether an address is exempt from the maximum wallet limit.
     */
    mapping(address => bool) public isMaxWalletExempt;

    /**
     * @dev Represents the last cumulative price of the native asset.
     */
    uint256 public price0CumulativeLast;

    /**
     * @dev Represents the last cumulative price of the token.
     */
    uint256 public price1CumulativeLast;

    /**
     * @dev Represents the timestamp of the last block for enabling twap
     */
    uint32 public blockTimestampLast;

    /**
     * @dev The address of the factory contract.
     */
    IBIFKN314FactoryV2 public factory;

    /**
     * @dev The maximum percentage of the total supply that a wallet can hold.
     * For example, a value of 100 represents 1% of the total supply.
     */
    uint256 public maxWalletPercent;

    /**
     * @dev A boolean variable that indicates whether the maximum wallet limit is enabled or not.
     */
    bool public maxWalletEnabled;

    /**
     * @dev Public variable to store the accrued native fees.
     */
    uint256 public accruedNativeFactoryFees;

    /**
     * @dev Public variable to store the amount of accrued token fees.
     */
    uint256 public accruedTokenFactoryFees;

    /**
     * @dev The tradingFeeRate variable represents the rate at which trading fees are charged.
     * It is a public variable, meaning it can be accessed and modified by other contracts and external accounts.
     * The value of tradingFeeRate is a uint256, which represents a non-negative integer.
     * If the value of tradingFeeRate is 0, no trading fees are charged.
     * 15 represents a trading fee of 0.15%.
     * 100 represents a trading fee of 1%.
     * If the value of tradingFeeRate is 500, a trading fee of 5% is charged.
     */
    uint256 public tradingFeeRate;

    /**
     * @dev Public variable to store the accrued trading fees.
     */
    uint256 public accruedNativeTradingFees;

    /**
     * @dev Public variable to store the accrued token trading fees.
     */
    uint256 public accruedTokenTradingFees;

    /**
     * @dev The address of the fee collector.
     */
    address public feeCollector;

    /**
     * @dev The address of the contract owner.
     */
    address public owner;

    /**
     * @dev Modifier that allows only the contract owner to execute the function.
     * Throws an error if the caller is not the owner.
     */
    modifier onlyOwner() {
        if (_msgSender() != owner) revert Unauthorized(_msgSender());
        _;
    }

    /**
     * @dev Modifier that allows only the fee collector to execute the function.
     * Throws an error if the caller is not the fee collector.
     */
    modifier onlyFeeCollector() {
        if (_msgSender() != feeCollector) revert Unauthorized(_msgSender());
        _;
    }

    /**
     * @dev Modifier to ensure that a transaction is executed before the specified deadline.
     * @param deadline The deadline timestamp after which the transaction is considered expired.
     * @notice This modifier reverts the transaction if the current block timestamp is greater than or equal to the deadline.
     */
    modifier ensureDeadline(uint deadline) {
        if (block.timestamp >= deadline) revert TransactionExpired();
        _;
    }

    /**
     * @dev Constructor function for the BIFKN314 contract.
     * It initializes the contract by calling the constructor of the BIFKNERC20 contract.
     * If the message sender is a contract, it sets the factory address to the message sender.
     * If the message sender is not a contract, it sets the factory address to address(0).
     * Finally, it transfers the ownership of the contract to the message sender.
     */
    constructor() BIFKNERC20() {
        address sender = _msgSender();
        _transferOwnership(sender);
    }

    /**
     * @dev Initializes the factory contract with a new owner.
     * @param newOwner The address of the new owner.
     * @notice This function can only be called once to initialize the factory contract.
     * @notice Once initialized, the ownership of the contract will be transferred to the factory contract.
     * @notice If the factory contract has already been initialized, calling this function will revert.
     */
    function initializeFactory(address newOwner) external virtual {
        // Check if the factory contract has already been initialized
        // if the address of the factory contract is not the zero address, revert
        if (address(factory) != address(0)) revert AlreadyInitialized();

        factory = IBIFKN314FactoryV2(newOwner);
        _transferOwnership(address(factory));
    }

    /**
     * @dev Initializes the contract with the given name and symbol.
     * Only the contract owner can call this function.
     *
     * @param tokenName The name of the contract.
     * @param tokenSymbol The symbol of the contract.
     */
    function initialize(
        string memory tokenName,
        string memory tokenSymbol
    ) public virtual override onlyOwner {
        super.initialize(tokenName, tokenSymbol);

        liquidityToken = new BIFKN314LP();
        liquidityToken.initialize(
            string(abi.encodePacked(tokenName, " LP Token")),
            string("BLP")
        );
    }

    /**
     * @dev Sets the total supply and mints tokens to the specified owner.
     * @param totalSupply_ The total supply of tokens to be minted.
     * @param owner_ The address of the owner to receive the minted tokens.
     * @param feeRate_ The trading fee rate to be set.
     * @param maxWalletPercent_ The maximum wallet percentage to be set.
     * @param metadataURI_ The metadata URI to be set.
     * @notice Only the contract owner can call this function.
     * @notice The total supply must be greater than zero.
     * @notice The total supply must not have been already minted.
     * @notice The owner address must not be the zero address.
     */
    function setSupplyAndMint(
        uint256 totalSupply_,
        address owner_,
        uint256 feeRate_,
        uint256 maxWalletPercent_,
        string memory metadataURI_
    ) public virtual onlyOwner {
        if (totalSupply_ == 0) {
            revert AmountMustBeGreaterThanZero();
        }
        if (totalSupply() > 0) {
            revert SupplyAlreadyMinted();
        }
        if (owner_ == address(0)) {
            revert InvalidOwner();
        }

        if (maxWalletPercent_ > 0) {
            maxWalletEnabled = true;
            setMaxWalletPercent(maxWalletPercent_);
        }

        metadataURI = metadataURI_;
        setTradingFeeRate(feeRate_);
        _transferOwnership(owner_);
        feeCollector = owner_;

        super._mint(owner_, totalSupply_);
    }

    /**
     * @dev Transfers tokens from the sender to the recipient.
     * Overrides the transfer function from the inherited contract.
     * If the recipient is this contract and autoSwap is not prevented,
     * then it automatically swaps tokens to native currency.
     * Otherwise, calls the transfer function from the inherited contract.
     * @param to The address receiving the tokens.
     * @param value The amount of tokens to transfer.
     * @return success A boolean indicating the success of the transfer.
     */
    function transfer(
        address to,
        uint256 value
    ) public override returns (bool) {
        if (_checkAndPerformAutoSwap(to, value)) {
            return true;
        } else {
            _checkMaxWallet(to, value);
            return super.transfer(to, value);
        }
    }

    /**
     * @dev Transfers tokens from one address to another using an allowance.
     * Overrides the transferFrom function from the inherited contract.
     * Includes a max wallet check to ensure the recipient's balance does not exceed the limit.
     * @param from The address sending the tokens.
     * @param to The address receiving the tokens.
     * @param value The amount of tokens to transfer.
     * @return success A boolean indicating the success of the transfer.
     */
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override returns (bool) {
        if (_checkAndPerformAutoSwap(to, value)) {
            return true;
        } else {
            _checkMaxWallet(to, value);
            return super.transferFrom(from, to, value);
        }
    }

    /**
     * @dev Internal function to transfer tokens from one address to another.
     * Overrides the internal transfer function from the inherited contract.
     * Calls the transfer function from the inherited contract.
     * This function is specifically used when transferring tokens to the contract
     * for the purpose of adding liquidity, swapping, or flash swapping.
     * @param from The address to transfer tokens from.
     * @param to The address to transfer tokens to.
     * @param value The amount of tokens to transfer.
     */
    function _internalTransfer(
        address from,
        address to,
        uint256 value
    ) internal {
        super._transfer(from, to, value);
    }

    /**
     * @dev Internal function to be called before any transfer of tokens.
     * Checks to see if an autoswap condition is true, if so it swaps tokens
     * @param to The address receiving the tokens.
     * @param amount The amount of tokens to transfer.
     * @return swapped A boolean indicating whether the tokens were swapped.
     */
    function _checkAndPerformAutoSwap(
        address to,
        uint256 amount
    ) internal returns (bool swapped) {
        if (to == address(this) && !_autoSwapIsPrevented()) {
            swapTokenToNative(
                amount,
                _calculateAutoSwapSlippage(amount, false),
                block.timestamp + 3 minutes
            );
            swapped = true;
        }
    }

    /**
     * @dev Adds liquidity to the contract by depositing tokens and native currency.
     * @param amountToken_ The amount of tokens to be deposited.
     * @param recipient The address of the recipient of the liquidity tokens.
     * @param deadline The deadline in unix time from the current timestamp for the transaction to occur.
     * @return liquidity The amount of liquidity tokens minted.
     */
    function addLiquidity(
        uint256 amountToken_,
        address recipient,
        uint256 deadline
    )
        public
        payable
        nonReentrant
        ensureDeadline(deadline)
        returns (uint256 liquidity)
    {
        address sender = _msgSender();

        if (amountToken_ == 0 || msg.value == 0) {
            revert AmountMustBeGreaterThanZero();
        }

        // get reserves
        (uint256 nativeReserve, uint256 tokenReserve) = getReserves();
        // the native reserve is the balance of the contract minus the value sent
        nativeReserve = nativeReserve - msg.value;

        uint256 lpTotalSupply = liquidityToken.totalSupply();
        uint256 amountNative = msg.value;
        uint256 amountToken = amountToken_;

        if (lpTotalSupply == 0) {
            uint256 _amountProduct = Math.sqrt(amountNative * amountToken);
            liquidity = _amountProduct - MINIMUM_LIQUIDITY;
            // Set owner of the first MINIMUM_LIQUIDITY tokens to the zero address
            liquidityToken.mint(DEAD_ADDRESS, MINIMUM_LIQUIDITY);
            // Liquidity is initialized
            isInitialized = true;
        } else {
            if (nativeReserve == 0 || tokenReserve == 0)
                revert InvalidReserves();

            // Determine the amount of token required to add liquidity
            // according to the native amount sent
            amountToken = (amountNative * tokenReserve) / nativeReserve;
            uint256 currentKValue = _calculateKValue(
                nativeReserve,
                tokenReserve
            );

            if (amountToken_ < amountToken) {
                revert AmountOfTokensLessThanMinimumRequired(
                    amountToken_,
                    amountToken
                );
            }

            /**
             * @dev Calculates the liquidity amount based on the given amounts of native currency and token.
             * The liquidity amount is determined by taking the minimum of two calculations:
             * 1. (amountNative * lpTotalSupply) / _nativeReserve
             * 2. (amountToken * lpTotalSupply) / _tokenReserve
             */
            liquidity = Math.min(
                (amountNative * lpTotalSupply) / nativeReserve,
                (amountToken * lpTotalSupply) / tokenReserve
            );

            /**
             * @dev Updates the reserves and checks the liquidity ratio.
             * The new k value is calculated by multiplying the new token reserve by the new native reserve.
             * If the new k value is less than the current k value, the transaction is reverted.
             */
            uint256 newNativeReserve = nativeReserve + amountNative;
            uint256 newTokenReserve = tokenReserve + amountToken;
            uint256 newKValue = newTokenReserve * newNativeReserve;
            if (newKValue < currentKValue) {
                revert DecreasesK();
            }
        }

        // check if liquidity is greater than 0
        if (liquidity == 0) {
            revert InsufficientLiquidityMinted();
        }
        // mint liquidity tokens to the liquidity provider
        liquidityToken.mint(recipient, liquidity);

        // Only transfer the necessary amount of tokens
        _internalTransfer(sender, address(this), amountToken);

        _updatePrices();

        emit AddLiquidity(sender, recipient, liquidity, msg.value, amountToken);
    }

    /**
     * @dev Removes liquidity from the contract by transferring native currency and tokens back to the liquidity provider.
     * @param amount The amount of liquidity to be removed.
     * @param recipient The address of the recipient of the native currency and tokens.
     * @param deadline The deadline in unix time from the current timestamp for the transaction to occur.
     * @return nativeAmount The amount of native currency received.
     * @return tokenAmount The amount of tokens received.
     * @notice The liquidity provider must have sufficient liquidity balance.
     */
    function removeLiquidity(
        uint256 amount,
        address recipient,
        uint256 deadline
    )
        public
        nonReentrant
        ensureDeadline(deadline)
        returns (uint256 nativeAmount, uint256 tokenAmount)
    {
        address sender = _msgSender();
        if (!isInitialized) {
            revert ContractIsNotInitialized();
        }

        uint256 lpTokenBalance = liquidityToken.balanceOf(sender);

        if (lpTokenBalance == 0) {
            revert YouHaveNoLiquidity();
        }
        if (amount > lpTokenBalance) {
            revert InsufficientLiquidity();
        }

        (nativeAmount, tokenAmount) = getAmountsForLP(amount);

        liquidityToken.burnFrom(sender, amount);

        _transferNative(recipient, nativeAmount);
        super._transfer(address(this), recipient, tokenAmount);

        emit RemoveLiquidity(
            sender,
            recipient,
            amount,
            nativeAmount,
            tokenAmount
        );

        _updatePrices();
    }

    /**
     * @dev Swaps native currency to tokens.
     * @param minimumTokensOut The minimum amount of tokens to receive in the swap.
     * @param deadline The deadline in unix time from current timestamp for the swap to occur.
     */
    function swapNativeToToken(
        uint256 minimumTokensOut,
        uint256 deadline
    )
        public
        payable
        nonReentrant
        ensureDeadline(deadline)
        returns (uint256[] memory amounts)
    {
        (uint256 nativeReserve, uint256 tokenReserve) = getReserves();
        uint256 nativeIn = msg.value;
        address sender = _msgSender();

        nativeReserve = nativeReserve - nativeIn;

        (uint256 tokensBought, uint256 factoryFee, uint256 tradingFee) = _swap(
            nativeIn,
            minimumTokensOut,
            nativeReserve,
            tokenReserve
        );

        accruedNativeTradingFees += tradingFee;
        _handleFactoryFees(factoryFee, true);

        _checkMaxWallet(sender, tokensBought);
        super._transfer(address(this), sender, tokensBought);

        _updatePrices();
        amounts = new uint256[](2);
        amounts[0] = nativeIn;
        amounts[1] = tokensBought;
        emit Swap(sender, 0, nativeIn, tokensBought, 0, false);
    }

    /**
     * @dev Swaps a specified amount of tokens for native currency.
     * @param tokensSold The amount of tokens to be sold.
     * @param minimumNativeOut The minimum amount of native currency expected to be received.
     * @param deadline The deadline in unix time from current timestamp for the swap to occur.
     */
    function swapTokenToNative(
        uint256 tokensSold,
        uint256 minimumNativeOut,
        uint256 deadline
    )
        public
        nonReentrant
        ensureDeadline(deadline)
        returns (uint256[] memory amounts)
    {
        (uint256 nativeReserve, uint256 tokenReserve) = getReserves();

        address sender = _msgSender();

        (uint256 nativeBought, uint256 factoryFee, uint256 tradingFee) = _swap(
            tokensSold,
            minimumNativeOut,
            tokenReserve,
            nativeReserve
        );

        accruedTokenTradingFees += tradingFee;
        _handleFactoryFees(factoryFee, false);

        _internalTransfer(sender, address(this), tokensSold);
        _transferNative(sender, nativeBought);

        _updatePrices();
        amounts = new uint256[](2);
        amounts[0] = tokensSold;
        amounts[1] = nativeBought;
        emit Swap(sender, tokensSold, 0, 0, nativeBought, false);
    }

    /**
     * @dev Executes a flash swap transaction.
     * @param recipient The address of the recipient of the flash swap.
     * @param amountNativeOut The amount of native currency to be sent to the recipient.
     * @param amountTokenOut The amount of tokens to be sent to the recipient.
     * @param data Additional data to be passed to the recipient.
     */
    function flashSwap(
        address recipient,
        uint256 amountNativeOut,
        uint256 amountTokenOut,
        bytes calldata data
    ) external preventAutoSwap {
        if (!isInitialized) revert ContractIsNotInitialized();
        if (!tradingEnabled) revert SwapNotEnabled();

        if (amountNativeOut == 0 && amountTokenOut == 0)
            revert AmountMustBeGreaterThanZero();

        if (recipient == address(0) || recipient == address(this))
            revert InvalidRecipient();

        (uint256 nativeReserve, uint256 tokenReserve) = getReserves();

        if (amountNativeOut > nativeReserve || amountTokenOut > tokenReserve)
            revert InsufficientLiquidity();

        address sender = _msgSender();

        if (amountNativeOut > 0) {
            // Sending native currency
            _transferNative(recipient, amountNativeOut);
        }
        if (amountTokenOut > 0) {
            // Sending token
            _checkMaxWallet(recipient, amountTokenOut);
            super._transfer(address(this), recipient, amountTokenOut);
        }

        IBIFKN314CALLEE(recipient).BIFKN314CALL(
            sender,
            amountNativeOut,
            amountTokenOut,
            data
        );

        (uint256 nativeReserveAfter, uint256 tokenReserveAfter) = getReserves();

        uint amountNativeIn = nativeReserveAfter > nativeReserve
            ? nativeReserveAfter - nativeReserve
            : 0;
        uint amountTokenIn = tokenReserveAfter > tokenReserve
            ? tokenReserveAfter - tokenReserve
            : 0;

        if (amountNativeIn == 0 && amountTokenIn == 0) {
            revert TokenRepaymentFailed();
        }

        {
            uint256 totalFees = factory.getBaseSwapRate(address(this)) +
                tradingFeeRate;

            uint256 nativeReserveAdjusted = (nativeReserveAfter *
                SCALE_FACTOR) - (amountNativeIn * totalFees);
            uint256 tokenReserveAdjusted = (tokenReserveAfter * SCALE_FACTOR) -
                (amountTokenIn * totalFees);

            if (
                nativeReserveAdjusted * tokenReserveAdjusted <
                nativeReserve * tokenReserve * (SCALE_FACTOR ** 2)
            ) {
                revert DecreasesK();
            }
        }

        (, , uint256 protocolFeeNative) = factory.getFees(
            address(this),
            amountNativeIn
        );
        (, , uint256 protocolFeeToken) = factory.getFees(
            address(this),
            amountTokenIn
        );

        uint256 tradingFeeNative = _calculateTradingFee(amountNativeIn);
        uint256 tradingFeeToken = _calculateTradingFee(amountTokenIn);

        accruedNativeTradingFees += tradingFeeNative;
        accruedTokenTradingFees += tradingFeeToken;

        _handleFactoryFees(protocolFeeNative, true);
        _handleFactoryFees(protocolFeeToken, false);

        _updatePrices();

        emit Swap(
            sender,
            amountTokenIn,
            amountNativeIn,
            amountTokenOut,
            amountNativeOut,
            true
        );
    }

    /**
     * @dev Calculates the amount of output tokens based on the input amount and reserves.
     * This accounts for all fees including the factory fee, trading fee, and base swap rate.
     * @param inputAmount The amount of input tokens.
     * @param inputReserve The amount of input tokens in the reserve.
     * @param outputReserve The amount of output tokens in the reserve.
     * @return outputAmount The amount of output tokens.
     * @return factoryFee The amount of factory fee.
     * @return tradingFee The amount of trading fee.
     */
    function getAmountOut(
        uint256 inputAmount,
        uint256 inputReserve,
        uint256 outputReserve
    )
        public
        view
        returns (uint256 outputAmount, uint256 factoryFee, uint256 tradingFee)
    {
        // Scale by 1e4 to avoid rounding errors
        // Since the SCALE_FACTOR is 1e4, the precision total is 1e8
        // This strikes a good balance between risk of overflow and precision
        uint256 precision = 1e4;

        (uint256 baseSwapRate, , uint256 protocolFee) = factory.getFees(
            address(this),
            inputAmount
        );

        uint256 feeFactor = SCALE_FACTOR - (baseSwapRate + tradingFeeRate);
        uint256 inputAmountScaled = inputAmount * precision;
        // if reserves are greater than 0
        if (inputReserve > 0 && outputReserve > 0) {
            factoryFee = protocolFee / precision;
            tradingFee = _calculateTradingFee(inputAmountScaled) / precision;
            uint256 inputAmountWithFee = inputAmountScaled * feeFactor;
            uint256 numerator = inputAmountWithFee * outputReserve;
            uint256 denominator = (inputReserve * SCALE_FACTOR * precision) +
                inputAmountWithFee;
            unchecked {
                outputAmount = numerator / denominator;
            }
        } else {
            revert InvalidReserves();
        }
    }

    /**
     * @dev Calculates the input amount and factory fee based on the output amount, output reserve, and input reserve.
     * This accounts for all fees including the factory fee, trading fee, and base swap rate.
     * @param outputAmount The desired output amount.
     * @param outputReserve The current output reserve.
     * @param inputReserve The current input reserve.
     * @return inputAmount The calculated input amount.
     */
    function getAmountIn(
        uint256 outputAmount,
        uint256 inputReserve,
        uint256 outputReserve
    ) public view returns (uint256 inputAmount) {
        // Scale by 1e4 to avoid rounding errors
        // Since the SCALE_FACTOR is 1e4, the precision total is 1e8
        // This strikes a good balance between risk of overflow and precision
        uint256 precision = 1e4;
        uint256 feeFactor = SCALE_FACTOR -
            (factory.getBaseSwapRate(address(this)) + tradingFeeRate);
        feeFactor = feeFactor * precision;
        // Ensure reserves are greater than 0
        if (outputReserve > 0 && inputReserve > 0) {
            uint256 numerator = inputReserve *
                outputAmount *
                SCALE_FACTOR *
                precision;
            uint256 denominator = (outputReserve - outputAmount) * feeFactor;
            unchecked {
                inputAmount = (numerator / denominator) + 1;
            }
        } else {
            revert InvalidReserves();
        }
    }

    /**
     * @dev Returns the number of tokens held by the contract.
     * @return tokenBalance The token balance of the contract.
     */
    function getTokensInContract() public view returns (uint256 tokenBalance) {
        tokenBalance = super.balanceOf(address(this));
    }

    /**
     * @dev Returns the reserves of the contract.
     * If the fees are greater than the reserves, the function returns 0 for the respective reserve.
     * @return amountNative The native reserve balance.
     * @return amountToken The token reserve balance.
     */
    function getReserves()
        public
        view
        returns (uint256 amountNative, uint256 amountToken)
    {
        uint256 totalNative = address(this).balance;
        uint256 totalNativeFees = accruedNativeTradingFees +
            accruedNativeFactoryFees;
        uint256 totalToken = getTokensInContract();
        uint256 totalTokenFees = accruedTokenTradingFees +
            accruedTokenFactoryFees;

        amountNative = totalNative >= totalNativeFees
            ? totalNative - totalNativeFees
            : 0;
        amountToken = totalToken >= totalTokenFees
            ? totalToken - totalTokenFees
            : 0;
    }

    /**
     * @dev Gets the amount of tokens held by the liquidity provider.
     * @param amount The amount of liquidity tokens to be converted.
     * @return nativeAmount The amount of native currency held by the liquidity provider.
     * @return tokenAmount The amount of tokens held by the liquidity provider.
     */
    function getAmountsForLP(
        uint256 amount
    ) public view returns (uint256 nativeAmount, uint256 tokenAmount) {
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        (uint256 nativeReserve, uint256 tokenReserve) = getReserves();

        if (nativeReserve == 0 || tokenReserve == 0) revert InvalidReserves();

        uint256 totalLPSupply = liquidityToken.totalSupply();
        if (totalLPSupply == 0) revert InsufficientLiquidity();

        nativeAmount = (amount * nativeReserve) / totalLPSupply;
        tokenAmount = (amount * tokenReserve) / totalLPSupply;

        if (nativeAmount == 0 || tokenAmount == 0)
            revert InsufficientLiquidity();
    }

    /**
     * @dev Enables trading by setting the `tradingEnabled` flag to true.
     * Can only be called by the contract owner.
     * Once trading is enabled, it cannot be disabled.
     */
    function setTradingEnabled() public onlyOwner {
        tradingEnabled = true;
    }

    /**
     * @dev Sets the fee collector address.
     * @param feeCollector_ The address of the fee collector.
     * @notice Only the contract owner can call this function.
     * @notice The fee collector address cannot be set to the zero address.
     */
    function setFeeCollector(address feeCollector_) external onlyOwner {
        if (feeCollector_ == address(0)) revert InvalidAddress();
        feeCollector = feeCollector_;
    }

    /**
     * @dev Sets the fee rate for trading.
     * @param feeRate The new fee rate to be set.
     * Requirements:
     * - `feeRate` must be less than or equal to 50 (5%).
     * Only the contract owner can call this function.
     */
    function setTradingFeeRate(uint256 feeRate) public onlyOwner {
        if (feeRate > MAX_FEE_RATE) revert InvalidFeeRate(); // 5%
        tradingFeeRate = feeRate;
    }

    /**
     * @dev Sets the maximum wallet percentage.
     * @param maxWalletPercent_ The maximum wallet percentage to be set.
     * Requirements:
     * - `maxWalletPercent_` must be less than or equal to 10000 (100%)
     * and greater than 0 if maxWalletEnabled is true.
     * Only the contract owner can call this function.
     */
    function setMaxWalletPercent(uint256 maxWalletPercent_) public onlyOwner {
        if (maxWalletPercent_ > 10000) revert InvalidMaxWalletPercent(); // 100%
        if (maxWalletEnabled && maxWalletPercent_ == 0)
            revert InvalidMaxWalletPercent();
        maxWalletPercent = maxWalletPercent_;
    }

    /**
     * @dev Enables or disables the maximum wallet limit.
     * @param enabled The boolean value to set the maximum wallet limit.
     * Requirements:
     * - Only the contract owner can call this function.
     */
    function setMaxWalletEnabled(bool enabled) public onlyOwner {
        if (enabled && maxWalletPercent == 0) revert InvalidMaxWalletPercent();
        maxWalletEnabled = enabled;
    }

    /**
     * @dev Sets the metadata URI for the token.
     * @param newURI The new metadata URI to be set.
     * Requirements:
     * - Only the contract owner can call this function.
     */
    function setMetadataURI(string memory newURI) public onlyOwner {
        metadataURI = newURI;
    }

    /**
     * @dev Sets the maximum wallet exemption status for a given address.
     * @param addressToChange The address for which the maximum wallet exemption status is to be set.
     * @param isExempt A boolean value indicating whether the address should be exempt from the maximum wallet limit.
     * Only the contract owner can call this function.
     * Requirements:
     * - The address to change cannot be the zero address, the contract address, or the dead address.
     * @notice If the address to change is the zero address, the contract address, or the dead address, the transaction will revert.
     */
    function setMaxWalletExempt(
        address addressToChange,
        bool isExempt
    ) public onlyOwner {
        if (
            !isExempt &&
            (addressToChange == address(0) ||
                addressToChange == address(this) ||
                addressToChange == DEAD_ADDRESS)
        ) revert InvalidAddress();
        isMaxWalletExempt[addressToChange] = isExempt;
    }

    /**
     * @dev Allows the fee collector to claim accrued trading fees.
     * The function transfers the accrued native currency and token trading fees to the fee collector.
     * The accrued amounts are reset to zero after the transfer.
     * Emits a `FeesCollected` event with the fee collector's address, accrued native amount, and accrued token amount.
     *
     * Requirements:
     * - The caller must be the fee collector.
     */
    function claimFees() external onlyFeeCollector {
        uint256 accruedNativeAmount = accruedNativeTradingFees;
        uint256 accruedTokenAmount = accruedTokenTradingFees;
        address sender = _msgSender();

        if (accruedNativeAmount == 0 && accruedTokenAmount == 0)
            revert NoFeesToClaim();

        accruedNativeTradingFees = 0;

        // If the accrued token amount is greater than the balance of the contract
        // set the accrued token amount to the balance of the contract
        if (accruedTokenAmount > getTokensInContract())
            accruedTokenAmount = getTokensInContract();

        accruedTokenTradingFees = 0;

        _transferNative(sender, accruedNativeAmount);
        super._transfer(address(this), sender, accruedTokenAmount);

        emit FeesCollected(sender, accruedNativeAmount, accruedTokenAmount);
    }

    /**
     * @dev Transfers the ownership of the contract to a new address.
     * Can only be called by the current owner.
     *
     * @param newOwner The address of the new owner.
     */
    function transferOwnership(address newOwner) public onlyOwner {
        if (newOwner == address(0)) revert InvalidOwner();

        _transferOwnership(newOwner);
    }

    /**
     * @dev Allows the current owner to renounce their ownership.
     * It sets the owner address to 0, effectively removing the ownership.
     */
    function renounceOwnership() external onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @notice Synchronizes the contract state by updating the prices.
     * @dev This function is protected by the nonReentrant modifier to prevent reentrancy attacks.
     */
    function sync() external nonReentrant {
        _updatePrices();
    }

    /**
     * @dev Transfers the ownership of the contract to a new address.
     * Can only be called by the current owner.
     *
     * @param newOwner The address of the new owner.
     * @notice Emits an {OwnershipTransferred} event.
     */
    function _transferOwnership(address newOwner) internal {
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    /**
     * @dev Calculates the product of two input values.
     * @param reserve1 The first input value.
     * @param reserve2 The second input value.
     * @return kValue_ The product of the two input values.
     */
    function _calculateKValue(
        uint256 reserve1,
        uint256 reserve2
    ) internal pure returns (uint256 kValue_) {
        kValue_ = reserve1 * reserve2;
    }

    /**
     * @dev Internal function to calculate the trading fee for a given amount.
     * @param amount The amount to apply the fee to.
     * @return amountForFee The amount to be deducted as a trading fee.
     * @notice If the amount is zero, the transaction will revert.
     * @notice If the trading fee rate is zero, the function will return zero.
     * @notice If the trading fee rate is 500, the function will return 5% of the amount.
     */
    function _calculateTradingFee(
        uint256 amount
    ) internal view returns (uint256 amountForFee) {
        // If the trading fee rate is 0, return 0
        if (tradingFeeRate == 0) amountForFee = 0;
        else {
            amountForFee = (amount * tradingFeeRate) / SCALE_FACTOR;
        }
    }

    /**
     * @dev Checks if the recipient's wallet balance exceeds the maximum allowed amount.
     * @param recipient The address of the recipient.
     * @param amount The amount to be transferred.
     * @notice If the max wallet limit is exceeded, the transaction will revert.
     */
    function _checkMaxWallet(address recipient, uint256 amount) internal view {
        if (!maxWalletEnabled) return; // Skip if max wallet is not enabled
        // Only apply the max wallet check if the recipient is not (this) contract, address(0), or the dead address
        // and if the recipient is not exempt from the max wallet limit
        if (
            recipient == address(this) ||
            recipient == address(0) ||
            recipient == DEAD_ADDRESS ||
            isMaxWalletExempt[recipient]
        ) {
            return;
        }

        uint256 maxWalletAmount = ((totalSupply() * maxWalletPercent) / 10000);
        if (balanceOf(recipient) + amount > maxWalletAmount) {
            revert MaxWalletAmountExceeded();
        }
    }

    /**
     * @dev Internal function to check for swap errors.
     * @param tokensSold The number of tokens sold in the swap.
     * @param nativeReserve The native reserve balance.
     * @param tokenReserve The token reserve balance.
     * @notice If the contract is not initialized, the transaction will revert.
     * @notice If the reserves are invalid, the transaction will revert.
     * @notice If the swap is not enabled, the transaction will revert.
     * @notice If the amount of tokens sold is zero, the transaction will revert.
     */
    function _checkForSwapErrors(
        uint256 tokensSold,
        uint256 nativeReserve,
        uint256 tokenReserve
    ) internal view {
        if (!isInitialized) revert ContractIsNotInitialized();
        if (!tradingEnabled) revert SwapNotEnabled();
        if (tokensSold == 0) {
            revert AmountMustBeGreaterThanZero();
        }
        if (nativeReserve == 0 || tokenReserve == 0) revert InvalidReserves();
    }

    /**
     * @dev Performs a swap operation between two reserves.
     * @param amountIn The amount of tokens being swapped in.
     * @param minimumAmountOut The minimum amount of tokens expected to be received.
     * @param reserveIn The reserve of the input token.
     * @param reserveOut The reserve of the output token.
     * @return amountOut The amount of tokens received after the swap.
     * @return factoryFee The fee charged by the factory for the swap.
     * @return tradingFee The fee charged for the swap.
     */
    function _swap(
        uint256 amountIn,
        uint256 minimumAmountOut,
        uint256 reserveIn,
        uint256 reserveOut
    )
        internal
        view
        returns (uint256 amountOut, uint256 factoryFee, uint256 tradingFee)
    {
        _checkForSwapErrors(amountIn, reserveIn, reserveOut);

        uint256 currentKValue = _calculateKValue(reserveIn, reserveOut);

        (amountOut, factoryFee, tradingFee) = getAmountOut(
            amountIn,
            reserveIn,
            reserveOut
        );

        if (amountOut == 0) revert BoughtAmountTooLow();
        if (amountOut < minimumAmountOut) revert SlippageToleranceExceeded();

        uint256 newReserveIn = reserveIn + (amountIn - tradingFee - factoryFee);

        uint256 newReserveOut = reserveOut - amountOut;

        if (_calculateKValue(newReserveIn, newReserveOut) < currentKValue)
            revert DecreasesK();
    }

    /**
     * @dev Calculates the cumulative prices based on the provided native and token reserves.
     */
    function _updatePrices() private {
        (uint256 nativeReserve, uint256 tokenReserve) = getReserves();

        if (nativeReserve == 0 || tokenReserve == 0) revert InvalidReserves();

        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // Overflow is desired

        if (timeElapsed > 0 && nativeReserve != 0 && tokenReserve != 0) {
            // Simulate fixed-point precision using a scaling factor
            uint256 scalingFactor = 2 ** 112;

            // Calculate price ratios with scaling to simulate UQ112x112 precision
            // Reflects the price of token in native currency
            uint256 price0Ratio = (nativeReserve * scalingFactor) /
                tokenReserve;
            // Reflects the price of native currency in token
            uint256 price1Ratio = (tokenReserve * scalingFactor) /
                nativeReserve;

            // Update cumulative prices
            price0CumulativeLast += price0Ratio * timeElapsed;
            price1CumulativeLast += price1Ratio * timeElapsed;

            // Update last block timestamp
            blockTimestampLast = blockTimestamp;
        }

        emit PricesUpdated(
            price0CumulativeLast,
            price1CumulativeLast,
            blockTimestampLast
        );
    }

    /**
     * @dev Accrues fees to the contract.
     * @param factoryFee The amount of fees to be accrued.
     * @param native A boolean value indicating whether the fee is in native currency or not.
     */
    function _handleFactoryFees(uint256 factoryFee, bool native) internal {
        // Check if the factory contract is set
        if (address(factory) != address(0)) {
            address feeTo = factory.feeTo();
            uint256 distributionThreshold = factory.feeDistributionThreshold();

            // Accrue fees and distribute if threshold is reached
            if (feeTo != address(0)) {
                if (native) {
                    accruedNativeFactoryFees += factoryFee;
                } else {
                    accruedTokenFactoryFees += factoryFee;
                }

                _distributeFees(feeTo, distributionThreshold);
            }
        }
    }

    /**
     * @dev Distributes fees to a specified address if the distribution threshold is reached.
     * @param feeTo The address to which the fees will be distributed.
     * @param distributionThreshold The threshold at which fees will be distributed.
     */
    function _distributeFees(
        address feeTo,
        uint256 distributionThreshold
    ) internal {
        uint256 nativeFees = accruedNativeFactoryFees;
        uint256 tokenFees = accruedTokenFactoryFees;
        bool nativeDistributed = false;
        bool tokenDistributed = false;

        // Only distribute fees if either the native or token fees are greater than 0
        if (nativeFees == 0 && tokenFees == 0) return;

        // Distribute native fees if threshold is reached
        if (nativeFees > 0 && nativeFees >= distributionThreshold) {
            accruedNativeFactoryFees = 0;
            nativeDistributed = true;
        }

        // Distribute token fees if threshold is reached
        if (tokenFees > 0) {
            (uint256 nativeReserve, uint256 tokenReserve) = getReserves();

            uint256 nativeAmount = (tokenFees * nativeReserve) / tokenReserve;

            if (nativeAmount >= distributionThreshold) {
                if (tokenFees > getTokensInContract()) {
                    tokenFees = getTokensInContract();
                }
                accruedTokenFactoryFees = 0;
                tokenDistributed = true;
            }
        }

        if (nativeDistributed) _transferNative(feeTo, nativeFees);
        if (tokenDistributed) super._transfer(address(this), feeTo, tokenFees);

        // Emit event if fees are distributed
        if (nativeDistributed || tokenDistributed)
            emit FeesDistributed(feeTo, nativeFees, tokenFees);
    }

    /**
     * @dev Internal function to transfer native currency to a specified address.
     * @param to The address to transfer the native currency to.
     * @param amount The amount of native currency to transfer.
     * @notice If the transfer fails, the transaction will revert.
     */
    function _transferNative(address to, uint256 amount) internal {
        if (amount == 0) return;
        if (to == address(0)) revert InvalidAddress();

        if (amount > address(this).balance) {
            amount = address(this).balance;
        }
        (bool success, ) = payable(to).call{value: amount}("");
        if (!success) revert FailedToSendNativeCurrency();
    }

    /**
     * @dev Calculates the minimum amount out with slippage for an auto swap.
     * @param amount The input amount.
     * @param isNative A boolean indicating whether the input is in the native token or not.
     * @return amountOutMin The minimum amount out with slippage.
     */
    function _calculateAutoSwapSlippage(
        uint256 amount,
        bool isNative
    ) internal view returns (uint256 amountOutMin) {
        (uint256 nativeReserve, uint256 tokenReserve) = getReserves();
        (uint256 amountOut, , ) = getAmountOut(
            amount,
            isNative ? nativeReserve : tokenReserve,
            isNative ? tokenReserve : nativeReserve
        );
        amountOutMin = amountOut - (amountOut / 20); // 5% slippage
    }

    // Function to receive native
    /**
     * @dev Fallback function to receive native currency.
     * It calls the `swapNativeToToken` function with a minimum token out amount of 0 (i.e. infinite slippage).
     */
    receive() external payable {
        if (!_autoSwapIsPrevented()) {
            swapNativeToToken(
                _calculateAutoSwapSlippage(msg.value, true),
                block.timestamp + 3 minutes
            );
        }
    }
}
