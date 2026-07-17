// SPDX-License-Identifier: BUSL-1.1
// version 1.14.0
pragma solidity 0.8.29;

import {
    I_TTSwap_Market,
    S_ProofState,
    S_GoodState,
    S_ProofKey,
    S_GoodTmpState
} from "./interfaces/I_TTSwap_Market.sol";
import {L_Good} from "./libraries/L_Good.sol";
import {L_Transient} from "./libraries/L_Transient.sol";
import {TTSwapError} from "./libraries/L_Error.sol";
import {L_Proof, L_ProofIdLibrary} from "./libraries/L_Proof.sol";
import {L_GoodConfigLibrary} from "./libraries/L_GoodConfig.sol";
import {L_UserConfigLibrary} from "./libraries/L_UserConfig.sol";
import {L_CurrencyLibrary} from "./libraries/L_Currency.sol";
import {
    L_TTSwapUINT256Library,
    toTTSwapUINT256,
    add,
    lowerprice
} from "./libraries/L_TTSwapUINT256.sol";
import {IMulticall_v4} from "./interfaces/IMulticall_v4.sol";
import {I_TTSwap_Token} from "./interfaces/I_TTSwap_Token.sol";
import {L_SignatureVerification} from "./libraries/L_SignatureVerification.sol";

/**
 * @title TTSwap_Market
 * @author ttswap.exchange@gmail.com
 * @dev v1.15.0 Core market contract for TTSwap protocol that manages goods trading, investing, and staking operations
 * @notice This contract implements a decentralized market system with the following key features:
 * - Meta good, value goods, and normal goods management
 * - Automated market making (AMM) with configurable fees
 * - Investment and disinvestment mechanisms
 * - Commission distribution system
 * website http://www.ttswap.io
 * twitter https://x.com/ttswapfinance
 * telegram https://t.me/ttswapfinance
 * discord https://discord.gg/XygqnmQgX3
 */
