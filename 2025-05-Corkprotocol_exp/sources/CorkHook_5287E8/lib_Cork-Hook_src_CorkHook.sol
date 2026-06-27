pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {CurrencySettler} from "v4-periphery/lib/v4-core/test/utils/CurrencySettler.sol";
import {LiquidityToken} from "./LiquidityToken.sol";
import {Action, AddLiquidtyParams, RemoveLiquidtyParams} from "./lib/Calls.sol";
import {SwapMath} from "./lib/SwapMath.sol";
import {IExpiry} from "Depeg-swap/contracts/interfaces/IExpiry.sol";
import {CorkSwapCallback} from "./interfaces/CorkSwapCallback.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {HookForwarder} from "./Forwarder.sol";
import {Constants} from "./Constants.sol";
import {IErrors} from "./interfaces/IErrors.sol";
import {ICorkHook} from "./interfaces/ICorkHook.sol";
import {MarketSnapshot} from "./lib/MarketSnapshot.sol";
import {IHooks} from "v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";

import "./lib/State.sol";
import "./lib/Calls.sol";
import "v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";

contract CorkHook is BaseHook, Ownable, ICorkHook {
    using Clones for address;
    using PoolStateLibrary for PoolState;
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;

    /// @notice Pool state
    mapping(AmmId => PoolState) internal pool;

    // we will deploy proxy to this address for each pool
    address internal immutable lpBase;
    HookForwarder internal immutable forwarder;

    constructor(IPoolManager _poolManager, LiquidityToken _lpBase, address owner)
        BaseHook(_poolManager)
        Ownable(owner)
    {
        lpBase = address(_lpBase);
        forwarder = new HookForwarder(_poolManager);
    }

    modifier onlyInitialized(address a, address b) {
        AmmId ammId = toAmmId(a, b);
        PoolState storage self = pool[ammId];

        if (!self.isInitialized()) {
            revert IErrors.NotInitialized();
        }
        _;
    }

    modifier withinDeadline(uint256 deadline) {
        if (deadline < block.timestamp) {
            revert IErrors.Deadline();
        }
        _;
    }

    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // deploy lp tokens for this pool
            afterInitialize: false,
            beforeAddLiquidity: true, // override, only allow adding liquidity from the hook
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true, // override, only allow removing liquidity from the hook
            afterRemoveLiquidity: false,
            beforeSwap: true, // override, use our price curve
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // override, use our price curve
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        virtual
        override
        returns (bytes4)
    {
        revert IErrors.DisableNativeLiquidityModification();
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external virtual override returns (bytes4) {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        AmmId ammId = toAmmId(token0, token1);

        if (pool[ammId].isInitialized()) {
            revert IErrors.AlreadyInitialized();
        }

        LiquidityToken lp = LiquidityToken(lpBase.clone());
        pool[ammId].initialize(token0, token1, address(lp));

        // check for the token to be valid, i.e have expiry
        {
            PoolState storage self = pool[ammId];
            _saveIssuedAndMaturationTime(self);
        }

        // the reason we just concatenate the addresses instead of their respective symbols is that because this way, we don't need to worry about
        // tokens symbols to have different encoding and other shinanigans. Frontend should parse and display the token symbols accordingly
        string memory identifier =
            string.concat(Strings.toHexString(uint160(token0)), "-", Strings.toHexString(uint160(token1)));

        lp.initialize(string.concat("Liquidity Token ", identifier), string.concat("LP-", identifier), address(this));

        return this.beforeInitialize.selector;
    }

    function _ensureValidAmount(uint256 amount0, uint256 amount1) internal pure {
        if (amount0 == 0 && amount1 == 0) {
            revert IErrors.InvalidAmount();
        }

        if (amount0 != 0 && amount1 != 0) {
            revert IErrors.InvalidAmount();
        }
    }

    // we default to exact out swap, since it's easier to do flash swap this way
    // only support flash swap where the user pays with the other tokens
    // for paying with the same token, use "take" and "settle" directly in the pool manager
    function swap(address ra, address ct, uint256 amountRaOut, uint256 amountCtOut, bytes calldata data)
        external
        onlyInitialized(ra, ct)
        returns (uint256 amountIn)
    {
        SortResult memory sortResult = sortPacked(ra, ct, amountRaOut, amountCtOut);
        sortResult = normalize(sortResult);

        _ensureValidAmount(sortResult.amount0, sortResult.amount1);

        // if the amount1 is zero, then we swap token0 to token1, and vice versa
        bool zeroForOne = sortResult.amount0 <= 0;
        uint256 out = zeroForOne ? sortResult.amount1 : sortResult.amount0;

        {
            PoolState storage self = pool[toAmmId(sortResult.token0, sortResult.token1)];
            (amountIn,) = _getAmountIn(self, zeroForOne, out);
        }

        // turn the amount back to the original token decimals for user returns and accountings
        {
            amountIn = toNative(zeroForOne ? sortResult.token0 : sortResult.token1, amountIn);
            out = toNative(zeroForOne ? sortResult.token1 : sortResult.token0, out);
        }

        bytes memory swapData;
        IPoolManager.SwapParams memory ammSwapParams;
        ammSwapParams = IPoolManager.SwapParams(zeroForOne, int256(out), Constants.SQRT_PRICE_1_1);

        SwapParams memory params;
        PoolKey memory key = getPoolKey(sortResult.token0, sortResult.token1);

        params = SwapParams(data, ammSwapParams, key, msg.sender, out, amountIn);
        swapData = abi.encode(Action.Swap, params);

        poolManager.unlock(swapData);
    }

    function _initSwap(SwapParams memory params) internal {
        // trf user token to forwarder
        address token0 = Currency.unwrap(params.poolKey.currency0);
        address token1 = Currency.unwrap(params.poolKey.currency1);

        // regular swap, the user already has the token, so we directly transfer the token to the forwarder
        // if it has data, then its a flash swap, user usually doesn't have the token to pay, so we skip this step
        // and let the user pay on the callback directly to pool manager
        if (params.swapData.length == 0) {
            if (params.params.zeroForOne) {
                IERC20(token0).transferFrom(params.sender, address(forwarder), params.amountIn);
            } else {
                IERC20(token1).transferFrom(params.sender, address(forwarder), params.amountIn);
            }
        }

        forwarder.swap(params);
    }

    function _addLiquidity(PoolState storage self, uint256 amount0, uint256 amount1, address sender) internal {
        // we can safely insert 0 here since we have checked for validity at the start
        self.addLiquidity(amount0, amount1, sender, 0, 0);

        Currency token0 = self.getToken0();
        Currency token1 = self.getToken1();

        // settle claims token
        settleNormalized(token0, poolManager, sender, amount0, false);
        settleNormalized(token1, poolManager, sender, amount1, false);

        // take the tokens
        takeNormalized(token0, poolManager, address(this), amount0, true);
        takeNormalized(token1, poolManager, address(this), amount1, true);
    }

    function _removeLiquidity(PoolState storage self, uint256 liquidityAmount, address sender) internal {
        (uint256 amount0, uint256 amount1,,) = self.removeLiquidity(liquidityAmount, sender);

        Currency token0 = self.getToken0();
        Currency token1 = self.getToken1();

        // burn claims token
        settle(token0, poolManager, address(this), amount0, true);
        settle(token1, poolManager, address(this), amount1, true);

        // send back the tokens
        take(token0, poolManager, sender, amount0, false);
        take(token1, poolManager, sender, amount1, false);
    }

    // we dont check for initialization here since we want to pre init the fee
    function updateBaseFeePercentage(address ra, address ct, uint256 baseFeePercentage) external onlyOwner {
        pool[toAmmId(ra, ct)].fee = baseFeePercentage;
    }

    function updateTreasurySplitPercentage(address ra, address ct, uint256 treasurySplit) external onlyOwner {
        pool[toAmmId(ra, ct)].treasurySplitPercentage = treasurySplit;
    }

    function addLiquidity(
        address ra,
        address ct,
        uint256 raAmount,
        uint256 ctAmount,
        uint256 amountRamin,
        uint256 amountCtmin,
        uint256 deadline
    ) external withinDeadline(deadline) returns (uint256 amountRa, uint256 amountCt, uint256 mintedLp) {
        // returns how much liquidity token was minted
        SortResult memory sortResult = sortPacked(ra, ct, raAmount, ctAmount);
        sortResult = normalize(sortResult);

        PoolState storage self = pool[toAmmId(sortResult.token0, sortResult.token1)];

        // all sanitiy check should go here
        if (!self.isInitialized()) {
            forwarder.initializePool(sortResult.token0, sortResult.token1);
            emit Initialized(ra, ct, address(self.liquidityToken));
        }

        {
            (,, uint256 amount0min, uint256 amount1min) = sort(ra, ct, amountRamin, amountCtmin);
            // check and returns how much lp minted
            // we use the return argument as container here but amountRa is actually token0 used right now
            // we stay it like this to avoid stack too deep errors and because we need the actual amount used to transfer from user
            (,, mintedLp, amountRa, amountCt) =
                self.tryAddLiquidity(sortResult.amount0, sortResult.amount1, amount0min, amount1min);
        }

        {
            // we use the previously used amount here
            AddLiquidtyParams memory params =
                AddLiquidtyParams(sortResult.token0, amountRa, sortResult.token1, amountCt, msg.sender);

            // now we actually sort back the tokens
            (amountRa, amountCt) = ra == sortResult.token0 ? (amountRa, amountCt) : (amountCt, amountRa);

            // we convert the amount to the native decimals to reflect the actual amount when returning
            amountRa = toNative(ra, amountRa);
            amountCt = toNative(ct, amountCt);

            bytes memory data = abi.encode(Action.AddLiquidity, params);

            poolManager.unlock(data);
        }

        emit ICorkHook.AddedLiquidity(ra, ct, amountRa, amountCt, mintedLp, msg.sender);
    }

    function removeLiquidity(
        address ra,
        address ct,
        uint256 liquidityAmount,
        uint256 amountRamin,
        uint256 amountCtmin,
        uint256 deadline
    ) external withinDeadline(deadline) returns (uint256 amountRa, uint256 amountCt) {
        SortResult memory sortResult = sortPacked(ra, ct);

        AmmId ammId = toAmmId(sortResult.token0, sortResult.token1);
        PoolState storage self = pool[ammId];

        // sanity check, we explicitly check here instrad of using modifier to avoid stack too deep
        if (!self.isInitialized()) {
            revert IErrors.NotInitialized();
        }

        (uint256 amount0, uint256 amount1,,) = self.tryRemoveLiquidity(liquidityAmount);
        (,, amountRa, amountCt) = reverseSortWithAmount(ra, ct, sortResult.token0, sortResult.token1, amount0, amount1);

        if (amountRa < amountRamin || amountCt < amountCtmin) {
            revert IErrors.InsufficientOutputAmout();
        }

        {
            RemoveLiquidtyParams memory params =
                RemoveLiquidtyParams(sortResult.token0, sortResult.token1, liquidityAmount, msg.sender);

            bytes memory data = abi.encode(Action.RemoveLiquidity, params);

            poolManager.unlock(data);
        }

        {
            emit ICorkHook.RemovedLiquidity(ra, ct, amountRa, amountCt, msg.sender);
        }
    }

    function _unlockCallback(bytes calldata data) internal virtual override returns (bytes memory) {
        Action action = abi.decode(data, (Action));

        if (action == Action.AddLiquidity) {
            (, AddLiquidtyParams memory params) = abi.decode(data, (Action, AddLiquidtyParams));

            _addLiquidity(pool[toAmmId(params.token0, params.token1)], params.amount0, params.amount1, params.sender);
            return "";
        }

        if (action == Action.RemoveLiquidity) {
            (, RemoveLiquidtyParams memory params) = abi.decode(data, (Action, RemoveLiquidtyParams));

            _removeLiquidity(pool[toAmmId(params.token0, params.token1)], params.liquidityAmount, params.sender);
            return "";
        }

        if (action == Action.Swap) {
            (, SwapParams memory params) = abi.decode(data, (Action, SwapParams));

            _initSwap(params);
        }

        return "";
    }

    function getLiquidityToken(address ra, address ct) external view onlyInitialized(ra, ct) returns (address) {
        return address(pool[toAmmId(ra, ct)].liquidityToken);
    }

    function getReserves(address ra, address ct) external view onlyInitialized(ra, ct) returns (uint256, uint256) {
        AmmId ammId = toAmmId(ra, ct);

        uint256 reserve0 = pool[ammId].reserve0;
        uint256 reserve1 = pool[ammId].reserve1;

        // we sort according what user requested
        return ra < ct ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta delta, uint24) {
        PoolState storage self = pool[toAmmId(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1))];
        // kinda packed, avoid stack too deep

        delta = toBeforeSwapDelta(-int128(params.amountSpecified), int128(_beforeSwap(self, params, hookData, sender)));

        // TODO: do we really need to specify the fee here?
        return (this.beforeSwap.selector, delta, 0);
    }

    // logically the flow is
    // 1. the hook settle the output token first, to create a debit. this enable flash swap
    // 2. token is transferred to the user using forwarder or router
    // 3 the user/router settle(pay) the input token
    // 4. the hook take the input token
    function _beforeSwap(
        PoolState storage self,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData,
        address sender
    ) internal returns (int256 unspecificiedAmount) {
        bool exactIn = (params.amountSpecified < 0);
        uint256 amountIn;
        uint256 amountOut;
        // the fee here will always refer to the input token
        uint256 fee;

        (Currency input, Currency output) = _getInputOutput(self, params.zeroForOne);

        // we calculate how much they must pay
        if (exactIn) {
            amountIn = uint256(-params.amountSpecified);
            amountIn = normalize(input, amountIn);
            (amountOut, fee) = _getAmountOut(self, params.zeroForOne, amountIn);
        } else {
            amountOut = uint256(params.amountSpecified);
            amountOut = normalize(output, amountOut);
            (amountIn, fee) = _getAmountIn(self, params.zeroForOne, amountOut);
        }

        // if exact in, the hook must goes into "debt" equal to amount out
        // since at that point, the user specifies how much token they wanna swap. you can think of it like
        //
        // EXACT IN :
        // specifiedDelta : unspecificiedDelta =  how much input token user want to swap : how much the hook must give
        //
        // EXACT OUT :
        // unspecificiedDelta : specifiedDelta =  how much output token the user wants : how much input token user must pay
        unspecificiedAmount = exactIn ? -int256(toNative(output, amountOut)) : int256(toNative(input, amountIn));

        self.ensureLiquidityEnoughAsNative(amountOut, Currency.unwrap(output));

        // update reserve
        self.updateReservesAsNative(Currency.unwrap(output), amountOut, true);

        // we transfer their tokens, i.e we settle the output token first so that the user can take the input token
        settleNormalized(output, poolManager, address(this), amountOut, true);

        // there is data, means flash swap
        if (hookData.length > 0) {
            // will 0 if user pay with the same token
            unspecificiedAmount = _executeFlashSwap(self, hookData, input, output, amountIn, amountOut, sender, exactIn);
            // no data, means normal swap
        } else {
            // update reserve
            self.updateReservesAsNative(Currency.unwrap(input), amountIn, false);

            // settle swap, i.e we take the input token from the pool manager, the debt will be payed by the user
            takeNormalized(input, poolManager, address(this), amountIn, true);

            // forward token to user if caller is forwarder
            if (sender == address(forwarder)) {
                forwarder.forwardToken(input, output, amountIn, amountOut);
            }
        }

        // IMPORTANT: we won't compare K right now since the K amount will never be the same and have slight imprecision.
        // but this is fine since the hook knows how much tokens it should receive and give based on the balance delta which it calculate from the invariants

        // split fee from input token
        _splitFee(self, fee, input);

        {
            // the true caller, we try to infer this by checking if the sender is the forwarder, we can get the true caller from
            // the forwarder transient slot
            // if not then we fallback to whoever is the sender
            address actualSender = sender == address(forwarder) ? forwarder.getCurrentSender() : sender;

            (uint256 baseFeePercentage, uint256 actualFeePercentage) = _getFee(self);

            emit ICorkHook.Swapped(
                Currency.unwrap(input),
                Currency.unwrap(output),
                toNative(input, amountIn),
                toNative(output, amountOut),
                actualSender,
                baseFeePercentage,
                actualFeePercentage,
                fee
            );
        }
    }

    function _splitFee(PoolState storage self, uint256 fee, Currency _token) internal {
        address token = Currency.unwrap(_token);
        
        // split fee
        uint256 treasuryAttributed = SwapMath.calculatePercentage(fee, self.treasurySplitPercentage);
        self.updateReservesAsNative(token, treasuryAttributed, true);

        // take and settle fee token from manager
        settleNormalized(_token, poolManager, address(this), treasuryAttributed, true);
        takeNormalized(_token, poolManager, address(this), treasuryAttributed, false);
        
        // send fee to treasury
        ITreasury config = ITreasury(owner());
        address treasury = config.treasury();

        TransferHelper.transferNormalize(token, treasury, treasuryAttributed);
    }

    function getFee(address ra, address ct)
        external
        view
        onlyInitialized(ra, ct)
        returns (uint256 baseFeePercentage, uint256 actualFeePercentage)
    {
        PoolState storage self = pool[toAmmId(ra, ct)];

        (baseFeePercentage, actualFeePercentage) = _getFee(self);
    }

    function _getFee(PoolState storage self)
        internal
        view
        returns (uint256 baseFeePercentage, uint256 actualFeePercentage)
    {
        baseFeePercentage = self.fee;

        (uint256 start, uint256 end) = _getIssuedAndMaturationTime(self);
        actualFeePercentage = SwapMath.getFeePercentage(baseFeePercentage, start, end, block.timestamp);
    }

    function _executeFlashSwap(
        PoolState storage self,
        bytes calldata hookData,
        Currency input,
        Currency output,
        uint256 amountIn,
        uint256 amountOut,
        address sender,
        bool exactIn
    ) internal returns (int256 unspecificiedAmount) {
        // exact in doesn't make sense on flash swap
        if (exactIn) {
            revert IErrors.NoExactIn();
        }

        {
            // send funds to the user
            try forwarder.forwardTokenUncheked(output, amountOut) {}
            // if failed then the user directly calls pool manager to flash swap, in that case we must send their token directly here
            catch {
                takeNormalized(input, poolManager, sender, amountIn, false);
            }

            // we expect user to use exact output swap when dealing with flash swap
            // so we use amountIn as the payment amount cause they they have to pay with the other token
            (uint256 paymentAmount, address paymentToken) = (amountIn, Currency.unwrap(input));

            // we convert the payment amount to the native decimals, fso that integrator contract can use it directly
            paymentAmount = toNative(paymentToken, paymentAmount);

            // call the callback
            CorkSwapCallback(sender).CorkCall(sender, hookData, paymentAmount, paymentToken, address(poolManager));
        }

        // process repayments

        // update reserve
        self.updateReservesAsNative(Currency.unwrap(input), amountIn, false);

        // settle swap, i.e we take the input token from the pool manager, the debt will be payed by the user, at this point, the user should've created a debit on the PM
        takeNormalized(input, poolManager, address(this), amountIn, true);

        // this is similar to normal swap, the unspecified amount is the other tokens
        // if exact in, the hook must goes into "debt" equal to amount out
        // since at that point, the user specifies how much token they wanna swap. you can think of it like
        //
        // EXACT IN :
        // specifiedDelta : unspecificiedDelta =  how much input token user want to swap : how much the hook must give
        //
        // EXACT OUT :
        // unspecificiedDelta : specifiedDelta =  how much output token the user wants : how much input token user must pay
        //
        // since in this case, exact in swap doesn't really make sense, we just return the amount in
        unspecificiedAmount = int256(toNative(input, amountIn));
    }

    function _getAmountIn(PoolState storage self, bool zeroForOne, uint256 amountOut)
        internal
        view
        returns (uint256 amountIn, uint256 fee)
    {
        if (amountOut <= 0) {
            revert IErrors.InvalidAmount();
        }

        (uint256 reserveIn, uint256 reserveOut) =
            zeroForOne ? (self.reserve0, self.reserve1) : (self.reserve1, self.reserve0);

        (Currency input, Currency output) = _getInputOutput(self, zeroForOne);

        reserveIn = normalize(input, reserveIn);
        reserveOut = normalize(output, reserveOut);

        if (reserveIn <= 0 || reserveOut <= 0) {
            revert IErrors.NotEnoughLiquidity();
        }

        uint256 oneMinusT = _1MinT(self);
        (amountIn, fee) = SwapMath.getAmountIn(amountOut, reserveIn, reserveOut, oneMinusT, self.fee);
    }

    function getAmountIn(address ra, address ct, bool raForCt, uint256 amountOut)
        external
        view
        onlyInitialized(ra, ct)
        returns (uint256 amountIn)
    {
        (address token0, address token1) = sort(ra, ct);
        // infer zero to one
        bool zeroForOne = raForCt ? (token0 == ra) : (token0 == ct);

        PoolState storage self = pool[toAmmId(token0, token1)];

        address inToken = zeroForOne ? token0 : token1;
        address outToken = zeroForOne ? token1 : token0;

        // we need to normalize the amount out, since we calculate everything in 18 decimals
        amountOut = normalize(outToken, amountOut);
        (amountIn,) = _getAmountIn(self, zeroForOne, amountOut);

        // convert to the proper decimals
        amountIn = TransferHelper.fixedToTokenNativeDecimals(amountIn, inToken);
    }

    function _getAmountOut(PoolState storage self, bool zeroForOne, uint256 amountIn)
        internal
        view
        returns (uint256 amountOut, uint256 fee)
    {
        if (amountIn <= 0) {
            revert IErrors.InvalidAmount();
        }

        (uint256 reserveIn, uint256 reserveOut) =
            zeroForOne ? (self.reserve0, self.reserve1) : (self.reserve1, self.reserve0);

        (Currency input, Currency output) = _getInputOutput(self, zeroForOne);

        reserveIn = normalize(input, reserveIn);
        reserveOut = normalize(output, reserveOut);

        if (reserveIn <= 0 || reserveOut <= 0) {
            revert IErrors.NotEnoughLiquidity();
        }

        uint256 oneMinusT = _1MinT(self);
        (amountOut, fee) = SwapMath.getAmountOut(amountIn, reserveIn, reserveOut, oneMinusT, self.fee);
    }

    function getAmountOut(address ra, address ct, bool raForCt, uint256 amountIn)
        external
        view
        onlyInitialized(ra, ct)
        returns (uint256 amountOut)
    {
        (address token0, address token1) = sort(ra, ct);
        // infer zero to one
        bool zeroForOne = raForCt ? (token0 == ra) : (token0 == ct);

        address inToken = zeroForOne ? token0 : token1;
        address outToken = zeroForOne ? token1 : token0;

        PoolState storage self = pool[toAmmId(token0, token1)];

        // we need to normalize the amount out, since we calculate everything in 18 decimals
        amountIn = normalize(inToken, amountIn);
        (amountOut,) = _getAmountOut(self, zeroForOne, amountIn);

        amountOut = normalize(outToken, amountOut);
    }

    function _getInputOutput(PoolState storage self, bool zeroForOne)
        internal
        view
        returns (Currency input, Currency output)
    {
        (address _input, address _output) = zeroForOne ? (self.token0, self.token1) : (self.token1, self.token0);
        return (Currency.wrap(_input), Currency.wrap(_output));
    }

    function _saveIssuedAndMaturationTime(PoolState storage self) internal {
        IExpiry token0 = IExpiry(self.token0);
        IExpiry token1 = IExpiry(self.token1);

        try token0.issuedAt() returns (uint256 issuedAt0) {
            self.startTimestamp = issuedAt0;
            self.endTimestamp = token0.expiry();
            return;
        } catch {}

        try token1.issuedAt() returns (uint256 issuedAt1) {
            self.startTimestamp = issuedAt1;
            self.endTimestamp = token1.expiry();
            return;
        } catch {}

        revert IErrors.InvalidToken();
    }

    function _getIssuedAndMaturationTime(PoolState storage self) internal view returns (uint256 start, uint256 end) {
        return (self.startTimestamp, self.endTimestamp);
    }

    function _1MinT(PoolState storage self) internal view returns (uint256) {
        (uint256 start, uint256 end) = _getIssuedAndMaturationTime(self);
        return SwapMath.oneMinusT(start, end, block.timestamp);
    }

    function getPoolKey(address ra, address ct) public view returns (PoolKey memory) {
        (address token0, address token1) = sort(ra, ct);
        return PoolKey(
            Currency.wrap(token0), Currency.wrap(token1), Constants.FEE, Constants.TICK_SPACING, IHooks(address(this))
        );
    }

    function getPoolManager() external view returns (address) {
        return address(poolManager);
    }

    function getForwarder() external view returns (address) {
        return address(forwarder);
    }

    function getMarketSnapshot(address ra, address ct) external view returns (MarketSnapshot memory snapshot) {
        PoolState storage self = pool[toAmmId(ra, ct)];

        // sort reserve according user input
        uint256 raReserve = self.token0 == ra ? self.reserve0 : self.reserve1;
        uint256 ctReserve = self.token0 == ct ? self.reserve0 : self.reserve1;

        snapshot.baseFee = self.fee;
        snapshot.liquidityToken = address(self.liquidityToken);
        snapshot.oneMinusT = _1MinT(self);
        snapshot.ra = ra;
        snapshot.ct = ct;
        snapshot.reserveRa = raReserve;
        snapshot.reserveCt = ctReserve;
        snapshot.startTimestamp = self.startTimestamp;
        snapshot.endTimestamp = self.endTimestamp;
        snapshot.treasuryFeePercentage = self.treasurySplitPercentage;
    }
}
