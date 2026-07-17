// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import "@openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IDividend} from "src/interfaces/Tax/IDividend.sol";
import {IPortal, IPortalTradeV2, IPortalTypes} from "src/interfaces/IPortal.sol";
import {BuyBackGuardUpgradeable} from "./BuyBackGuardUpgradeable.sol";
import {ISwapRegistry} from "src/interfaces/Tax/ISwapRegistry.sol";
import {IMultiDexRouter} from "src/interfaces/IMultiDexRouter.sol";
import {
    ITaxProcessor,
    TaxProcessorInitParams,
    PackedFeeConfig,
    PackedFeeConfigV2
} from "src/interfaces/Tax/ITaxProcessor.sol";

interface IWETH {
    function withdraw(uint256) external;
    function deposit() external payable;
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapRouter02 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);

    function factory() external pure returns (address);
}

/// @title TaxProcessorBase
/// @notice Abstract base contract containing shared state, events, modifiers and constructor
///         for TaxProcessor and TaxProcessorDispatchImpl.
abstract contract TaxProcessorBase is OwnableUpgradeable, ReentrancyGuardUpgradeable, BuyBackGuardUpgradeable {
    using SafeERC20 for IERC20;

    // --- Constants ---
    /// @notice Dead address for burning deflation tokens
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // --- Immutable Storage ---
    /// @notice WETH address for ETH conversion (immutable)
    address public immutable weth;

    /// @notice FlapBlackHole address (immutable)
    address public immutable flapBlackHole;

    /// @notice Portal address for swapping (immutable)
    address public immutable portal;

    /// @notice SwapRegistry address for dividend token swap path lookup (immutable).
    /// @dev Set in constructor so all clones share the same registry address.
    ///      Required when dividendToken != quoteToken and dividendToken != taxToken (Case 3).
    ///      May be address(0) for deployments that do not support custom dividend tokens.
    address public immutable swapRegistry;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address weth_, address flapBlackHole_, address portal_, address swapRegistry_) {
        require(weth_ != address(0), "TaxProcessor: zero WETH address");
        require(portal_ != address(0), "TaxProcessor: zero portal address");
        weth = weth_;
        flapBlackHole = flapBlackHole_;
        portal = portal_;
        swapRegistry = swapRegistry_;
        _disableInitializers();
    }

    // --- Storage ---
    /// @notice Quote token (WETH or other ERC20)
    address public quoteToken;

    /// @notice Tax token (the token that calls processing)
    address public taxToken;

    /// @notice Uniswap V2 router address
    address public router;

    /// @notice Fee receiver address
    address public feeReceiver;

    /// @notice Market receiver address (only set if marketBps > 0)
    address public marketAddress;

    /// @notice Dividend contract address (only set if dividendBps > 0)
    address public dividendAddress;

    /// @notice Accumulated quote token balance for fee
    uint256 public feeQuoteBalance;

    /// @notice Accumulated quote token balance for lp
    uint256 public lpQuoteBalance;

    /// @notice Accumulated quote token balance for market
    uint256 public marketQuoteBalance;

    /// @notice Accumulated quote token balance pending conversion to dividend token
    uint256 public pendingDividendQuoteTokenBalance;

    /// @notice Internal gas-optimized struct containing all fee configuration including commission
    /// @dev Packed into a single 256-bit storage slot for gas efficiency.
    /// Field breakdown:
    ///   - marketBps:     16 bits (basis points, max 65535)
    ///   - deflationBps:  16 bits (basis points, max 65535)
    ///   - lpBps:         16 bits (basis points, max 65535)
    ///   - dividendBps:   16 bits (basis points, max 65535)
    ///   - feeRate:       16 bits (basis points, max 65535)
    ///   - isWeth:         8 bits (boolean, padded to 8 bits for alignment)
    ///   - commissionBps: 16 bits (basis points, max 65535)
    /// Total: 16 + 16 + 16 + 16 + 16 + 8 + 16 = 104 bits (fits in one storage slot)
    struct PackedFeeConfigInternal {
        uint16 marketBps;
        uint16 deflationBps;
        uint16 lpBps;
        uint16 dividendBps;
        uint16 feeRate;
        bool isWeth;
        uint16 commissionBps;
    }

    /// @notice All fee-related configuration (including commission) packed into a single storage slot
    PackedFeeConfigInternal internal _feeConfig;

    /// @notice Total dividend tokens deposited to dividend contract
    uint256 public totalDividendTokenSent;

    /// @notice Total quote token added to liquidity
    uint256 public totalQuoteAddedToLiquidity;

    /// @notice Total tax token added to liquidity
    uint256 public totalTokenAddedToLiquidity;

    /// @notice Total quote token sent to marketing wallet
    uint256 public totalQuoteSentToMarketing;

    /// @notice Pre-bonding burn funds (deflation portion from bonding curve tax)
    uint256 public preBondBurnFunds;

    /// @notice Minimum buy back quote amount threshold
    uint256 public minBuyBackQuote;

    /// @notice Maximum gas limit for buy back operations
    uint256 public maxBuyBackGasLimit;

    // --- V3 Storage ---
    /// @notice The dividend token address.
    ///   address(0)  = use quoteToken (V2 behaviour).
    ///   taxToken    = self-dividend (Case 1): accumulated tax tokens sent directly.
    ///   other ERC20 = custom (Case 3): quoteToken is swapped via converter before deposit.
    address public dividendToken;

    /// @notice Optional commission receiver. address(0) = disabled.
    address public commissionReceiver;

    /// @notice Accumulated quote-token commission waiting to be dispatched.
    uint256 public commissionQuoteBalance;

    /// @notice MEV-protected converter address for Case 3 dividend swaps.
    /// @dev Only calls originating from this address may trigger the swap.
    address public converter;

    /// @notice Reference output amount used to determine liquidation-threshold direction.
    uint256 public liqExpectedOutputAmount;

    /// @notice Accumulated dividend tokens waiting to be deposited to dividend contract.
    /// @dev Holds the actual dividend token (taxToken for Case 1, quoteToken for Case 2 after conversion).
    uint256 public dividendTokenBalance;

    // --- Events ---
    event FlapTaxProcessorDispatchExecuted(
        address indexed taxToken, uint256 feeAmount, uint256 marketAmount, uint256 dividendAmount
    );
    event FlapTaxProcessorBurnExecuted(address indexed taxToken, uint256 quoteAmount, uint256 tokensBurned);
    event FlapTaxProcessorBuyBackSkipped(address indexed taxToken, uint256 quoteAmount, uint256 gasLeft, string reason);
    event FlapTaxProcessorPortalRefund(address indexed taxToken, uint256 refundAmount, bool isWeth);
    event FlapTaxProcessorDividendDepositSkipped(address indexed taxToken, uint256 amount, string reason);
    event FlapTaxProcessorTokensBurned(address indexed taxToken, uint256 amount);
    event FlapTaxProcessorBondingCurveTax(address indexed taxToken, uint256 quoteAmount);
    event FlapTaxProcessorProcessTaxTokens(address indexed taxToken, uint256 taxAmount);
    event FlapTaxProcessorMaxBuyBackGasLimitUpdated(uint256 oldLimit, uint256 newLimit);
    event FlapTaxProcessorMinBuyBackQuoteUpdated(uint256 oldAmount, uint256 newAmount);
    event FlapTaxProcessorCommissionPaid(address receiver, uint256 amount);
    event FlapTaxProcessorDividendConverted(address dividendToken, uint256 quoteIn, uint256 dividendOut);
    event FlapTaxProcessorConverterUpdated(address oldConverter, address newConverter);
    event FlapTaxProcessorCommissionConfigUpdated(address receiver, uint16 bps);
    /// @notice Emitted during initialize() when a processor is set up with a custom dividend token (Case 3).
    /// @dev No arguments are indexed. Used by backend to fast-discover MEV-protected processors.
    ///      Absence of this event does NOT mean MEV protection is not required (legacy processors).
    event FlapTaxProcessorMEVProtectionRequired(address taxProcessor, address taxToken);

    // --- Modifiers ---
    modifier onlyTaxToken() {
        require(msg.sender == taxToken, "TaxProcessor: caller is not the tax token");
        _;
    }
}

