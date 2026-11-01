// SPDX-License-Identifier: BUSL-1.1
/*
 *        ▄▄▄▄▄▄▄▄▄▄
 *     ▄▄████████████▄▄
 *    ▄████████████████▄
 *   ████████████████████
 *  ████████▀    ▀████████
 *  ███████        ███████
 *  ███████        ███████
 *  ███████        ███████
 *  ███████        ███████
 *  ███████  ▄██▄  ███████
 *  ███████ ██████ ███████
 *  ███████  ▀██▀  ███████
 *
 *  Kolan
 *
 *  Website   https://kolan.c0llback.com
 *  Twitter   https://x.com/kolan_protocol
 */
pragma solidity 0.8.26;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

import {KolanToken} from "./KolanToken.sol";
import {LiquidityBook} from "./LiquidityBook.sol";

contract KolanHook is IHooks, IUnlockCallback, LiquidityBook, ReentrancyGuardTransient {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeCast for int256;
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    struct Config {
        IPoolManager manager;
        address launcher;
        address dev;
        string name;
        string symbol;
        uint256 supply;
        uint256 taxBps;
        uint256 referencePremium;
        uint256 baseWindow;
        uint256 minWindow;
        uint256 maxWindow;
        uint256 maxPremiumBps;
    }

    struct Window {
        address owner;
        uint40 expiry;
        uint8 cuts;
        uint96 eth;
        uint96 tokens;
        uint64 premium;
    }

    struct Held {
        uint128 eth;
        uint128 tokens;
    }

    enum Action {
        Launch,
        Redeem,
        Open,
        Close
    }

    uint160 public constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    uint256 public constant MAX_TAX_BPS = 500;
    uint256 public constant ROUNDING_ALLOWANCE = 1_000;
    uint256 internal constant BPS = 10_000;
    Currency internal constant ETH = CurrencyLibrary.ADDRESS_ZERO;

    KolanToken public immutable TOKEN;
    Currency internal immutable TOKEN_CURRENCY;
    PoolId internal immutable POOL_ID;
    address public immutable LAUNCHER;
    address public immutable DEV;
    uint256 public immutable TAX_BPS;
    uint256 public immutable REFERENCE_PREMIUM;
    uint256 public immutable BASE_WINDOW;
    uint256 public immutable MIN_WINDOW;
    uint256 public immutable MAX_WINDOW;
    uint256 public immutable MAX_PREMIUM_BPS;

    bool public launched;
    int24 public openTick;
    uint256 public devOwed;

    uint256 public windowCount;
    Held public held;
    mapping(uint256 id => Window) public windows;
    mapping(uint256 id => mapping(uint256 => Cut)) internal _cuts;

    event Launched(PoolId indexed id, int24 tick, uint128 liquidity, uint256 tokens);
    event Taxed(address indexed payer, uint256 fee);
    event DevPaid(address indexed dev, uint256 amount);
    event WindowOpened(
        uint256 indexed id,
        address indexed owner,
        uint256 eth,
        uint256 tokens,
        uint256 premium,
        uint256 expiry,
        int24 lower,
        int24 upper
    );
    event WindowClosed(
        uint256 indexed id, address indexed owner, bool kept, bool backInPlace, uint256 burned
    );

    error NotPoolManager();
    error NotLauncher();
    error AlreadyLaunched();
    error NotLaunched();
    error BadHookAddress();
    error BadConfig();
    error BadTick();
    error LiquidityIsLocked();
    error OnlyTheHookOpensThePool();
    error NotSupported();
    error NothingOwed();
    error PayoutFailed();
    error TransferFailed();
    error TooLate();
    error BadRecipient();
    error NotEnoughEth();
    error NothingToBuy();
    error TooFewTokens();
    error PremiumTooLow();
    error PremiumTooHigh();
    error NoWindow();
    error NotOwner();
    error WindowExpired();
    error WindowStillOpen();
    error Insolvent();

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        _;
    }

    constructor(Config memory c) LiquidityBook(c.manager) {
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != FLAGS) revert BadHookAddress();
        if (address(c.manager) == address(0) || c.launcher == address(0) || c.dev == address(0)) {
            revert BadConfig();
        }
        if (c.supply == 0 || c.taxBps > MAX_TAX_BPS) revert BadConfig();
        if (c.referencePremium == 0 || c.baseWindow == 0 || c.minWindow == 0) revert BadConfig();
        if (c.minWindow > c.maxWindow || c.maxWindow > type(uint32).max) revert BadConfig();
        if (c.maxPremiumBps == 0 || c.maxPremiumBps > BPS) revert BadConfig();
        if (c.supply > type(uint96).max) revert BadConfig();
        if (c.maxWindow * c.referencePremium / c.baseWindow >= type(uint64).max) revert BadConfig();

        LAUNCHER = c.launcher;
        DEV = c.dev;
        TAX_BPS = c.taxBps;
        REFERENCE_PREMIUM = c.referencePremium;
        BASE_WINDOW = c.baseWindow;
        MIN_WINDOW = c.minWindow;
        MAX_WINDOW = c.maxWindow;
        MAX_PREMIUM_BPS = c.maxPremiumBps;

        KolanToken token = new KolanToken(c.name, c.symbol, c.supply);
        TOKEN = token;
        TOKEN_CURRENCY = Currency.wrap(address(token));
        POOL_ID = PoolKey({
                currency0: ETH,
                currency1: Currency.wrap(address(token)),
                fee: 0,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(address(this))
            }).toId();
    }

    receive() external payable {}

    function poolKey() public view override returns (PoolKey memory) {
        return PoolKey({
            currency0: ETH,
            currency1: TOKEN_CURRENCY,
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }

    function poolId() external view returns (PoolId) {
        return POOL_ID;
    }

    function _poolId() internal view override returns (PoolId) {
        return POOL_ID;
    }

    function launch(int24 tick) external payable nonReentrant {
        if (msg.sender != LAUNCHER) revert NotLauncher();
        if (launched) revert AlreadyLaunched();
        if (tick <= LOWEST_TICK || tick > HIGHEST_TICK || tick % TICK_SPACING != 0) revert BadTick();
        launched = true;
        openTick = tick;

        POOL_MANAGER.initialize(poolKey(), TickMath.getSqrtPriceAtTick(tick) - 1);
        uint256 paid = abi.decode(POOL_MANAGER.unlock(abi.encode(Action.Launch, abi.encode(tick))), (uint256));

        uint256 dust = TOKEN.balanceOf(address(this));
        if (dust != 0) TOKEN.burn(dust);
        if (msg.value > paid) _send(msg.sender, msg.value - paid);
    }

    function quote(uint256 eth) external view returns (uint256 tokens, uint256 cost) {
        (,, cost, tokens) = _plan(eth);
    }

    function windowFor(uint256 premium) public view returns (uint256) {
        return premium * BASE_WINDOW / REFERENCE_PREMIUM;
    }

    function cutsOf(uint256 id) public view returns (Cut[] memory cuts) {
        cuts = new Cut[](windows[id].cuts);
        for (uint256 i = 0; i < cuts.length; ++i) {
            cuts[i] = _cuts[id][i];
        }
    }

    function buy(address recipient, uint256 premium, uint256 minTokens, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 id, uint256 tokens)
    {
        if (!launched) revert NotLaunched();
        if (block.timestamp > deadline) revert TooLate();
        if (recipient == address(0)) revert BadRecipient();
        if (msg.value <= premium + ROUNDING_ALLOWANCE) revert NotEnoughEth();

        uint256 budget = FullMath.mulDiv(msg.value - premium - ROUNDING_ALLOWANCE, BPS, BPS + TAX_BPS);
        id = ++windowCount;
        (uint256 cost, uint256 paid, uint256 kept, uint256 got) = abi.decode(
            POOL_MANAGER.unlock(abi.encode(Action.Open, abi.encode(id, recipient, budget, premium))),
            (uint256, uint256, uint256, uint256)
        );
        if (got < minTokens) revert TooFewTokens();
        tokens = got;

        uint256 refund = msg.value - cost - paid - kept;
        if (refund != 0) _send(msg.sender, refund);
        _checkSolvent();
    }

    function cancel(uint256 id) external nonReentrant {
        Window memory w = windows[id];
        if (w.owner == address(0)) revert NoWindow();
        if (msg.sender != w.owner) revert NotOwner();
        if (block.timestamp >= w.expiry) revert WindowExpired();

        _close(id, w, false);
        _send(w.owner, w.eth);
        _checkSolvent();
    }

    function accept(uint256 id) external nonReentrant {
        Window memory w = windows[id];
        if (w.owner == address(0)) revert NoWindow();
        if (msg.sender != w.owner && block.timestamp < w.expiry) revert WindowStillOpen();

        _close(id, w, true);
        if (!TOKEN.transfer(w.owner, w.tokens)) revert TransferFailed();
        _checkSolvent();
    }

    function claimDev() external nonReentrant returns (uint256 amount) {
        amount = devOwed;
        if (amount == 0) revert NothingOwed();
        devOwed = 0;
        POOL_MANAGER.unlock(abi.encode(Action.Redeem, abi.encode(amount)));
        _send(DEV, amount);
        emit DevPaid(DEV, amount);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Action action, bytes memory args) = abi.decode(data, (Action, bytes));
        if (action == Action.Open) {
            (uint256 id, address owner, uint256 budget, uint256 premium) =
                abi.decode(args, (uint256, address, uint256, uint256));
            return _openWindow(id, owner, budget, premium);
        }
        if (action == Action.Close) {
            (uint256 id, bool keep) = abi.decode(args, (uint256, bool));
            (uint256 burned, bool backInPlace) = _closeWindow(id, keep);
            return abi.encode(burned, backInPlace);
        }
        if (action == Action.Launch) return abi.encode(_seed(abi.decode(args, (int24))));
        _redeem(abi.decode(args, (uint256)));
        return "";
    }

    function _close(uint256 id, Window memory w, bool keep) private {
        (uint256 burned, bool backInPlace) =
            abi.decode(POOL_MANAGER.unlock(abi.encode(Action.Close, abi.encode(id, keep))), (uint256, bool));
        if (burned != 0) TOKEN.burn(burned);
        emit WindowClosed(id, w.owner, keep, backInPlace, burned);
    }

    function _openWindow(uint256 id, address owner, uint256 budget, uint256 premium)
        private
        returns (bytes memory)
    {
        (Take[] memory takes, uint256 count, uint256 cost,) = _plan(budget);
        if (count == 0 || cost == 0) revert NothingToBuy();
        (uint256 kept, uint256 duration) = _premiumFor(cost, premium);
        (int24 lower, int24 upper) = _carveAll(id, takes, count);

        _tax(owner, cost);
        (int256 eth, int256 tokens) = _settle();
        if (tokens <= 0) revert NothingToBuy();
        uint256 got = tokens.toUint256();

        windows[id] = Window({
            owner: owner,
            expiry: (block.timestamp + duration).toUint40(),
            cuts: count.toUint8(),
            eth: cost.toUint96(),
            tokens: got.toUint96(),
            premium: kept.toUint64()
        });
        Held memory h = held;
        held = Held({eth: (h.eth + cost + kept).toUint128(), tokens: (h.tokens + got).toUint128()});

        emit WindowOpened(id, owner, cost, got, kept, block.timestamp + duration, lower, upper);
        return abi.encode(cost, eth < 0 ? (-eth).toUint256() : 0, kept, got);
    }

    function _carveAll(uint256 id, Take[] memory takes, uint256 count)
        private
        returns (int24 lower, int24 upper)
    {
        lower = type(int24).max;
        upper = type(int24).min;
        for (uint256 i = 0; i < count; ++i) {
            Take memory t = takes[i];
            _carve(t);
            Cut memory c = _cutOf(t);
            _cuts[id][i] = c;
            (int24 low, int24 high) = _span(c);
            if (low < lower) lower = low;
            if (high > upper) upper = high;
        }
    }

    function _closeWindow(uint256 id, bool keep) private returns (uint256 burned, bool backInPlace) {
        Window memory w = windows[id];
        Cut[] memory cuts = cutsOf(id);
        (int24 lower, int24 upper) = (type(int24).max, type(int24).min);
        for (uint256 i = 0; i < cuts.length; ++i) {
            (int24 low, int24 high) = _span(cuts[i]);
            if (low < lower) lower = low;
            if (high > upper) upper = high;
            delete _cuts[id][i];
        }
        delete windows[id];

        uint160 sqrtPrice = _sqrtPrice();
        backInPlace = keep
            ? sqrtPrice <= TickMath.getSqrtPriceAtTick(lower)
            : sqrtPrice >= TickMath.getSqrtPriceAtTick(upper);
        if (backInPlace) {
            for (uint256 i = 0; i < cuts.length; ++i) {
                _restore(cuts[i]);
            }
        } else if (keep) {
            _addEthAbove(sqrtPrice, upper - lower, w.eth);
        } else {
            _addTokensBelow(sqrtPrice, upper - lower, w.tokens);
        }

        int256 spendable = int256(uint256(w.premium)) + (keep ? int256(uint256(w.eth)) : int256(0))
            + POOL_MANAGER.currencyDelta(address(this), ETH);
        if (spendable > 0) _buyBack(spendable.toUint256());
        _settle();

        Held memory h = held;
        h.eth -= uint128(w.eth) + w.premium;
        h.tokens -= w.tokens;
        held = h;

        uint256 balance = TOKEN.balanceOf(address(this));
        uint256 owed = h.tokens + (keep ? w.tokens : 0);
        if (balance < owed) revert Insolvent();
        burned = balance - owed;
    }

    function _addEthAbove(uint160 sqrtPrice, int24 width, uint256 eth) private {
        int24 from = _alignedAtOrAbove(sqrtPrice);
        int24 to = from + width > HIGHEST_TICK ? HIGHEST_TICK : from + width;
        if (from >= to) from = to - TICK_SPACING;
        _add(
            from,
            to,
            _liquidityForEth(TickMath.getSqrtPriceAtTick(from), TickMath.getSqrtPriceAtTick(to), eth)
        );
    }

    function _addTokensBelow(uint160 sqrtPrice, int24 width, uint256 tokens) private {
        int24 to = _alignedAtOrBelow(sqrtPrice);
        int24 from = to - width < LOWEST_TICK ? LOWEST_TICK : to - width;
        if (from >= to) to = from + TICK_SPACING;
        _add(
            from,
            to,
            _liquidityForTokens(TickMath.getSqrtPriceAtTick(from), TickMath.getSqrtPriceAtTick(to), tokens)
        );
    }

    function _buyBack(uint256 eth) private {
        POOL_MANAGER.swap(
            poolKey(),
            SwapParams({
                zeroForOne: true,
                amountSpecified: -eth.toInt256(),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
    }

    function _premiumFor(uint256 cost, uint256 premium)
        private
        view
        returns (uint256 kept, uint256 duration)
    {
        duration = windowFor(premium);
        if (duration < MIN_WINDOW) revert PremiumTooLow();
        kept = premium;
        if (duration > MAX_WINDOW) {
            duration = MAX_WINDOW;
            kept = (MAX_WINDOW * REFERENCE_PREMIUM + BASE_WINDOW - 1) / BASE_WINDOW;
        }
        if (kept * BPS > cost * MAX_PREMIUM_BPS) revert PremiumTooHigh();
    }

    function _seed(int24 tick) private returns (uint256 paid) {
        uint256 tokens = TOKEN.balanceOf(address(this));
        uint160 upper = TickMath.getSqrtPriceAtTick(tick);
        uint128 liquidity = FullMath.mulDiv(
                tokens, FixedPoint96.Q96, upper - TickMath.getSqrtPriceAtTick(LOWEST_TICK)
            ).toUint128();

        _first(LOWEST_TICK, tick, liquidity);

        (int256 eth, int256 tokensIn) = _settle();
        paid = eth < 0 ? (-eth).toUint256() : 0;
        emit Launched(POOL_ID, tick, liquidity, tokensIn < 0 ? (-tokensIn).toUint256() : 0);
    }

    function _settle() private returns (int256 eth, int256 tokens) {
        eth = POOL_MANAGER.currencyDelta(address(this), ETH);
        tokens = POOL_MANAGER.currencyDelta(address(this), TOKEN_CURRENCY);
        if (eth < 0) POOL_MANAGER.settle{value: (-eth).toUint256()}();
        else if (eth > 0) POOL_MANAGER.take(ETH, address(this), eth.toUint256());
        if (tokens < 0) {
            POOL_MANAGER.sync(TOKEN_CURRENCY);
            if (!TOKEN.transfer(address(POOL_MANAGER), (-tokens).toUint256())) revert TransferFailed();
            POOL_MANAGER.settle();
        } else if (tokens > 0) {
            POOL_MANAGER.take(TOKEN_CURRENCY, address(this), tokens.toUint256());
        }
    }

    function _redeem(uint256 amount) private {
        POOL_MANAGER.burn(address(this), ETH.toId(), amount);
        POOL_MANAGER.take(ETH, address(this), amount);
    }

    function _checkSolvent() private view {
        Held memory h = held;
        if (address(this).balance < h.eth || TOKEN.balanceOf(address(this)) < h.tokens) revert Insolvent();
    }

    function _send(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert PayoutFailed();
    }

    function _tax(address payer, uint256 eth) private returns (uint256 fee) {
        fee = FullMath.mulDiv(eth, TAX_BPS, BPS);
        if (fee == 0) return 0;
        POOL_MANAGER.mint(address(this), ETH.toId(), fee);
        devOwed += fee;
        emit Taxed(payer, fee);
    }

    function _ethIsSpecified(SwapParams calldata params) private pure returns (bool) {
        return (params.amountSpecified < 0) == params.zeroForOne;
    }

    function beforeSwap(address sender, PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!_ethIsSpecified(params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        int256 specified = params.amountSpecified;
        uint256 fee = _tax(sender, (specified < 0 ? -specified : specified).toUint256());
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt256().toInt128(), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        if (_ethIsSpecified(params)) return (IHooks.afterSwap.selector, 0);

        int128 eth = delta.amount0();
        uint256 fee = _tax(sender, int256(eth < 0 ? -eth : eth).toUint256());
        return (IHooks.afterSwap.selector, fee.toInt256().toInt128());
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert OnlyTheHookOpensThePool();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert LiquidityIsLocked();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert LiquidityIsLocked();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert NotSupported();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert NotSupported();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert NotSupported();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert NotSupported();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert NotSupported();
    }
}