contract TTSwap_Market is I_TTSwap_Market, IMulticall_v4 {
    using L_GoodConfigLibrary for uint256;
    using L_UserConfigLibrary for uint256;
    using L_ProofIdLibrary for S_ProofKey;
    using L_TTSwapUINT256Library for uint256;
    using L_Good for S_GoodState;
    using L_Proof for S_ProofState;
    using L_CurrencyLibrary for address;
    using L_SignatureVerification for bytes;

    /**
     * @dev Address of the official TTS token contract
     * @notice Handles:
     * - Minting rewards for market participation
     * - Staking operations and rewards
     * - Referral tracking and rewards
     * - Governance token functionality
     */
    address internal implementation;
    I_TTSwap_Token internal immutable TTS_CONTRACT;

    mapping(address _trader => uint256 nonce) private nonces;
    bool internal upgradeable;

    /**
     * @dev Mapping of good addresses to their state information
     * @notice Stores the complete state of each good including:
     * - Current trading state(invest quantity & current quantity)
     * - Investment state (invest shares & invest value)
     * - Owner information
     * - Configuration parameters
     */
    mapping(address goodid => S_GoodState) private goods;

    /**
     * @dev Mapping of proof IDs to their state information
     * @notice Records all investment proofs in the system:
     * shares amount0:normal good shares amount1:value good shares
     * state amount0:total value : amount1:total actual value
     * invest amount0:normal good virtual quantity amount1:normal good actual quantity
     * valueinvest amount0:value good virtual quantity amount1:value good actual quantity
     */
    mapping(uint256 proofid => S_ProofState) private proofs;
    uint256 internal immutable INITIAL_CHAIN_ID;
    uint128 internal constant executeFee = 50_000_000_000; //5*10**10
    bytes32 internal immutable INITIAL_DOMAIN_SEPARATOR;

    /**
     * @dev Constructor for TTSwap_Market
     * @param _TTS_Contract The address of the official token contract
     */
    constructor(I_TTSwap_Token _TTS_Contract) {
        TTS_CONTRACT = _TTS_Contract;
        INITIAL_CHAIN_ID = block.chainid;
        INITIAL_DOMAIN_SEPARATOR = computeDomainSeparator();
    }

    /// only market admin can execute
    modifier onlyMarketadmin() {
        if (!TTS_CONTRACT.userConfig(msg.sender).isMarketAdmin())
            revert TTSwapError(1);
        _;
    }

    /// only market manager can execute
    modifier onlyMarketor() {
        if (!TTS_CONTRACT.userConfig(msg.sender).isMarketManager())
            revert TTSwapError(2);
        _;
    }

    /// run when eth token transfer to market contract
    modifier msgValue() {
        L_Transient.checkbefore();
        _;
        L_Transient.checkafter();
    }

    /// @notice Top-level reentrancy guard (used by multicall only).
    /// Sets lock to 1 (multicall context) so inner functions can enter via guardedEntry.
    modifier noReentrant() {
        if (L_Transient.get() != 0) revert TTSwapError(3);
        L_Transient.set(1);
        _;
        L_Transient.set(0);
    }

    /// @notice Guarded entry: works standalone (lock 0→2) and inside multicall (lock 1→2).
    /// Reverts on reentrancy (lock == 2). Restores previous lock level on exit.
    modifier guardedEntry() {
        uint256 lock = L_Transient.get();
        if (lock > 1) revert TTSwapError(3);
        L_Transient.set(2);
        _;
        L_Transient.set(lock);
    }

    /// @dev Internal function to validate trader matches msg.sender
    function _checkTrader(address _trader) private view {
        if (_trader != msg.sender) revert TTSwapError(39);
    }

    /// @dev Internal function to check if a good is active (not frozen and has state)
    function _checkGoodActive(
        address _goodid,
        uint8 freezeErr,
        uint8 emptyErr
    ) private view {
        // Storage pointer avoids recomputing the mapping key hash twice
        S_GoodState storage g = goods[_goodid];
        if (g.goodConfig.isFreeze()) revert TTSwapError(freezeErr);
        if (g.currentState == 0) revert TTSwapError(emptyErr);
    }

    /// @notice Enables calling multiple methods in a single call to the contract
    /// @inheritdoc IMulticall_v4
    function multicall(
        bytes[] calldata data
    ) external payable msgValue noReentrant returns (bytes[] memory results) {
        uint256 len = data.length;
        results = new bytes[](len);
        for (uint256 i = 0; i < len; ) {
            (bool success, bytes memory result) = address(this).delegatecall(
                data[i]
            );

            if (!success) {
                // bubble up the revert reason
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }

            results[i] = result;
            unchecked { ++i; }
        }
    }

    /**
     * @dev Initializes a meta good with initial liquidity
     * @param _erc20address The address of the ERC20 token to be used as the meta good
     * @param _initial The initial liquidity amounts:
     *        - amount0: Initial token value
     *        - amount1: Initial token amount
     * @param _goodConfig Configuration parameters for the good:
     *        - Fee rates (trading, investment)
     *        - Trading limits (min/max amounts)
     *        - Special flags ( emergency pause)
     * @param data Additional data for token transfer
     * @return bool Success status of the initialization
     * @notice This function:
     * - Creates a new meta good with specified parameters
     * - Sets up initial liquidity pool
     * - Mints corresponding tokens to the market creator
     * - Initializes proof tracking
     * - Emits initialization events
     * @custom:security Only callable by market admin
     */
    /// @inheritdoc I_TTSwap_Market
    function initMetaGood(
        address _erc20address,
        uint256 _initial,
        uint256 _goodConfig,
        bytes calldata data
    ) external payable onlyMarketadmin msgValue returns (bool) {
        if (!_goodConfig.isvaluegood()) revert TTSwapError(4);
        if (goods[_erc20address].owner != address(0)) revert TTSwapError(5);
        _erc20address.transferFrom(
            msg.sender,
            msg.sender,
            _initial.amount1(),
            data
        );
        goods[_erc20address].init(_initial, _goodConfig);
        /// update good to value good & initialize good config
        // Set default fee splits and max power for the meta/value good.
        goods[_erc20address].modifyGoodConfig(
            0x30d4204000000000000000000000000000000000000000000000000000000000
        ); //6*2**28+ 1*2**24+ 5*2**21+8*2**16+8*2**11+2*2**6
        goods[_erc20address].modifyGoodCoreConfig(
            0x8000000000000000000000000000000000000000000000000000000000000000
        ); //2**255
        uint256 proofid = S_ProofKey(msg.sender, _erc20address, address(0))
            .toId();
        // Seed the proof with initial shares/value/quantity; this anchors the pool's initial V/Q/I.
        proofs[proofid].updateInvest(
            _erc20address,
            address(0),
            toTTSwapUINT256(_initial.amount1(), 0),
            toTTSwapUINT256(_initial.amount0(), _initial.amount0()),
            toTTSwapUINT256(_initial.amount1(), _initial.amount1()),
            0
        );
        uint128 construct = L_Proof.stake(
            TTS_CONTRACT,
            msg.sender,
            _initial.amount0()
        );
        emit e_initMetaGood(
            proofid,
            _erc20address,
            construct,
            _goodConfig,
            _initial
        );
        return true;
    }

    /**
     * @dev Initializes a new normal good in the market.
     * @param _valuegood The ID of the value good (must be a value good).
     * @param _initial The initial balance configuration:
     *        - amount0: The quantity of the normal good to invest
     *        - amount1: The quantity of the value good to invest
     * @param _erc20address The address of the ERC20 token representing the new good.
     * @param _goodConfig The good configuration settings (fees, limits, etc.).
     * @param _normaldata The data for transferring the normal good (Permit/Transfer).
     * @param _valuedata The data for transferring the value good (Permit/Transfer).
     * @param _trader The address of the trader initiating the initialization (must be msg.sender).
     * @param signature The signature authorizing the initialization (if applicable).
     * @return bool Returns true if the initialization is successful.
     * @notice This function creates a new market pair between the normal good and the value good.
     * It requires:
     * - Both goods to be transferred from the creator.
     * - Initial liquidity to be added.
     * - A proof of investment to be created.
     * @custom:security Protected by reentrancy guard.
     * @custom:security Validates that `_valuegood` is a valid value good.
     * @custom:security Validates initial amounts and configurations.
     */
    function initGood(
        address _valuegood,
        uint256 _initial,
        address _erc20address,
        uint256 _goodConfig,
        bytes calldata _normaldata,
        bytes calldata _valuedata,
        address _trader,
        bytes calldata signature
    ) external payable override guardedEntry msgValue returns (bool) {
        _checkTrader(_trader);
        if (_initial.amount0() < 500000 || _initial.amount0() > 2 ** 109)
            revert TTSwapError(36);
        if (!goods[_valuegood].goodConfig.isvaluegood()) {
            revert TTSwapError(6);
        }
        if (goods[_erc20address].owner != address(0)) revert TTSwapError(5);
        _erc20address.transferFrom(
            msg.sender,
            msg.sender,
            _initial.amount0(),
            _normaldata
        );
        _valuegood.transferFrom(
            msg.sender,
            msg.sender,
            _initial.amount1(),
            _valuedata
        );
        L_Good.S_GoodInvestReturn memory investResult;
        // Retrieve the current investment state of the value good (Shares and Values)
        (investResult.goodShares, investResult.goodValues) = goods[_valuegood]
            .investState
            .amount01();
        // Retrieve the current trading state of the value good (Invest Quantity and Current Quantity)
        (
            investResult.goodInvestQuantity,
            investResult.goodCurrentQuantity
        ) = goods[_valuegood].currentState.amount01();

        // Calculate the investment details for the value good.
        // This step ensures the new normal good is paired with the correct amount/value of the value good
        // based on the current market state of the value good.
        goods[_valuegood].investGood(_initial.amount1(), investResult, 100);

        if (investResult.investValue < 100000000000000) revert TTSwapError(35);

        // Initialize the new normal good state.
        // amount0: Initial value (pegged to the value good's invested value).
        // amount1: Initial quantity of the normal good.
        goods[_erc20address].init(
            toTTSwapUINT256(investResult.investValue, _initial.amount0()),
            _goodConfig
        );

        // Generate a unique proof ID for this liquidity provision.
        // The proof key consists of the creator (msg.sender), the new good, and the value good.
        uint256 proofId = S_ProofKey(msg.sender, _erc20address, _valuegood)
            .toId();

        // Create the initial proof state.
        // - Shares: Initial shares issued for the new good and the value good investment.
        // - State: Tracks the total value of the investment.
        // - Invest: Tracks the virtual and actual quantities of the normal good.
        // - ValueInvest: Tracks the virtual and actual quantities of the value good.
        proofs[proofId] = S_ProofState(
            _erc20address,
            _valuegood,
            toTTSwapUINT256(_initial.amount0(), investResult.investShare),
            toTTSwapUINT256(investResult.investValue, investResult.investValue),
            toTTSwapUINT256(_initial.amount0(), _initial.amount0()),
            toTTSwapUINT256(
                investResult.investQuantity,
                investResult.investQuantity
            )
        );

        emit e_initGood(
            proofId,
            _erc20address,
            _valuegood,
            _goodConfig,
            L_Proof.stake(
                TTS_CONTRACT,
                msg.sender,
                investResult.investValue * 2
            ),
            toTTSwapUINT256(_initial.amount0(), investResult.investValue), // amount0: the quantity of the normal good,amount1: the value of the value good
            toTTSwapUINT256(
                investResult.investFeeQuantity, // amount0: the fee of the value good
                investResult.investQuantity // amount1: the quantity of the value good
            ),
            _trader
        );
        return true;
    }

    /**
     * @dev Executes a swap (buy) between two goods.
     * @param _goodid1 The address of the input good (selling).
     * @param _goodid2 The address of the output good (buying).
     * @param _swapQuantity The swap details:
     *        - amount0: The input quantity of _goodid1.
     *        - amount1: The minimum output quantity of _goodid2 (slippage protection).
     * @param _recipient The address to receive the bought goods (if different from trader).
     *                 Also used for referral tracking if different from trader.
     * @param data Additional data for the input token transfer (Permit/Transfer).
     * @param _trader The address of the trader initiating the swap (must match signer if signature used).
     * @param signature The EIP-712 signature authorizing the trade (if msg.sender != _trader).
     * @return good1change The state change of the input good:
     *         - amount0: Fee quantity deducted.
     *         - amount1: Actual input quantity swapped.
     * @return good2change The state change of the output good:
     *         - amount0: Fee quantity deducted.
     *         - amount1: Actual output quantity received.
     * @notice This function calculates the swap amount based on the AMM formula, deducts fees,
     * updates reserves, and transfers tokens.
     * @custom:security Protected by reentrancy guard.
     * @custom:security Verifies EIP-712 signature if the caller is a relayer.
     * @custom:security Checks slippage tolerance (`_swapQuantity.amount1()`).
     * @custom:security Validates that the pool has sufficient liquidity and is not frozen.
     */
    function buyGood(
        address _goodid1,
        address _goodid2,
        uint256 _swapQuantity,
        address _recipient,
        bytes calldata data,
        address _trader,
        bytes calldata signature
    )
        external
        payable
        override
        guardedEntry
        msgValue
        returns (uint256 good1change, uint256 good2change)
    {
        if (msg.sender != _trader)
            signature.verify(
                keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        DOMAIN_SEPARATOR(),
                        keccak256(
                            abi.encode(
                                keccak256(
                                    "buyGood(address _trader,address referal,address _goodid1,address _goodid2,uint256 _swapQuantity,uint256 nonce,bytes data)"
                                ),
                                _trader,
                                _recipient,
                                _goodid1,
                                _goodid2,
                                _swapQuantity,
                                nonces[_trader]++,
                                keccak256(data)
                            )
                        )
                    )
                ),
                _trader
            );
        if (_goodid1 == _goodid2) revert TTSwapError(9);
        _checkGoodActive(_goodid1, 10, 12);
        _checkGoodActive(_goodid2, 11, 13);
        if (_recipient != address(0) && _recipient != _trader) {
            TTS_CONTRACT.setReferral(_trader, _recipient);
        }
        // Step 1: map input quantity to transferred value (ΔV) on good1 side.
        good1change = goods[_goodid1].good1Swap(_swapQuantity.amount0(), true);
        // Step 2: map transferred value (ΔV) to output quantity on good2 side.
        good2change = goods[_goodid2].good2Swap(good1change.amount1(), true);

        if (good1change.amount1() < 1_00_000_000) revert TTSwapError(14);
        if (
            good2change.amount1() < _swapQuantity.amount1() &&
            _swapQuantity.amount1() > 0
        ) revert TTSwapError(15);
        _goodid1.transferFrom(
            _trader,
            msg.sender,
            _swapQuantity.amount0(),
            data
        );

        // Transfer output tokens from market to recipient.
        if (msg.sender == _trader) {
            _goodid2.safeTransfer(_trader, good2change.amount1());
        } else {
            // Fee is denominated in output good units to keep payout consistent.
            uint128 feeQuantity = goods[_goodid2]
                .getGoodState()
                .getamount1fromamount0(executeFee);
            if (feeQuantity > good2change.amount1()) revert TTSwapError(46);
            goods[_goodid2].commission[msg.sender] += feeQuantity;
            _goodid2.safeTransfer(
                _recipient,
                (good2change.amount1() - feeQuantity)
            );
        }

        emit e_buyGood(
            _goodid1,
            _goodid2,
            good1change.amount1(),
            toTTSwapUINT256(
                good1change.amount0(),
                _swapQuantity.amount0() - good1change.amount0()
            ),
            toTTSwapUINT256(
                good2change.amount0(),
                good2change.amount1() + good2change.amount0()
            ),
            _trader
        );
    }

    /**
     * @dev Executes a payment or swap using specific output quantity (Pay).
     * @param _goodid1 The address of the input good (paying with).
     * @param _goodid2 The address of the output good (paying to).
     * @param _swapQuantity The swap details:
     *        - amount0: The maximum input quantity of _goodid1 (slippage protection).
     *        - amount1: The exact output quantity of _goodid2 required.
     * @param _recipient The address to receive the payment (goods).
     * @param data Additional data for the input token transfer (Permit/Transfer).
     * @param _trader The address of the trader initiating the payment (must match signer).
     * @param signature The EIP-712 signature authorizing the payment (if msg.sender != _trader).
     * @param data_hash A hash of the `data` parameter, intended to bind the transfer data to the signature.
     * @return good1change The state change of the input good:
     *         - amount0: Fee quantity deducted.
     *         - amount1: Actual input quantity used.
     * @return good2change The state change of the output good:
     *         - amount0: Fee quantity deducted.
     *         - amount1: Actual output quantity paid.
     * @notice This function calculates the input amount needed to get a specific output amount (inverse swap).
     * If `_goodid1` == `_goodid2`, it performs a direct transfer with fee deduction.
     * @custom:security Protected by reentrancy guard.
     * @custom:security Verifies EIP-712 signature if the caller is a relayer.
     * @custom:security Checks max input limit (`_swapQuantity.amount0()`).
     * @custom:security CRITICAL: `data_hash` is signed but NOT verified against `data` in current implementation.
     */
    function payGood(
        address _goodid1,
        address _goodid2,
        uint256 _swapQuantity,
        address _recipient,
        bytes calldata data,
        address _trader,
        bytes calldata signature,
        uint256 data_hash
    )
        external
        payable
        override
        guardedEntry
        msgValue
        returns (uint256 good1change, uint256 good2change)
    {
        uint128 feeQuantity;
        _checkGoodActive(_goodid1, 10, 12);
        _checkGoodActive(_goodid2, 11, 13);
        if (_recipient == address(0)) revert TTSwapError(32);
        if (msg.sender != _trader)
            signature.verify(
                keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        DOMAIN_SEPARATOR(),
                        keccak256(
                            abi.encode(
                                keccak256(
                                    "payGood(address _trader,address recipent,address _goodid1,address _goodid2,uint256 _swapQuantity,uint256 data_hash,bytes data,uint256 nonce)"
                                ),
                                _trader,
                                _recipient,
                                _goodid1,
                                _goodid2,
                                _swapQuantity,
                                data_hash,
                                keccak256(data),
                                nonces[_trader]++
                            )
                        )
                    )
                ),
                _trader
            );
        if (_goodid1 != _goodid2) {
            // exact-out flow: desired output quantity -> required input value -> required input quantity
            good2change = goods[_goodid2].good2Swap(
                _swapQuantity.amount1(),
                false
            );

            good1change = goods[_goodid1].good1Swap(
                good2change.amount1(),
                false
            );
            if (
                good1change.amount1() + good1change.amount0() >
                _swapQuantity.amount0() &&
                _swapQuantity.amount0() > 0
            ) revert TTSwapError(15);
            _goodid1.transferFrom(
                _trader,
                msg.sender,
                good1change.amount1() + good1change.amount0(),
                data
            );
            // Transfer output tokens.
            if (msg.sender == _trader) {
                _goodid2.safeTransfer(_recipient, _swapQuantity.amount1());
            } else {
                // Commission logic for relayer.

                feeQuantity = goods[_goodid2]
                    .getGoodState()
                    .getamount1fromamount0(executeFee);
                if (feeQuantity > good2change.amount1()) revert TTSwapError(46);
                goods[_goodid2].commission[msg.sender] += feeQuantity;
                _goodid2.safeTransfer(
                    _recipient,
                    _swapQuantity.amount1() - feeQuantity
                );
            }
            emit e_payGood(
                _goodid1,
                _goodid2,
                good2change.amount1(),
                toTTSwapUINT256(good1change.amount0(), good1change.amount1()),
                toTTSwapUINT256(
                    good2change.amount0(),
                    _swapQuantity.amount1() - good2change.amount0()
                ),
                _trader,
                _recipient,
                data_hash
            );
        } else {
            // Direct payment path (good1 == good2).
            // No AMM swap, just fee deduction and transfer.
            _goodid1.transferFrom(
                _trader,
                msg.sender,
                _swapQuantity.amount0(),
                data
            );
            good1change = toTTSwapUINT256(
                goods[_goodid1].currentState.amount1(),
                goods[_goodid1].investState.amount1()
            );
            if (msg.sender == _trader) {
                _goodid1.safeTransfer(_recipient, _swapQuantity.amount0());
            } else {
                // Relayer commission calculation.

                feeQuantity = good1change.getamount0fromamount1(executeFee);
                if (feeQuantity > _swapQuantity.amount0())
                    revert TTSwapError(46);
                good2change = _swapQuantity.amount0() - feeQuantity;
                goods[_goodid1].commission[msg.sender] += feeQuantity;
                _goodid1.safeTransfer(_recipient, good2change);
                good2change = (good2change << 128) + feeQuantity;
            }
            emit e_payGood(
                _goodid1,
                address(0),
                good1change.getamount1fromamount0(_swapQuantity.amount0()),
                _swapQuantity,
                good2change,
                _trader,
                _recipient,
                data_hash
            );
        }
    }

    /**
     * @dev Invests liquidity into a good pool, minting shares and proof tokens.
     * @param _togood The address of the normal good to invest in.
     * @param _valuegood The address of the paired value good (can be address(0) for single-sided, but checks apply).
     * @param _quantity The amount of `_togood` to invest.
     * @param data1 Transfer data for `_togood`.
     * @param data2 Transfer data for `_valuegood`.
     * @param _trader The address of the investor (must match msg.sender).
     * @param signature Unused in current logic but present for interface consistency (potential future EIP-712 support).
     * @return bool Returns true if investment is successful.
     * @notice Investment requires providing both the normal good and the paired value good (if applicable)
     * in a ratio determined by the current pool reserves.
     * - Mints shares representing ownership of the pool.
     * - Updates the investment proof (S_ProofState).
     * - Stakes a portion of the value to the TTS contract (minting TTS rewards).
     * @custom:security Protected by reentrancy guard.
     * @custom:security Enforces `_trader == msg.sender`.
     * @custom:security Validates goods are initialized and not frozen.
     * @custom:security Calculates required `_valuegood` amount based on current price.
     */
    function investGood(
        address _togood,
        address _valuegood,
        uint128 _quantity,
        bytes calldata data1,
        bytes calldata data2,
        address _trader,
        bytes calldata signature
    ) external payable override guardedEntry msgValue returns (bool) {
        _checkTrader(_trader);
        L_Good.S_GoodInvestReturn memory normalInvest_;
        L_Good.S_GoodInvestReturn memory valueInvest_;
        if (_togood == _valuegood) revert TTSwapError(9);
        _checkGoodActive(_togood, 10, 12);
        if (
            !(goods[_togood].goodConfig.isvaluegood() ||
                goods[_valuegood].goodConfig.isvaluegood())
        ) revert TTSwapError(17);
        if (goods[_togood].currentState.amount1() + _quantity > 2 ** 109)
            revert TTSwapError(18);

        // Calculate the power/leverage factor.
        // The power determines how much "virtual" liquidity is minted relative to the actual deposit.
        // It is capped by the lower power factor of the two goods in the pair.
        uint128 enpower = goods[_togood].getInvestPower();
        if (_valuegood != address(0)) {
            enpower = enpower < goods[_valuegood].getInvestPower()
                ? enpower
                : goods[_valuegood].getInvestPower();
        }

        // Transfer normal good tokens from investor to market.
        _togood.transferFrom(msg.sender, msg.sender, _quantity, data1);

        // Retrieve current investment state of the normal good.
        (normalInvest_.goodShares, normalInvest_.goodValues) = goods[_togood]
            .investState
            .amount01();
        (
            normalInvest_.goodInvestQuantity,
            normalInvest_.goodCurrentQuantity
        ) = goods[_togood].currentState.amount01();

        // Process investment for normal good.
        // Calculates new shares and updates normal good's state.
        goods[_togood].investGood(_quantity, normalInvest_, enpower);

        if (normalInvest_.investValue < 1000000) revert TTSwapError(38);

        if (_valuegood != address(0)) {
            _checkGoodActive(_valuegood, 11, 13);
            S_GoodState storage vGood = goods[_valuegood];
            (valueInvest_.goodShares, valueInvest_.goodValues) = vGood.investState.amount01();
            (
                valueInvest_.goodInvestQuantity,
                valueInvest_.goodCurrentQuantity
            ) = vGood.currentState.amount01();

            // Calculate required value good quantity based on the value of the normal good investment.
            // Ensures the investment maintains the current price ratio between the two goods.
            valueInvest_.investQuantity = toTTSwapUINT256(
                valueInvest_.goodCurrentQuantity,
                valueInvest_.goodValues
            ).getamount0fromamount1(normalInvest_.investValue);

            // Cache goodConfig once: getInvestFullFee + investGood both read it internally
            valueInvest_.investQuantity = vGood.goodConfig.getInvestFullFee(
                valueInvest_.investQuantity
            );

            // Process investment for value good.
            vGood.investGood(
                valueInvest_.investQuantity,
                valueInvest_,
                enpower
            );

            // Transfer value good tokens from investor to market.
            _valuegood.transferFrom(
                msg.sender,
                msg.sender,
                (valueInvest_.investQuantity * 100) /
                    enpower +
                    valueInvest_.investFeeQuantity,
                data2
            );
        }

        // Generate/Get proof ID.
        uint256 proofNo = S_ProofKey(msg.sender, _togood, _valuegood).toId();
        uint128 investvalue = normalInvest_.investValue;

        // Convert virtual value to actual value basis (scale down by leverage).
        investvalue = ((normalInvest_.investValue * 100) / enpower);

        // Update the investment proof with the new shares and amounts.
        proofs[proofNo].updateInvest(
            _togood,
            _valuegood,
            toTTSwapUINT256(
                normalInvest_.investShare,
                valueInvest_.investShare
            ),
            toTTSwapUINT256(normalInvest_.investValue, investvalue),
            toTTSwapUINT256(
                normalInvest_.investQuantity,
                (normalInvest_.investQuantity * 100) / enpower //real quantity
            ),
            toTTSwapUINT256(
                valueInvest_.investQuantity,
                (valueInvest_.investQuantity * 100) / enpower
            )
        );
        emit e_investGood(
            proofNo,
            _togood,
            _valuegood,
            toTTSwapUINT256(normalInvest_.investValue, investvalue),
            toTTSwapUINT256(
                normalInvest_.investFeeQuantity,
                normalInvest_.investQuantity
            ),
            toTTSwapUINT256(
                valueInvest_.investFeeQuantity,
                valueInvest_.investQuantity
            ),
            _trader
        );
        investvalue = _valuegood == address(0) ? investvalue : investvalue * 2;

        // Stake the investment value to the TTS contract to earn rewards.
        L_Proof.stake(TTS_CONTRACT, msg.sender, investvalue);
        return true;
    }

    /**
     * @dev Disinvests from a proof by withdrawing invested tokens and collecting profits
     * @param _proofid The ID of the proof to disinvest from
     * @param _goodQuantity The amount of normal good tokens to disinvest
     * @param _gate The address to receive gate rewards (falls back to DAO admin if banned)
     * @return uint128 The profit amount from normal good disinvestment
     * @return uint128 The profit amount from value good disinvestment (if applicable)
     * @notice This function:
     * - Validates proof ownership and state
     * - Processes disinvestment for both normal and value goods
     * - Handles commission distribution and fee collection
     * - Updates proof state and burns tokens
     * - Distributes rewards to gate and referrer
     * - Unstakes TTS tokens
     * @custom:security Protected by noReentrant modifier
     * @custom:security Reverts if:
     * - Proof ID does not match sender's proof
     * - Invalid proof state
     * - Insufficient balance for disinvestment
     */
    /// @inheritdoc I_TTSwap_Market
    function disinvestProof(
        uint256 _proofid,
        uint128 _goodshares,
        address _gate,
        address _trader,
        bytes calldata signature
    ) external override guardedEntry returns (uint128, uint128) {
        _checkTrader(_trader);
        if (
            S_ProofKey(
                _trader,
                proofs[_proofid].currentgood,
                proofs[_proofid].valuegood
            ).toId() != _proofid
        ) {
            revert TTSwapError(19);
        }

        L_Good.S_GoodDisinvestReturn memory disinvestNormalResult1_;
        L_Good.S_GoodDisinvestReturn memory disinvestValueResult2_;
        address normalgood = proofs[_proofid].currentgood;
        if (goods[normalgood].goodConfig.isFreeze()) revert TTSwapError(10);
        if (
            goods[normalgood].goodConfig.getApply() &&
            goods[normalgood].owner == _trader
        ) {
            revert TTSwapError(40);
        }
        address valuegood = proofs[_proofid].valuegood;
        uint256 divestvalue;
        address referal = TTS_CONTRACT.getreferral(msg.sender);
        _gate = TTS_CONTRACT.userConfig(_gate).isBan() ? address(0) : _gate;
        referal = _gate == referal ? address(0) : referal;
        referal = TTS_CONTRACT.userConfig(referal).isBan()
            ? address(0)
            : referal;
        // Normalize payout routes:
        // - banned gate/referral are nulled
        // - gate == referral collapses referral to avoid double-counting

        // Disinvest uses proof-time shares to compute virtual/actual quantities,
        // then realizes profit/loss against current pool state and applies fee splits.
        // Calculate disinvestment details using the shared library.
        // This computes:
        // - The amount of normal/value goods to return to the user.
        // - The realized profit/loss.
        // - Any applicable fees (gate, referral, platform).
        // - Updates the state of both goods.
        (disinvestNormalResult1_, disinvestValueResult2_, divestvalue) = goods[
            normalgood
        ].disinvestGood(
                goods[valuegood],
                proofs[_proofid],
                L_Good.S_GoodDisinvestParam(
                    _goodshares,
                    _gate,
                    referal,
                    msg.sender
                )
            );

        // Transfer accumulated commission/profit for normal good to the user.
        uint256 tranferamount = goods[normalgood].commission[msg.sender];

        if (tranferamount > 1) {
            goods[normalgood].commission[msg.sender] = 1;
            normalgood.safeTransfer(msg.sender, tranferamount - 1);
        }
        // Commission balances are kept with a 1-unit sentinel to avoid cold SSTORE.

        // Transfer accumulated commission/profit for value good to the user (if exists).
        if (valuegood != address(0)) {
            if (goods[valuegood].goodConfig.isFreeze()) revert TTSwapError(10);
            tranferamount = goods[valuegood].commission[msg.sender];
            if (tranferamount > 1) {
                goods[valuegood].commission[msg.sender] = 1;
                valuegood.safeTransfer(msg.sender, tranferamount - 1);
            }
        }

        // Unstake the corresponding amount of value from the TTS contract.
        // This reduces the user's staking rewards going forward.
        L_Proof.unstake(TTS_CONTRACT, msg.sender, divestvalue.amount0());

        emit e_disinvestProof(
            _proofid,
            normalgood,
            valuegood,
            _gate,
            divestvalue,
            toTTSwapUINT256(
                disinvestNormalResult1_.profit,
                disinvestNormalResult1_.virtualDisinvestQuantity
            ),
            toTTSwapUINT256(
                disinvestNormalResult1_.actual_fee,
                disinvestNormalResult1_.actualDisinvestQuantity
            ),
            toTTSwapUINT256(
                disinvestValueResult2_.profit,
                disinvestValueResult2_.virtualDisinvestQuantity
            ),
            toTTSwapUINT256(
                disinvestValueResult2_.actual_fee,
                disinvestValueResult2_.actualDisinvestQuantity
            ),
            _trader
        );
        return (disinvestNormalResult1_.profit, disinvestValueResult2_.profit);
    }

    function refreshPromise(uint256 _proofid) external override {
        // Cache proof storage pointer + fields: avoids 4+ repeated SLOAD on proofs[_proofid]
        S_ProofState storage proof = proofs[_proofid];
        address currentgood = proof.currentgood;
        address valuegood = proof.valuegood;
        if (S_ProofKey(msg.sender, currentgood, valuegood).toId() != _proofid) {
            revert TTSwapError(19);
        }
        S_GoodState storage g = goods[currentgood];
        if (g.goodConfig.getApply() && g.owner == msg.sender) {
            // Emits a claimable-proof signal for applied goods (creator-owned).
            emit e_getPromiseProof(currentgood, _proofid);
        }
    }

    /**
     * @dev Compares the current trading states of two goods to determine if the first good is in a higher iteration
     * @param good1 The address of the first good to compare
     * @param good2 The address of the second good to compare
     * @param compareprice the price of use good2 for good1
     * @return bool Returns true if good1's current state is higher than good2's, false otherwise
     * @notice This function:
     * - Compares the current trading iterations (states) of two goods
     * - Used to determine the trading order and eligibility for operations
     * - Essential for maintaining trading synchronization between goods
     * - Returns false if either good is not registered (state = 0)
     * @custom:security This is a view function with no state modifications
     * @custom:security Returns false for unregistered goods to prevent invalid operations
     */
    /// @inheritdoc I_TTSwap_Market
    function ishigher(
        address goodid,
        address valuegood,
        uint256 compareprice
    ) external view override returns (bool) {
        return
            lowerprice(
                toTTSwapUINT256(
                    goods[goodid].investState.amount1(),
                    goods[goodid].currentState.amount1()
                ),
                toTTSwapUINT256(
                    goods[valuegood].investState.amount1(),
                    goods[valuegood].currentState.amount1()
                ),
                compareprice
            );
    }

    /**
     * @dev Retrieves the current state of two goods in a single call
     * @param good1 The address of the first good to query
     * @param good2 The address of the second good to query
     * @return good1correntstate The current state of the first good, representing its latest trading iteration
     * @return good2correntstate The current state of the second good, representing its latest trading iteration
     * @notice This function is a view function that:
     * - Returns the current trading iteration (state) for both goods
     * - Useful for checking the latest trading status of a pair of goods
     * - Can be used to verify if goods are in sync for trading operations
     * @custom:security This is a view function with no state modifications
     * @custom:security Returns 0 if either good address is not registered
     */
    /// @inheritdoc I_TTSwap_Market
    function getRecentGoodState(
        address good1,
        address good2
    )
        external
        view
        override
        returns (uint256 good1currentstate, uint256 good2currentstate)
    {
        // return (goods[good1].currentState, goods[good2].currentState);
        return (goods[good1].getGoodState(), goods[good2].getGoodState());
    }

    /// @notice Retrieves the current state of a proof
    /// @param proofid The ID of the proof to query
    /// @return proofstate The current state of the proof,
    ///  currentgood The current good associated with the proof
    ///  valuegood The value good associated with the proof
    ///  shares normal good shares, value good shares
    ///  state Total value, Total actual value
    ///  invest normal good virtual quantity, normal good actual quantity
    ///  valueinvest value good virtual quantity, value good actual quantity
    /// @inheritdoc I_TTSwap_Market
    function getProofState(
        uint256 proofid
    ) external view override returns (S_ProofState memory) {
        return proofs[proofid];
    }

    /// @notice Retrieves the current state of a good
    /// @param good The address of the good to query
    /// @return goodstate The current state of the good,
    ///  goodConfig Configuration of the good, check goodconfig.sol or whitepaper for details
    ///  owner Creator of the good
    ///  currentState Present investQuantity, CurrentQuantity
    ///  investState Shares, value
    /// @inheritdoc I_TTSwap_Market
    function getGoodState(
        address good
    ) external view override returns (S_GoodTmpState memory) {
        return
            S_GoodTmpState(
                goods[good].goodConfig,
                goods[good].owner,
                goods[good].currentState,
                goods[good].investState
            );
    }

    /// @notice Updates a good's configuration
    /// @param _goodid The ID of the good
    /// @param _goodConfig The new configuration
    /// @return Success status
    /// @inheritdoc I_TTSwap_Market
    function updateGoodConfig(
        address _goodid,
        uint256 _goodConfig,
        address _trader,
        bytes calldata signature
    ) external override returns (bool) {
        _checkTrader(_trader);
        if (msg.sender != goods[_goodid].owner) revert TTSwapError(20);
        goods[_goodid].updateGoodConfig(_goodConfig);
        emit e_updateGoodConfig(_goodid, goods[_goodid].goodConfig, _trader);
        return true;
    }

    /// @param _goodid The ID of the good
    /// @param _goodConfig The new configuration
    /// @return Success status
    /// @inheritdoc I_TTSwap_Market
    function modifyGoodConfig(
        address _goodid,
        uint256 _goodConfig,
        address _trader,
        bytes calldata signature
    ) external override onlyMarketor returns (bool) {
        _checkTrader(_trader);
        if (!_goodConfig.checkGoodConfig()) revert TTSwapError(24);
        goods[_goodid].modifyGoodConfig(_goodConfig);
        emit e_modifyGoodConfig(_goodid, goods[_goodid].goodConfig, _trader);
        return true;
    }

    /// @param _goodid The ID of the good
    /// @param _goodConfig The new configuration
    /// @return Success status
    /// @inheritdoc I_TTSwap_Market
    function modifyGoodCoreConfig(
        address _goodid,
        uint256 _goodConfig,
        address _trader,
        bytes calldata signature
    ) external override onlyMarketadmin returns (bool) {
        _checkTrader(_trader);
        goods[_goodid].modifyGoodCoreConfig(_goodConfig);
        emit e_modifyGoodConfig(_goodid, goods[_goodid].goodConfig, _trader);
        return true;
    }

    function lockGood(
        address _goodid,
        address _trader,
        bytes calldata signature
    ) external override {
        _checkTrader(_trader);
        if (
            !TTS_CONTRACT.userConfig(msg.sender).isMarketManager() &&
            goods[_goodid].owner != msg.sender
        ) revert TTSwapError(20);
        goods[_goodid].lockGood();
        emit e_updateGoodConfig(_goodid, goods[_goodid].goodConfig, _trader);
    }

    /// @notice Changes the owner of a good
    /// @param _goodid The ID of the good
    /// @param _to The new owner's address
    /// @inheritdoc I_TTSwap_Market
    function changeGoodOwner(
        address _goodid,
        address _to,
        address _trader,
        bytes calldata signature
    ) external override onlyMarketor {
        _checkTrader(_trader);
        goods[_goodid].owner = _to;
        emit e_changegoodowner(_goodid, _to, _trader);
    }

    /// @notice Collects commission for specified goods
    /// @param _goodid Array of good IDs
    /// @inheritdoc I_TTSwap_Market
    function collectCommission(
        address[] calldata _goodid,
        address _trader,
        bytes calldata signature
    ) external override guardedEntry {
        _checkTrader(_trader);
        address recipent = TTS_CONTRACT.userConfig(msg.sender).isMarketAdmin()
            ? address(0)
            : msg.sender;
        uint256 len = _goodid.length;
        if (len > 100) revert TTSwapError(21);
        uint256[] memory commissionamount = new uint256[](len);
        for (uint256 i = 0; i < len; ) {
            commissionamount[i] = goods[_goodid[i]].commission[recipent];
            if (commissionamount[i] > 1) {
                commissionamount[i] = commissionamount[i] - 1;
                goods[_goodid[i]].commission[recipent] = 1;
                _goodid[i].safeTransfer(msg.sender, commissionamount[i]);
            }
            unchecked { ++i; }
        }
        emit e_collectcommission(_goodid, commissionamount, _trader);
    }

    /**
     * @dev Queries commission amounts for multiple goods for a specific recipient
     * @param _goodid Array of good addresses to query commission for
     * @param _recipient The address to check commission amounts for
     * @return feeamount Array of commission amounts corresponding to each good
     * @notice This function:
     * - Returns commission amounts for up to 100 goods in a single call
     * - Each amount represents the commission available for the recipient
     * - Returns 0 for goods where no commission is available
     * - Maintains gas efficiency by using a fixed array size
     * @custom:security Reverts if more than 100 goods are queried
     * @custom:security View function, does not modify state
     */
    /// @inheritdoc I_TTSwap_Market
    function queryCommission(
        address[] calldata _goodid,
        address _recipient
    ) external view override returns (uint256[] memory) {
        uint256 len = _goodid.length;
        if (len > 100) revert TTSwapError(21);
        uint256[] memory feeamount = new uint256[](len);
        for (uint256 i = 0; i < len; ) {
            feeamount[i] = goods[_goodid[i]].commission[_recipient];
            unchecked { ++i; }
        }
        return feeamount;
    }

    /**
     * @dev Adds welfare funds to a good's fee pool
     * @param goodid The address of the good to receive welfare
     * @param welfare The amount of tokens to add as welfare
     * @param data Additional data for token transfer
     * @notice This function:
     * - Allows anyone to contribute additional funds to a good's fee pool
     * - Increases the good's feeQuantityState by the welfare amount
     * - Transfers tokens from the sender to the good
     * - Emits an event with the welfare contribution details
     * @custom:security Protected by noReentrant modifier
     * @custom:security Checks for overflow in feeQuantityState
     */
    /// @inheritdoc I_TTSwap_Market
    function goodWelfare(
        address goodid,
        uint128 welfare,
        bytes calldata data,
        address _trader,
        bytes calldata signature
    ) external payable override guardedEntry msgValue {
        _checkTrader(_trader);
        if (goods[goodid].currentState.amount0() + welfare > 2 ** 109) {
            revert TTSwapError(18);
        }
        // Welfare is a direct pool top-up:
        // - increases both investQuantity and currentQuantity equally (fee-like injection)
        // - raises LP net value without minting new shares
        goodid.transferFrom(msg.sender, msg.sender, welfare, data);
        goods[goodid].currentState = add(
            goods[goodid].currentState,
            toTTSwapUINT256(uint128(welfare), uint128(welfare))
        );
        emit e_goodWelfare(goodid, welfare, _trader);
    }

    function DOMAIN_SEPARATOR() public view virtual returns (bytes32) {
        return
            block.chainid == INITIAL_CHAIN_ID
                ? INITIAL_DOMAIN_SEPARATOR
                : computeDomainSeparator();
    }

    function computeDomainSeparator() internal view virtual returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256(
                        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                    ),
                    keccak256(bytes("TTSwap_Market")),
                    keccak256("1"),
                    block.chainid,
                    address(this)
                )
            );
    }
}