/// @title TaxProcessorDispatchImpl
/// @notice Implementation contract for the dispatch logic, deployed by TaxProcessor and called via delegatecall.
///         Inherits TaxProcessorBase for shared state layout and helper access.
contract TaxProcessorDispatchImpl is TaxProcessorBase {
    using SafeERC20 for IERC20;

    constructor(address weth_, address flapBlackHole_, address portal_, address swapRegistry_)
        TaxProcessorBase(weth_, flapBlackHole_, portal_, swapRegistry_)
    {}

    /// @notice Executes the dispatch logic. Called via delegatecall from TaxProcessor.dispatch().
    /// @dev nonReentrant is enforced by the caller (TaxProcessor.dispatch). Do not add it here.
    ///      Direct calls to this function on the TaxProcessorDispatchImpl instance are safe but
    ///      meaningless, since the impl holds no relevant persistent state (all state lives in the
    ///      TaxProcessor proxy that delegatecalls into this contract).
    function executeDispatch() external {
        // fee and optional channel commission
        uint256 feeAmount = feeQuoteBalance;
        uint256 commissionAmount = commissionQuoteBalance;
        // marketing wallet
        uint256 marketAmount = marketQuoteBalance;
        // burn amount
        uint256 burnAmount = preBondBurnFunds;
        // dividend in quote (if the dividend token is not quote, this amount will be swapped to dividend token)
        uint256 pendingDividendQuote = pendingDividendQuoteTokenBalance;
        // dividend in the actual dividend token, will be sent to dividend contract directly
        uint256 dividendTokenAmt = dividendTokenBalance;

        // Save snapshot for event (before local modifications)
        uint256 dividendAmountForEvent = pendingDividendQuote;

        // Clear balances first (checks-effects-interactions pattern)
        if (feeAmount > 0) feeQuoteBalance = 0;
        if (marketAmount > 0) marketQuoteBalance = 0;
        if (pendingDividendQuote > 0) pendingDividendQuoteTokenBalance = 0;
        if (burnAmount > 0) preBondBurnFunds = 0;
        if (commissionAmount > 0) commissionQuoteBalance = 0;
        if (dividendTokenAmt > 0) dividendTokenBalance = 0;

        PackedFeeConfigInternal memory config = _feeConfig;

        // Dispatch fee + market + commission (dividend handled separately below)
        if (config.isWeth) {
            _dispatchETH(feeAmount, marketAmount, commissionAmount);
        } else {
            _dispatchERC20(feeAmount, marketAmount, commissionAmount);
        }

        // Check token state once — shared by both dividend (Case 1) and burn logic below
        IPortalTradeV2.TokenStateV7 memory state = IPortal(portal).getTokenV7(taxToken);
        bool isOnDex = state.status == IPortalTypes.TokenStatus.DEX;

        // --- Dividend handling ---
        // Convert pending quote tokens to dividend tokens, then deposit all to dividend contract.
        // Case 1: dividendToken == taxToken — pending quote swapped to tax tokens via Portal (bonding
        //         curve) or DEX router (graduated); tax tokens added to dividendTokenAmt.
        // Case 2: dividendToken == quoteToken — merge pending quote into dividendTokenAmt (same token).
        // Case 3: dividendToken == custom ERC20 — converter swaps pending quote to dividend token.
        {
            address dvToken = dividendToken;

            if (dvToken == quoteToken) {
                // Case 2: quoteToken IS the dividend token — merge pending into dividend tokens
                dividendTokenAmt += pendingDividendQuote;
                pendingDividendQuote = 0;
            } else if (dvToken == taxToken) {
                // Case 1: dividend in tax tokens; convert pending quote to tax tokens
                if (pendingDividendQuote > 0) {
                    uint256 quoteIn = pendingDividendQuote;
                    pendingDividendQuote = 0;
                    uint256 converted;
                    if (isOnDex) {
                        // Token graduated to DEX — use DEX router (no threshold required)
                        converted = _swapQuoteForTokens(quoteIn);
                    } else if (quoteIn >= minBuyBackQuote) {
                        // Token still on bonding curve — use Portal when threshold is met
                        converted = _swapQuoteForTaxTokenViaPortal(quoteIn);
                    }else{
                        pendingDividendQuoteTokenBalance += quoteIn;
                    }
                    if (converted > 0) {
                        dividendTokenAmt += converted;
                        emit FlapTaxProcessorDividendConverted(dvToken, quoteIn, converted);
                    } 
                    // for security reason, We intentionally dropped the inputs for a failed swap.
                    // for most of the time, this could be the dust.  
                    // However, they will first be collected as the burn funds 
                    // If it cannot be used for burning, then it will be assimilated into the fee balance.  
                }
            } else {
                // Case 3: custom dividend token — only converter can trigger the swap
                if (msg.sender == converter && pendingDividendQuote > 0 && dividendAddress != address(0)) {
                    uint256 converted = _convertQuoteToDividendToken(pendingDividendQuote, dvToken);
                    if (converted > 0) {
                        dividendTokenAmt += converted;
                        emit FlapTaxProcessorDividendConverted(dvToken, pendingDividendQuote, converted);
                        pendingDividendQuote = 0;
                    }
                }
            }

            // Restore any unconsumed pending quote tokens
            if (pendingDividendQuote > 0) {
                pendingDividendQuoteTokenBalance += pendingDividendQuote;
            }

            // Deposit accumulated dividend tokens to dividend contract
            if (dividendTokenAmt > 0 && dividendAddress != address(0)) {
                if (!_sendToDividendContract(dividendTokenAmt, dvToken)) {
                    // Restore failed deposit to appropriate balance
                    if (dvToken == quoteToken) {
                        pendingDividendQuoteTokenBalance += dividendTokenAmt;
                    } else {
                        dividendTokenBalance += dividendTokenAmt;
                    }
                }
            }
        }

        // Process burn funds based on token state
        if (burnAmount > 0) {
            // TokenState: Tradable=BondingCurve, DEX=Graduated
            if (isOnDex) {
                // Token is on DEX, liquidate all remaining funds regardless of threshold
                // Use DEX router to swap quote tokens for tax tokens and burn
                uint256 taxTokensReceived = _swapQuoteForTokens(burnAmount);
                if (taxTokensReceived > 0) {
                    IERC20(taxToken).safeTransfer(flapBlackHole, taxTokensReceived);
                    emit FlapTaxProcessorBurnExecuted(taxToken, burnAmount, taxTokensReceived);
                } else {
                    // Swap failed (likely dust) — redirect to fee so _reconcileBalance() does not
                    // re-add it to preBondBurnFunds and cause an infinite retry loop on next dispatch.
                    feeQuoteBalance += burnAmount;
                    emit FlapTaxProcessorBuyBackSkipped(taxToken, burnAmount, gasleft(), "Dust: redirected to fee");
                }
            } else {
                // Token still on bonding curve, only process if exceeds threshold
                if (burnAmount >= minBuyBackQuote) {
                    uint256 taxTokensReceived = _swapQuoteForTaxTokenViaPortal(burnAmount);
                    if (taxTokensReceived > 0) {
                        IERC20(taxToken).safeTransfer(flapBlackHole, taxTokensReceived);
                        emit FlapTaxProcessorBurnExecuted(taxToken, burnAmount, taxTokensReceived);
                    } else {
                        // Swap returned zero tokens — accumulate for next dispatch
                        preBondBurnFunds += burnAmount;
                        emit FlapTaxProcessorBuyBackSkipped(taxToken, burnAmount, gasleft(), "Swap failed");
                    }
                } else {
                    // Below threshold — accumulate for next dispatch
                    preBondBurnFunds += burnAmount;
                }
            }
        }

        // Reconcile any untracked balance (refunds from portal swaps, donations, etc.)
        _reconcileBalance();

        emit FlapTaxProcessorDispatchExecuted(taxToken, feeAmount, marketAmount, dividendAmountForEvent);
    }

    /// @notice Dispatch ETH (when quote token is WETH) with optimized unwrapping
    function _dispatchETH(uint256 feeAmount, uint256 marketAmount, uint256 commissionAmount) internal {
        uint256 totalETHNeeded = 0;

        // Calculate total ETH needed for external addresses (fee + market + commission)
        if (feeAmount > 0) totalETHNeeded += feeAmount;
        if (marketAmount > 0 && marketAddress != address(0)) totalETHNeeded += marketAmount;
        if (commissionAmount > 0 && commissionReceiver != address(0)) totalETHNeeded += commissionAmount;

        // Unwrap all needed ETH at once
        if (totalETHNeeded > 0) {
            IWETH(weth).withdraw(totalETHNeeded);
        }

        uint256 ethUsed = 0;

        // Send fee
        if (feeAmount > 0) {
            (bool success,) = payable(feeReceiver).call{value: feeAmount}("");
            if (success) {
                ethUsed += feeAmount;
            }
        }

        // Send market
        if (marketAmount > 0 && marketAddress != address(0)) {
            (bool success,) = payable(marketAddress).call{value: marketAmount}("");
            if (success) {
                ethUsed += marketAmount;
                totalQuoteSentToMarketing += marketAmount;
            }
        }

        // Send commission
        if (commissionAmount > 0 && commissionReceiver != address(0)) {
            (bool success,) = payable(commissionReceiver).call{value: commissionAmount, gas: 100_000}("");
            if (success) {
                ethUsed += commissionAmount;
                emit FlapTaxProcessorCommissionPaid(commissionReceiver, commissionAmount);
            }
        }

        // If any ETH sends failed, wrap the remaining ETH back to WETH and add to fee balance
        uint256 remainingETH = totalETHNeeded - ethUsed;
        if (remainingETH > 0) {
            IWETH(weth).deposit{value: remainingETH}();
            feeQuoteBalance += remainingETH; // Add failed amounts to fee balance
        }
    }

    /// @notice Dispatch ERC20 tokens (when quote token is not WETH)
    function _dispatchERC20(uint256 feeAmount, uint256 marketAmount, uint256 commissionAmount) internal {
        // Send fee
        if (feeAmount > 0) {
            IERC20(quoteToken).safeTransfer(feeReceiver, feeAmount);
        }

        // Send market
        if (marketAmount > 0 && marketAddress != address(0)) {
            totalQuoteSentToMarketing += marketAmount;
            IERC20(quoteToken).safeTransfer(marketAddress, marketAmount);
        }

        // Send commission
        if (commissionAmount > 0 && commissionReceiver != address(0)) {
            IERC20(quoteToken).safeTransfer(commissionReceiver, commissionAmount);
            emit FlapTaxProcessorCommissionPaid(commissionReceiver, commissionAmount);
        }
    }

    /// @notice Swap quote tokens for tax tokens (reverse swap, used for DEX burn)
    function _swapQuoteForTokens(uint256 quoteAmount) internal returns (uint256 taxTokensReceived) {
        IERC20(quoteToken).safeApprove(router, 0);
        IERC20(quoteToken).safeApprove(router, quoteAmount);

        address[] memory path = new address[](2);
        path[0] = quoteToken;
        path[1] = taxToken;

        uint256 taxTokenBefore = IERC20(taxToken).balanceOf(address(this));

        try IUniswapRouter02(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            quoteAmount,
            0, // Accept any amount
            path,
            address(this),
            block.timestamp
        ) {
            taxTokensReceived = IERC20(taxToken).balanceOf(address(this)) - taxTokenBefore;
        } catch {
            // Reset approvals and return 0 if swap fails
            IERC20(quoteToken).safeApprove(router, 0);
            taxTokensReceived = 0;
        }
    }

    /// @notice Deposit tokens to Dividend contract
    function _sendToDividendContract(uint256 amount, address token) internal returns (bool success) {
        IERC20(token).safeApprove(dividendAddress, 0);
        IERC20(token).safeApprove(dividendAddress, amount);

        success = IDividend(dividendAddress).deposit(amount);
        if (success) {
            totalDividendTokenSent += amount;
        } else {
            emit FlapTaxProcessorDividendDepositSkipped(taxToken, amount, "Deposit failed or no shareholders");
        }
    }

    /// @notice Swap quote tokens to dividendToken via SwapRegistry (Case 3 only).
    /// @dev Only called by executeDispatch() when msg.sender == converter.
    ///      The converter MUST use a MEV-protected RPC to avoid sandwich attacks.
    function _convertQuoteToDividendToken(uint256 quoteAmount, address dvToken) internal returns (uint256 dvReceived) {
        // Emergency brake: if the dividend token has been blacklisted, skip conversion entirely.
        if (ISwapRegistry(swapRegistry).isBlacklisted(dvToken)) {
            return 0;
        }

        // Case 3: custom dividend token — use SwapRegistry
        ISwapRegistry.SwapInfo memory info = ISwapRegistry(swapRegistry).getSwapInfo(quoteToken, dvToken);
        if (!info.supported) {
            return 0;
        }

        address routerAddr = ISwapRegistry(swapRegistry).multiDexRouter();
        require(routerAddr != address(0), "TaxProcessor: no router in registry");

        IERC20(quoteToken).safeApprove(routerAddr, 0);
        IERC20(quoteToken).safeApprove(routerAddr, quoteAmount);

        uint256 dvBefore = IERC20(dvToken).balanceOf(address(this));

        if (info.poolType == ISwapRegistry.PoolType.V3) {
            IMultiDexRouter.ExactInputSingleParams memory p = IMultiDexRouter.ExactInputSingleParams({
                tokenIn: quoteToken,
                tokenOut: dvToken,
                fee: info.feeTier,
                recipient: address(this),
                amountIn: quoteAmount,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0
            });
            try IMultiDexRouter(routerAddr).exactInputSingle(info.dexId, p) {}
            catch {
                return 0;
            }
        } else {
            address[] memory path = new address[](2);
            path[0] = quoteToken;
            path[1] = dvToken;
            try IMultiDexRouter(routerAddr).swapExactTokensForTokens(info.dexId, quoteAmount, 1, path, address(this)) {}
            catch {
                return 0;
            }
        }

        dvReceived = IERC20(dvToken).balanceOf(address(this)) - dvBefore;
    }

    /// @notice Swap quote tokens for tax tokens via Portal (pure buyback, no burn logic).
    /// @dev duringBuyBack modifier: any tax collected during the swap goes to preBondBurnFunds.
    ///      Uses minOutputAmount: 1 so a legitimate zero-output result causes the Portal to revert,
    ///      meaning a return value of 0 from this function always means the swap was caught and failed.
    ///      Refunds are NOT handled here — _reconcileBalance() catches any untracked balances.
    /// @param quoteAmount The amount of quote tokens to swap.
    /// @return tokensBought The number of tax tokens received from the swap (0 if swap fails and is caught).
    function _swapQuoteForTaxTokenViaPortal(uint256 quoteAmount)
        internal
        duringBuyBack
        returns (uint256 tokensBought)
    {
        if (_feeConfig.isWeth) {
            IWETH(weth).withdraw(quoteAmount);

            IPortalTradeV2.ExactInputParams memory params = IPortalTradeV2.ExactInputParams({
                inputToken: address(0), // Native token (BNB/ETH)
                outputToken: taxToken,
                inputAmount: quoteAmount,
                minOutputAmount: 1,
                permitData: ""
            });

            try IPortal(portal).swapExactInput{value: quoteAmount, gas: maxBuyBackGasLimit}(params) returns (
                uint256 received
            ) {
                tokensBought = received;

                uint256 ethBalance = address(this).balance;
                if (ethBalance > 0) {
                    IWETH(weth).deposit{value: ethBalance}();
                }
            } catch {
                IWETH(weth).deposit{value: quoteAmount}();
                return 0;
            }
        } else {
            IERC20(quoteToken).safeApprove(portal, 0);
            IERC20(quoteToken).safeApprove(portal, quoteAmount);

            IPortalTradeV2.ExactInputParams memory params = IPortalTradeV2.ExactInputParams({
                inputToken: quoteToken,
                outputToken: taxToken,
                inputAmount: quoteAmount,
                minOutputAmount: 1,
                permitData: ""
            });

            try IPortal(portal).swapExactInput{gas: maxBuyBackGasLimit}(params) returns (uint256 received) {
                tokensBought = received;
                IERC20(quoteToken).safeApprove(portal, 0); // clear residual allowance after success
            } catch {
                IERC20(quoteToken).safeApprove(portal, 0); // clear allowance on failure
                return 0;
            }
        }
    }

    /// @notice Reconcile actual token balance with tracked balances
    /// @dev Any untracked balance (from refunds, donations, etc.) goes to preBondBurnFunds
    function _reconcileBalance() internal {
        uint256 actualBalance = IERC20(quoteToken).balanceOf(address(this));
        uint256 trackedBalance = feeQuoteBalance + marketQuoteBalance + pendingDividendQuoteTokenBalance
            + lpQuoteBalance + preBondBurnFunds + commissionQuoteBalance;

        if (actualBalance > trackedBalance) {
            uint256 untracked = actualBalance - trackedBalance;
            preBondBurnFunds += untracked;
            emit FlapTaxProcessorPortalRefund(taxToken, untracked, _feeConfig.isWeth);
        }
    }
}

/// @title TaxProcessor
/// @notice Main TaxProcessor contract. Handles all tax processing logic except dispatch,
///         which is delegated to TaxProcessorDispatchImpl to stay within the contract size limit.
contract TaxProcessor is TaxProcessorBase {
    using SafeERC20 for IERC20;

    /// @notice Address of the deployed TaxProcessorDispatchImpl used for dispatch delegation
    address public immutable DISPATCH_IMPL;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address weth_, address flapBlackHole_, address portal_, address swapRegistry_)
        TaxProcessorBase(weth_, flapBlackHole_, portal_, swapRegistry_)
    {
        DISPATCH_IMPL = address(new TaxProcessorDispatchImpl(weth_, flapBlackHole_, portal_, swapRegistry_));
    }

    // --- Initialization ---
    function initialize(TaxProcessorInitParams memory params) external initializer {
        // --- Input validation (all checks up front) ---
        require(params.router != address(0), "TaxProcessor: zero router");
        require(params.feeReceiver != address(0), "TaxProcessor: zero fee receiver");
        require(params.taxToken != address(0), "TaxProcessor: zero tax token");
        require(params.quoteToken != address(0), "TaxProcessor: zero quote token");
        require(params.dividendToken != address(0), "TaxProcessor: zero dividend token");
        require(params.feeRate <= 10000, "TaxProcessor: feeRate must be <= 10000");
        uint256 totalBps = uint256(params.marketBps) + uint256(params.deflationBps) + uint256(params.lpBps)
            + uint256(params.dividendBps);
        require(totalBps == 10000, "TaxProcessor: distribution bps must sum to 10000");
        if (params.marketBps > 0) require(params.marketAddress != address(0), "TaxProcessor: zero market address");
        if (params.dividendBps > 0) {
            require(params.dividendAddress != address(0), "TaxProcessor: zero dividend address");
        }

        // --- Initialize base contracts ---
        __Ownable_init();
        __ReentrancyGuard_init();
        __BuyBackGuard_init();

        // --- Basic addresses ---
        router = params.router;
        feeReceiver = params.feeReceiver;
        taxToken = params.taxToken;

        // --- Quote token ---
        bool isWeth = params.quoteToken == weth;
        quoteToken = params.quoteToken;

        // --- Optional addresses (only stored when their allocation is non-zero) ---
        if (params.marketBps > 0) marketAddress = params.marketAddress;
        // Always store dividendAddress when provided so tracker-only deployments (dividendBps == 0)
        // have a reachable dividend contract for share accounting and manual deposits.
        if (params.dividendAddress != address(0)) dividendAddress = params.dividendAddress;

        // --- Fee configuration + commission packed into a single storage slot ---
        _feeConfig = PackedFeeConfigInternal({
            marketBps: params.marketBps,
            deflationBps: params.deflationBps,
            lpBps: params.lpBps,
            dividendBps: params.dividendBps,
            feeRate: params.feeRate,
            isWeth: isWeth,
            commissionBps: params.commissionReceiver != address(0) ? params.commissionBps : 0
        });

        // --- Buy-back thresholds ---
        minBuyBackQuote = _calculateMinBuyBackQuote(isWeth, params.quoteToken);
        maxBuyBackGasLimit = 500_000;

        // --- Commission (optional; address(0) = disabled) ---
        if (params.commissionReceiver != address(0)) {
            commissionReceiver = params.commissionReceiver;
        }

        // --- Dividend token ---
        // Case 1: dividendToken == taxToken   → self-dividend, accumulate tax tokens directly.
        // Case 2: dividendToken == quoteToken → standard quote-token dividend, no swap needed.
        // Case 3: anything else               → custom ERC20, requires swapRegistry + converter.
        // The Case 3 swap-path/converter validation only applies when live dividends are enabled
        // (dividendBps > 0). In tracker-only mode (dividendBps == 0) no quote→dividend conversion
        // will ever happen at dispatch time, so an arbitrary custom dividend token is allowed
        // without a registered swap path, mirroring the launcher's `_validateTaxTokenV3Params`.
        if (
            params.dividendBps > 0 && params.dividendToken != params.taxToken
                && params.dividendToken != params.quoteToken
        ) {
            require(swapRegistry != address(0), "TaxProcessor: swapRegistry required for custom dividend token");
            require(
                ISwapRegistry(swapRegistry).isSwapSupported(params.quoteToken, params.dividendToken),
                "TaxProcessor: swap path not supported for dividend token"
            );
            require(params.converter != address(0), "TaxProcessor: converter required for custom dividend token");
            converter = params.converter;
            // Emit discovery event for the backend's event indexer.
            // NOTE: absence of this event must NOT be treated as proof that MEV protection is not required.
            emit FlapTaxProcessorMEVProtectionRequired(address(this), params.taxToken);
        }
        dividendToken = params.dividendToken;
        liqExpectedOutputAmount = params.liqExpectedOutputAmount;
    }

    // --- External Functions ---

    /// @notice Get the quote token address
    function getQuoteToken() external view returns (address) {
        return quoteToken;
    }

    /// @notice Process bonding curve tax in quote tokens
    /// @param quoteAmount The amount of quote tokens to process
    /// @dev Splits quote tokens into fee, market, dividend, lp, and deflation based on configured ratios
    ///      LP portion is added to lpQuoteBalance for later processing
    ///      Deflation portion is added to preBondBurnFunds for buyback and burn
    ///      During buyback (_isBuyingBack=true), all tax goes to preBondBurnFunds to avoid balance pollution
    function processBondingCurveTax(uint256 quoteAmount) external {
        require(quoteAmount > 0, "TaxProcessor: zero amount");

        IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), quoteAmount);

        if (_isBuyingBack()) {
            preBondBurnFunds += quoteAmount;
            emit FlapTaxProcessorBondingCurveTax(taxToken, quoteAmount);
            return;
        }

        PackedFeeConfigInternal memory config = _feeConfig;

        uint256 fee = (quoteAmount * uint256(config.feeRate)) / 10000;
        uint256 remaining = quoteAmount - fee;

        if (config.commissionBps > 0 && commissionReceiver != address(0)) {
            uint256 commission = (remaining * uint256(config.commissionBps)) / 10000;
            if (commission > 0) {
                commissionQuoteBalance += commission;
                remaining -= commission;
            }
        }

        uint256 market = (remaining * uint256(config.marketBps)) / 10000;
        uint256 deflation = (remaining * uint256(config.deflationBps)) / 10000;
        uint256 lp = (remaining * uint256(config.lpBps)) / 10000;
        uint256 dividend = remaining - market - deflation - lp;

        feeQuoteBalance += fee;
        marketQuoteBalance += market;
        pendingDividendQuoteTokenBalance += dividend;
        lpQuoteBalance += lp;
        preBondBurnFunds += deflation;

        emit FlapTaxProcessorBondingCurveTax(taxToken, quoteAmount);
    }

    /// @notice Process tax tokens: compute fees, split amounts, burn deflation, swap and distribute
    /// @param taxAmount The total amount of tax tokens to process
    /// @return liqThresholdDirection Direction to adjust liquidation threshold:
    ///         +1 = swap output below reference (price lower, raise threshold to liquidate less often),
    ///          0 = no reference set or exact match,
    ///         -1 = swap output exceeded reference (price higher, lower threshold to liquidate smaller amounts).
    function processTaxTokens(uint256 taxAmount) external onlyTaxToken returns (int8 liqThresholdDirection) {
        require(taxAmount > 0, "TaxProcessor: zero amount");

        IERC20(taxToken).safeTransferFrom(msg.sender, address(this), taxAmount);

        PackedFeeConfigInternal memory config = _feeConfig;

        uint256 fee = (taxAmount * uint256(config.feeRate)) / 10000;
        uint256 remaining = taxAmount - fee;

        uint256 commission = 0;
        if (config.commissionBps > 0 && commissionReceiver != address(0)) {
            commission = (remaining * uint256(config.commissionBps)) / 10000;
            if (commission > 0) {
                remaining -= commission;
            }
        }

        uint256 market = (remaining * uint256(config.marketBps)) / 10000;
        uint256 deflation = (remaining * uint256(config.deflationBps)) / 10000;
        uint256 lp = (remaining * uint256(config.lpBps)) / 10000;
        uint256 dividend = remaining - (market + deflation + lp);

        if (deflation > 0) {
            IERC20(taxToken).safeTransfer(flapBlackHole, deflation);
            emit FlapTaxProcessorTokensBurned(taxToken, deflation);
        }

        uint256 dividendToSwap = dividend;
        {
            address dvToken = dividendToken;
            if (dvToken == taxToken && dividend > 0) {
                dividendTokenBalance += dividend;
                dividendToSwap = 0;
            }
        }

        uint256 totalQuoteReceived = _processTokenDistribution(fee, market, lp, dividendToSwap, commission);

        emit FlapTaxProcessorProcessTaxTokens(taxToken, taxAmount);

        uint256 refAmount = liqExpectedOutputAmount;
        if (refAmount == 0 || totalQuoteReceived == 0) {
            liqThresholdDirection = 0;
        } else if (totalQuoteReceived > refAmount) {
            // Price is higher than expected: lower the threshold so liquidations sell smaller
            // amounts more frequently, avoiding a large single dump that nukes the price.
            liqThresholdDirection = -1;
        } else if (totalQuoteReceived < refAmount) {
            // Price is lower than expected: raise the threshold so the contract waits for more
            // tokens to accumulate before selling, reducing sell pressure during weak markets.
            liqThresholdDirection = 1;
        } else {
            liqThresholdDirection = 0;
        }
    }

    /// @notice Process token distribution: add liquidity first, then swap remaining tokens
    function _processTokenDistribution(uint256 fee, uint256 market, uint256 lp, uint256 dividend, uint256 commission)
        internal
        returns (uint256 totalQuoteReceived)
    {
        uint256 lpTaxToSwap = lp;

        if (lp > 0 && lpQuoteBalance > 0) {
            (uint256 actualTokenUsed, uint256 actualQuoteUsed) = _addLiquidity(lp, lpQuoteBalance);
            lpTaxToSwap = lp >= actualTokenUsed ? lp - actualTokenUsed : 0;
            lpQuoteBalance = lpQuoteBalance >= actualQuoteUsed ? lpQuoteBalance - actualQuoteUsed : 0;
        }

        uint256 totalToSwap = lpTaxToSwap + fee + commission + market + dividend;

        if (totalToSwap > 0) {
            uint256 quoteReceived = _swapTokensForQuote(totalToSwap);
            totalQuoteReceived = quoteReceived;

            if (quoteReceived > 0) {
                uint256 feeShare = fee > 0 ? (quoteReceived * fee) / totalToSwap : 0;
                uint256 commissionShare = commission > 0 ? (quoteReceived * commission) / totalToSwap : 0;
                uint256 marketShare = market > 0 ? (quoteReceived * market) / totalToSwap : 0;
                uint256 dividendShare = dividend > 0 ? (quoteReceived * dividend) / totalToSwap : 0;
                uint256 lpShare = lpTaxToSwap > 0 ? (quoteReceived * lpTaxToSwap) / totalToSwap : 0;

                feeQuoteBalance += feeShare;
                commissionQuoteBalance += commissionShare;
                marketQuoteBalance += marketShare;
                pendingDividendQuoteTokenBalance += dividendShare;
                lpQuoteBalance += lpShare;

                // Credit any wei remainder from integer-division rounding to feeQuoteBalance
                // so that no quote tokens are left untracked.
                uint256 distributed = feeShare + commissionShare + marketShare + dividendShare + lpShare;
                if (distributed < quoteReceived) {
                    feeQuoteBalance += quoteReceived - distributed;
                }
            }
        }
    }

    /// @notice Dispatch accumulated quote tokens to receivers.
    ///         The actual dispatch logic lives in TaxProcessorDispatchImpl and is called via delegatecall.
    function dispatch() external nonReentrant {
        (bool success, bytes memory result) =
            DISPATCH_IMPL.delegatecall(abi.encodeWithSelector(TaxProcessorDispatchImpl.executeDispatch.selector));
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    /// @notice Owner can update receivers
    function setReceivers(address feeReceiver_, address marketAddress_, address dividendAddress_) external onlyOwner {
        require(feeReceiver_ != address(0), "TaxProcessor: zero fee receiver");
        feeReceiver = feeReceiver_;

        PackedFeeConfigInternal memory config = _feeConfig;

        if (config.marketBps > 0) {
            require(marketAddress_ != address(0), "TaxProcessor: zero market address");
            marketAddress = marketAddress_;
        }

        if (config.dividendBps > 0) {
            require(dividendAddress_ != address(0), "TaxProcessor: zero dividend address");
            dividendAddress = dividendAddress_;
        }
    }

    /// @notice Owner can update tax configuration
    function setTaxConfig(uint16 feeRate_, uint16 marketBps_, uint16 deflationBps_, uint16 lpBps_, uint16 dividendBps_)
        external
        onlyOwner
    {
        require(feeRate_ <= 10000, "TaxProcessor: feeRate must be <= 10000");
        uint256 totalBps = uint256(marketBps_) + uint256(deflationBps_) + uint256(lpBps_) + uint256(dividendBps_);
        require(totalBps == 10000, "TaxProcessor: distribution bps must sum to 10000");

        if (marketBps_ > 0) {
            require(marketAddress != address(0), "TaxProcessor: market address not set");
        }
        if (dividendBps_ > 0) {
            require(dividendAddress != address(0), "TaxProcessor: dividend address not set");
        }

        PackedFeeConfigInternal memory config = _feeConfig;
        config.feeRate = feeRate_;
        config.marketBps = marketBps_;
        config.deflationBps = deflationBps_;
        config.lpBps = lpBps_;
        config.dividendBps = dividendBps_;
        _feeConfig = config;
    }

    /// @notice Owner can update maximum buy back gas limit
    function setMaxBuyBackGasLimit(uint256 newLimit) external onlyOwner {
        require(newLimit > 0, "TaxProcessor: zero maxBuyBackGasLimit");
        uint256 oldLimit = maxBuyBackGasLimit;
        maxBuyBackGasLimit = newLimit;
        emit FlapTaxProcessorMaxBuyBackGasLimitUpdated(oldLimit, newLimit);
    }

    /// @notice Owner can update minimum buy back quote amount
    function setMinBuyBackQuote(uint256 newAmount) external onlyOwner {
        require(newAmount > 0, "TaxProcessor: zero minBuyBackQuote");
        uint256 oldAmount = minBuyBackQuote;
        minBuyBackQuote = newAmount;
        emit FlapTaxProcessorMinBuyBackQuoteUpdated(oldAmount, newAmount);
    }

    // --- V3 Setter Functions ---

    /// @notice Owner can update commission configuration
    function setCommissionConfig(address receiver, uint16 bps) external onlyOwner {
        commissionReceiver = receiver;
        _feeConfig.commissionBps = bps;
        emit FlapTaxProcessorCommissionConfigUpdated(receiver, bps);
    }

    /// @notice Owner can update the dividend token
    function setDividendToken(address token) external onlyOwner {
        require(token != address(0), "TaxProcessor: dividendToken cannot be zero");
        // If the new dividend token is a custom ERC20 (not quoteToken and not taxToken),
        // validate that a swap path exists in the SwapRegistry and a converter is configured.
        // Only enforced when live dividends are enabled (dividendBps > 0); in tracker-only
        // mode no quote→dividend conversion is ever performed so the swap path is not required.
        if (_feeConfig.dividendBps > 0 && token != quoteToken && token != taxToken) {
            require(swapRegistry != address(0), "TaxProcessor: swapRegistry required for custom dividend token");
            require(
                ISwapRegistry(swapRegistry).isSwapSupported(quoteToken, token),
                "TaxProcessor: swap path not supported for dividend token"
            );
            require(converter != address(0), "TaxProcessor: converter required for custom dividend token");
        }
        dividendToken = token;
    }

    /// @notice Owner can update the converter address (for Case 3 MEV-protected swaps)
    function setConverter(address converter_) external onlyOwner {
        // Prevent setting converter to zero when a custom dividend token (Case 3) is configured.
        if (converter_ == address(0)) {
            address dvToken = dividendToken;
            require(
                dvToken == quoteToken || dvToken == taxToken,
                "TaxProcessor: converter cannot be zero when custom dividend token is set"
            );
        }
        address old = converter;
        converter = converter_;
        emit FlapTaxProcessorConverterUpdated(old, converter_);
    }

    /// @notice Owner can recalibrate the reference expected output for liquidation threshold direction
    function setLiqExpectedOutputAmount(uint256 amount) external onlyOwner {
        liqExpectedOutputAmount = amount;
    }

    // --- V3 View Functions ---

    /// @notice Returns true if this TaxProcessor requires a MEV-protected RPC for the converter
    function requiresMEVProtection() external view returns (bool) {
        address dvToken = dividendToken;
        return dvToken != quoteToken && dvToken != taxToken;
    }

    /// @notice Get packed fee configuration (backward-compatible view satisfying ITaxProcessor interface)
    function feeConfig() external view returns (PackedFeeConfig memory) {
        PackedFeeConfigInternal memory c = _feeConfig;
        return PackedFeeConfig({
            marketBps: c.marketBps,
            deflationBps: c.deflationBps,
            lpBps: c.lpBps,
            dividendBps: c.dividendBps,
            feeRate: c.feeRate,
            isWeth: c.isWeth
        });
    }

    /// @notice Get the commission in basis points (taken from remainder after protocol fee)
    function commissionBps() external view returns (uint16) {
        return _feeConfig.commissionBps;
    }

    /// @notice Returns the full fee configuration including commission bps
    function feeConfigV2() external view returns (PackedFeeConfigV2 memory result) {
        PackedFeeConfigInternal memory config = _feeConfig;
        result = PackedFeeConfigV2({
            marketBps: config.marketBps,
            deflationBps: config.deflationBps,
            lpBps: config.lpBps,
            dividendBps: config.dividendBps,
            feeRate: config.feeRate,
            isWeth: config.isWeth,
            commissionBps: config.commissionBps,
            dividendToken: dividendToken
        });
    }

    /// @notice Backward-compatible view for total dividend tokens sent.
    function totalQuoteSentToDividend() external view returns (uint256) {
        return totalDividendTokenSent;
    }

    /// @notice Backward-compatible view for pending dividend quote token balance.
    function dividendQuoteBalance() external view returns (uint256) {
        return pendingDividendQuoteTokenBalance;
    }

    // --- Internal Functions ---

    /// @notice Calculate minimum buy back quote amount based on chain and quote token
    function _calculateMinBuyBackQuote(bool isWeth, address quoteTokenAddr) internal view returns (uint256) {
        uint256 chainId = block.chainid;
        uint256 decimals = IERC20Metadata(quoteTokenAddr).decimals();

        if (chainId == 56 || chainId == 97) {
            if (isWeth) {
                return 0.05 ether;
            } else if (quoteTokenAddr == 0x000Ae314E2A2172a039B26378814C252734f556A) {
                return 100 ether;
            } else if (quoteTokenAddr == 0x924fa68a0FC644485b8df8AbfA0A41C2e7744444) {
                return 300 ether;
            } else {
                return 50 * (10 ** decimals);
            }
        } else if (chainId == 196) {
            if (isWeth) {
                return 0.3 ether;
            } else {
                return 50 * (10 ** decimals);
            }
        } else {
            return 0.1 ether;
        }
    }

    /// @notice Swap tax tokens for quote tokens
    function _swapTokensForQuote(uint256 amount) internal returns (uint256 quoteReceived) {
        IERC20(taxToken).safeApprove(router, 0);
        IERC20(taxToken).safeApprove(router, amount);

        address[] memory path = new address[](2);
        path[0] = taxToken;
        path[1] = quoteToken;

        uint256 quoteBefore = IERC20(quoteToken).balanceOf(address(this));

        IUniswapRouter02(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount, 0, path, address(this), block.timestamp
        );
        quoteReceived = IERC20(quoteToken).balanceOf(address(this)) - quoteBefore;
    }

    /// @notice Add liquidity to DEX
    function _addLiquidity(uint256 tokenAmount, uint256 quoteAmount)
        internal
        returns (uint256 actualTokenUsed, uint256 actualQuoteUsed)
    {
        IERC20(taxToken).safeApprove(router, 0);
        IERC20(taxToken).safeApprove(router, tokenAmount);
        IERC20(quoteToken).safeApprove(router, 0);
        IERC20(quoteToken).safeApprove(router, quoteAmount);

        (uint256 amountA, uint256 amountB,) = IUniswapRouter02(router).addLiquidity(
            taxToken, quoteToken, tokenAmount, quoteAmount, 0, 0, address(DEAD_ADDRESS), block.timestamp
        );

        actualTokenUsed = amountA;
        actualQuoteUsed = amountB;

        totalTokenAddedToLiquidity += actualTokenUsed;
        totalQuoteAddedToLiquidity += actualQuoteUsed;
    }

    // --- Emergency Functions ---

    /// @notice Withdraw all remaining tokens to a specified address
    /// @param token Token address to withdraw (use address(0) for quote token or native ETH)
    /// @param to Recipient address
    function withdrawAll(address token, address to) external onlyOwner {
        require(to != address(0), "TaxProcessor: zero address");

        if (token == address(0)) {
            if (_feeConfig.isWeth) {
                uint256 balance = address(this).balance;
                if (balance > 0) {
                    (bool success,) = payable(to).call{value: balance}("");
                    require(success, "TaxProcessor: ETH transfer failed");
                }
            } else {
                uint256 balance = IERC20(quoteToken).balanceOf(address(this));
                if (balance > 0) {
                    IERC20(quoteToken).safeTransfer(to, balance);
                }
            }
        } else {
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) {
                IERC20(token).safeTransfer(to, balance);
            }
        }
    }

    // --- Fallback ---
    /// @notice Allow contract to receive native ETH
    receive() external payable {}
}
