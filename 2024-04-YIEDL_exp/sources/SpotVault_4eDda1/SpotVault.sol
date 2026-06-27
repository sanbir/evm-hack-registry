// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "Utils.sol";
import "DefaultAccess.sol";
import "IDiscountPolicy.sol";
import "IOracleConnector.sol";
import "ReentrancyGuard.sol";
import "ERC20.sol";
import "SafeERC20.sol";


interface IUniswapRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function WETH9() external view returns (address);
}

interface IPancakeRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function WETH9() external view returns (address);
}

contract SpotVault is Utils, DefaultAccess, ReentrancyGuard, ERC20 {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for ERC20;
    using Address for address;
    using Address for address payable;

    enum SlippageType{ SWAP, AUM, NAV }

    enum FeeType { DEPOSIT, REDEEM, ROTATION }

    struct TxParams {
        uint nav;
        uint nominalFinalAum;
        uint aum;
        address[] assets;
        uint256[] prices;
        uint256[] usdValues;
        address feeRecipient;
        address feeAsset;
        uint256 totalSupply;
    }

    struct RotationParams {
        uint256 startAum;
        uint256 srcTokenSize;
        uint256 dstTokenSize;
        bool srcTokenLessThanBefore;
        address nativeToken;
    }

    uint256 public maxAssets;
    mapping (SlippageType => uint256) public slippageTolerances;

    IOracleConnector public oracle;

    // fee variables
    address payable public feeRecipient;
    mapping (FeeType => uint256) public feePercentages;
    address public feeAsset;
    bool public useUniswap;
    IDiscountPolicy public discountPolicy;
    mapping (uint256 => uint256) public feeRecord;
    mapping (address => uint24) public directPoolSwapFee;
    uint256 public immutable FEE_INTERVAL;
    uint256 constant MAX_FEE_PERCENTAGE = 10 * UNIT / 100;

    // immutables
    address public immutable ONE_INCH_AGG_ROUTER;
    address public immutable DIRECT_SWAP_ROUTER;
    address public immutable NATIVE_TOKEN;
    uint256 constant SLIPPAGE_LOWER_BOUND = 5 * UNIT / 1000; // 0.5%
    uint256 constant SLIPPAGE_UPPER_BOUND = UNIT / 5; // 20%

    // constants
    bytes32 public constant ROTATOR = keccak256('ROTATOR');
    bytes32 public constant ORACLE_MGR = keccak256('ORACLE_MGR');
    uint256 public constant UNIT = 10 ** 18;

    EnumerableSet.AddressSet private portfolio;
    EnumerableSet.AddressSet private depositableAssets;

    event DepositableAssetUpdated(address indexed token, bool indexed added);
    event DiscountPolicyUpdated(address discountPolicy);
    event FeeCollected(address indexed feeCollectionToken, uint256 feeAmount);
    event FeeDetailsUpdated(uint256 depositFeePercentage, uint256 redeemFeePercentage, uint256 rotationFeePercentage,
        address feeRecipient, address feeAsset);
    event MaxAssetsUpdated(uint256 newMaxAssets);
    event OracleUpdated(address newAddress);
    event RotationFeeCollected(uint256 indexed weekNumber, uint256 usdValue);
    event SlippageToleranceUpdated(SlippageType indexed slippageType, uint256 tolerance);
    event Transaction(bool indexed isDeposit, address indexed user, address indexed txAsset, uint256 txAmount, uint256 shares);

    modifier reimburseGas() {
        uint256 initialGas = gasleft();
        _;
        payable(msg.sender).sendValue((initialGas - gasleft()) * tx.gasprice);
    }

    constructor(
        string memory name, string memory symbol, address nativeToken,
        address oneinchRouter, address directSwapRouter, uint256 feeInterval,
        address initFeeAsset
    )
    ERC20(name, symbol)
    {
        require(nativeToken != address(0), "z1");
        require(oneinchRouter != address(0), "z2");
        require(directSwapRouter != address(0), "z3");
        require(initFeeAsset != address(0), "z4");

        NATIVE_TOKEN = nativeToken;
        ONE_INCH_AGG_ROUTER = oneinchRouter; // 0x1111111254EEB25477B68fb85Ed929f73A960582;
        DIRECT_SWAP_ROUTER = directSwapRouter;
        _initDefaultAccess(msg.sender);
        _setRoleAdmin(ROTATOR, MASTER);
        _grantRole(ROTATOR, msg.sender);
        _setRoleAdmin(ORACLE_MGR, MASTER);
        _grantRole(ORACLE_MGR, msg.sender);

        FEE_INTERVAL = feeInterval;
        feeRecipient = payable(msg.sender);

        feeAsset = initFeeAsset;
        emit FeeDetailsUpdated(0, 0, 0, msg.sender, initFeeAsset);
    }

    receive() external payable {
        require((msg.sender == ONE_INCH_AGG_ROUTER) || (msg.sender == DIRECT_SWAP_ROUTER), "n1");
    }

    /* Restricted ROTATOR Functions */

    function rotationSwaps(
        address[] calldata srcTokens,
        address[] calldata dstTokens,
        bytes[] calldata dataList,
        uint256[] calldata nativeAmounts
    ) external reimburseGas onlyRole(ROTATOR) nonReentrant
    {
        require(srcTokens.length == dstTokens.length, "l");
        require(srcTokens.length == dataList.length, "l");
        require(nativeAmounts.length == dataList.length, "l");

        RotationParams memory rp;

        rp.startAum = _getAum();
        rp.nativeToken = NATIVE_TOKEN;

        {
            for (uint256 i = 0; i < dataList.length; i++) {
                rp.dstTokenSize = dstTokens[i] == rp.nativeToken ? address(this).balance : ERC20(dstTokens[i]).balanceOf(address(this));
                if (srcTokens[i] != rp.nativeToken) {
                    rp.srcTokenSize = ERC20(srcTokens[i]).balanceOf(address(this));
                    ONE_INCH_AGG_ROUTER.functionCall(dataList[i]);
                    rp.srcTokenLessThanBefore = ERC20(srcTokens[i]).balanceOf(address(this)) < rp.srcTokenSize;
                } else {
                    rp.srcTokenSize = address(this).balance;
                    ONE_INCH_AGG_ROUTER.functionCallWithValue(dataList[i], nativeAmounts[i]);
                    rp.srcTokenLessThanBefore = address(this).balance < rp.srcTokenSize;
                }
                require(rp.srcTokenLessThanBefore, "b2");
                require(
                    (dstTokens[i] == rp.nativeToken ? address(this).balance : ERC20(dstTokens[i]).balanceOf(address(this))) > rp.dstTokenSize,
                    "b3"
                );
                _updatePortfolio(ERC20(srcTokens[i]));
                _updatePortfolio(ERC20(dstTokens[i]));
            }
        }

        require(portfolio.length() <= maxAssets, "m2");
        require(absSlippage(rp.startAum, _getAum(), UNIT) <= slippageTolerances[SlippageType.AUM], "s2");
    }

    /* Restricted OPERATOR Functions */

    function collectFee() external reimburseGas onlyRole(OPERATOR)
    {
        uint256 weekNumber = block.timestamp / FEE_INTERVAL;
        require(feeRecord[weekNumber] == 0, "wf");
        uint256 feeValueInUsd = feePercentages[FeeType.ROTATION] * _getAum() / UNIT;

        (int256 price, uint8 priceDecimals, uint256 timestamp) = oracle.getPriceInUsd(feeAsset);
        ERC20 token = ERC20(feeAsset);

        uint256 tokenSize = feeValueInUsd * (10 ** (priceDecimals + token.decimals())) / uint256(price) / UNIT;
        feeRecord[weekNumber] = feeValueInUsd;
        token.safeTransfer(feeRecipient, tokenSize);
        emit RotationFeeCollected(weekNumber, feeValueInUsd);
    }

    function approveAsset(ERC20 token, address spender, uint256 amount) external reimburseGas onlyRole(OPERATOR)
    {
        require((spender == ONE_INCH_AGG_ROUTER) || (spender == DIRECT_SWAP_ROUTER), "a1");
        token.approve(spender, amount);
    }

    function updateDiscountPolicy(address newDiscountPolicy) external onlyRole(OPERATOR) {
        require(newDiscountPolicy.code.length > 0, "dp");
        discountPolicy = IDiscountPolicy(newDiscountPolicy);
        emit DiscountPolicyUpdated(newDiscountPolicy);
    }

    function updateFeeDetails(
        uint256 newDepositFeePercentage,
        uint256 newRedeemFeePercentage,
        uint256 newRotationFeePercentage,
        address payable newFeeRecipient,
        address newFeeAsset,
        bool useUniswapFlag
    )
    external onlyRole(OPERATOR)
    {
        require(
             (newDepositFeePercentage <= MAX_FEE_PERCENTAGE) &&
                (newRedeemFeePercentage <= MAX_FEE_PERCENTAGE) &&
                (newRotationFeePercentage <= MAX_FEE_PERCENTAGE),
            "mf"
        );
        require(newFeeRecipient != address(0), "z4");
        require(newFeeAsset.code.length > 0, "fa");
        feePercentages[FeeType.DEPOSIT] = newDepositFeePercentage;
        feePercentages[FeeType.REDEEM] = newRedeemFeePercentage;
        feePercentages[FeeType.ROTATION] = newRotationFeePercentage;
        feeRecipient = newFeeRecipient;
        feeAsset = newFeeAsset;
        useUniswap = useUniswapFlag;
        emit FeeDetailsUpdated(
            newDepositFeePercentage, newRedeemFeePercentage, newRotationFeePercentage,
            newFeeRecipient, newFeeAsset);
    }

    function updateMaxAssets(uint256 newMaxAssets) external onlyRole(OPERATOR) {
        require(newMaxAssets >= 2, "m1");
        maxAssets = newMaxAssets;
        emit MaxAssetsUpdated(newMaxAssets);
    }

    function updateSlippageTolerance(SlippageType slippageType, uint256 tolerance) external onlyRole(OPERATOR) {
        require(tolerance >= SLIPPAGE_LOWER_BOUND, "sl");
        require(tolerance <= SLIPPAGE_UPPER_BOUND, "su");
        emit SlippageToleranceUpdated(slippageType, tolerance);
        slippageTolerances[slippageType] = tolerance;
    }

    function addDepositableAsset(address token, uint24 fee) external onlyRole(OPERATOR) {
        require(oracle.isTokenSupported(token), "st");
        depositableAssets.add(token);
        directPoolSwapFee[token] = fee;
        if (token != NATIVE_TOKEN) {
            ERC20(token).approve(DIRECT_SWAP_ROUTER, type(uint256).max);
        }
        emit DepositableAssetUpdated(token, true);
    }

    function removeDepositableAsset(address token) external onlyRole(OPERATOR) {
        require(depositableAssets.contains(token), "da");
        depositableAssets.remove(token);
        directPoolSwapFee[token] = 0;
        if (token != NATIVE_TOKEN) {
            ERC20(token).approve(DIRECT_SWAP_ROUTER, 0);
        }
        emit DepositableAssetUpdated(token, false);
    }

    /* Restricted ORACLE_MGR Functions */
    function updateOracle(address newOracle) external onlyRole(ORACLE_MGR)
    {
        require(newOracle.code.length > 0, "oc");
        oracle = IOracleConnector(newOracle);
        emit OracleUpdated(newOracle);
    }

    /* User Functions */
    function redeem(
        uint256 sharesToRedeem,
        address receivingAsset,
        uint256 minTokensToReceive,
        bytes[] calldata dataList,
        bool useDiscount
    )
    external nonReentrant
    returns (uint256 tokensToReturn)
    {
        require(depositableAssets.contains(receivingAsset), "da");
        TxParams memory dp;
        (dp.aum, dp.assets, dp.prices, dp.usdValues) = _getAllocations(0);
        dp.nav = getNav();
        dp.nominalFinalAum = dp.aum - (dp.nav * sharesToRedeem / UNIT);
        require(dataList.length == dp.assets.length, "l");
        dp.totalSupply = totalSupply();
        uint256 rcvTokenAccumulator =
        (receivingAsset == NATIVE_TOKEN ? address(this).balance : ERC20(receivingAsset).balanceOf(address(this)))
         * sharesToRedeem / dp.totalSupply;

        for (uint256 i = 0; i < dp.assets.length; i++) {
            if (dp.assets[i] == receivingAsset) {
                continue;
            }
            uint256 rcvTokenSize = receivingAsset == NATIVE_TOKEN ? address(this).balance :
                ERC20(receivingAsset).balanceOf(address(this));

            if (dp.assets[i] != NATIVE_TOKEN) {
                ONE_INCH_AGG_ROUTER.functionCall(dataList[i]);
            } else {
                uint256 sizeToSwap = address(this).balance * sharesToRedeem / dp.totalSupply;
                ONE_INCH_AGG_ROUTER.functionCallWithValue(dataList[i], sizeToSwap);
            }

            rcvTokenAccumulator += receivingAsset == NATIVE_TOKEN ? address(this).balance - rcvTokenSize :
                ERC20(receivingAsset).balanceOf(address(this)) - rcvTokenSize;
        }
        _burn(msg.sender, sharesToRedeem);

        uint256 feePortion = rcvTokenAccumulator * feePercentages[FeeType.REDEEM] / UNIT;
        dp.feeRecipient = feeRecipient;
        if (useDiscount) {
            (uint256 discountTokensToSpend, uint256 discountMultiplier) = discountPolicy.computeDiscountTokensToSpend(_getUsdValue(receivingAsset, feePortion));
            ERC20(discountPolicy.discountToken()).safeTransferFrom(msg.sender, dp.feeRecipient, discountTokensToSpend);
            feePortion = feePortion * discountMultiplier / (10 ** discountPolicy.decimals());
            emit FeeCollected(discountPolicy.discountToken(), discountTokensToSpend);
        }

        tokensToReturn = rcvTokenAccumulator - feePortion;
        require((tokensToReturn) >= minTokensToReceive, "s4");
        if (receivingAsset == NATIVE_TOKEN) {
            payable(msg.sender).sendValue(tokensToReturn);
        } else {
            ERC20(receivingAsset).safeTransfer(msg.sender, tokensToReturn);
        }

        if (feePortion > 0) {
            uint256 feeTokenAmount;
            dp.feeAsset = feeAsset;
            if (receivingAsset == dp.feeAsset) {
                feeTokenAmount = feePortion;
            }
            else {
                feeTokenAmount = _directSwapForFee(
                    feePortion,
                    0, // don't hinder redemptions due to low liquidity for the fee conversion.
                    receivingAsset,
                    dp.feeAsset
                );
            }

            ERC20(dp.feeAsset).safeTransfer(dp.feeRecipient, feeTokenAmount);
            emit FeeCollected(dp.feeAsset, feeTokenAmount);
        }

        require(absSlippage(dp.nav, getNav(), UNIT) <= slippageTolerances[SlippageType.NAV], "s3");
        _postSwapHandler(receivingAsset, dp);

        emit Transaction(false, msg.sender, receivingAsset, tokensToReturn, sharesToRedeem);
    }

    function deposit(
        ERC20 token,
        uint256 amountIn,
        uint256 minSharesToReceive,
        bytes[] calldata dataList,
        bytes calldata feeSwapData,
        bool useDiscount
    )
    external nonReentrant
    returns (uint256 sharesToMint)
    {
        require(address(token) != NATIVE_TOKEN, "n2");

        // handle discount
        uint256 feeAmount = amountIn * feePercentages[FeeType.DEPOSIT] / UNIT;
        if (useDiscount) {
            (uint256 discountTokensToSpend, uint256 discountMultiplier) = discountPolicy.computeDiscountTokensToSpend(_getUsdValue(address(token), feeAmount));
            ERC20(discountPolicy.discountToken()).safeTransferFrom(msg.sender, feeRecipient, discountTokensToSpend);
            feeAmount = feeAmount * discountMultiplier / (10 ** discountPolicy.decimals());
            emit FeeCollected(discountPolicy.discountToken(), discountTokensToSpend);
        }
        uint256 effectiveAmount = amountIn - feeAmount;

        // compute swap allocation, do this before moving in the deposited token.
        TxParams memory dp = _preSwapHandler(token, minSharesToReceive);
        dp.nominalFinalAum = dp.aum + _getUsdValue(address(token), effectiveAmount);
        require(dp.assets.length == dataList.length, "l");

        // move deposited token in.
        token.safeTransferFrom(msg.sender, address(this), amountIn);

        // swap and get fees
        if (feeAmount > 0) {
            uint256 feeTokenDeltaBal;
            ERC20 feeToken = ERC20(feeAsset);
            if (feeToken != token) {
                uint256 feeTokenBeforeBal = feeToken.balanceOf(address(this));
                ONE_INCH_AGG_ROUTER.functionCall(feeSwapData);
                feeTokenDeltaBal = feeToken.balanceOf(address(this)) - feeTokenBeforeBal;
            } else {
                feeTokenDeltaBal = feeAmount;
            }
            feeToken.safeTransfer(feeRecipient, feeTokenDeltaBal);
            emit FeeCollected(address(feeToken), feeTokenDeltaBal);
        }

        // perform swaps
        for (uint256 i = 0; i < dp.assets.length; i++) {
            if (dp.assets[i] == address(token)) {
                continue;
            }
            ONE_INCH_AGG_ROUTER.functionCall(dataList[i]);
        }
        if (dp.nav != 0) {
            uint256 endAum = _postSwapHandler(address(token), dp);
            sharesToMint = (endAum * UNIT / dp.nav) - totalSupply();

            require(sharesToMint >= minSharesToReceive, "s4");
            _mint(msg.sender, sharesToMint);
            require(absSlippage(dp.nav, getNav(), UNIT) <= slippageTolerances[SlippageType.NAV], "s3");
        } else { // cold start
            _updatePortfolio(token);
            sharesToMint = _getAum();
            _mint(msg.sender, sharesToMint);
        }
        emit Transaction(true, msg.sender, address(token), amountIn, sharesToMint);
    }

    function depositNative(
        uint256 minSharesToReceive,
        bytes[] calldata dataList,
        uint256[] calldata nativeAmounts,
        bytes calldata feeSwapData,
        bool useDiscount
    )
    payable external nonReentrant
    returns (uint256 sharesToMint)
    {
        require(depositableAssets.contains(NATIVE_TOKEN), "da");

        // handle discount
        uint256 feeAmount = msg.value * feePercentages[FeeType.DEPOSIT] / UNIT;
        if (useDiscount) {
            (uint256 discountTokensToSpend, uint256 discountMultipler) = discountPolicy.computeDiscountTokensToSpend(_getUsdValue(NATIVE_TOKEN, feeAmount));
            ERC20(discountPolicy.discountToken()).safeTransferFrom(msg.sender, feeRecipient, discountTokensToSpend);
            feeAmount = feeAmount * discountMultipler / (10 ** discountPolicy.decimals());
            emit FeeCollected(discountPolicy.discountToken(), discountTokensToSpend);
        }

        uint256 amount = msg.value - feeAmount;
        if (feeAmount > 0) {
            ERC20 feeToken = ERC20(feeAsset);
            uint256 feeTokenBeforeBal = feeToken.balanceOf(address(this));
            ONE_INCH_AGG_ROUTER.functionCallWithValue(feeSwapData, feeAmount);
            uint256 feeTokenDeltaBal = feeToken.balanceOf(address(this)) - feeTokenBeforeBal;
            feeToken.safeTransfer(feeRecipient, feeTokenDeltaBal);
            emit FeeCollected(address(feeToken), feeTokenDeltaBal);
        }

        // compute swap allocation. account for deposited native token that has already
        // arrived in contract at beginning of function.
        TxParams memory dp;
        dp.totalSupply = totalSupply();
        (dp.aum, dp.assets, dp.prices, dp.usdValues) = _getAllocations(amount);
        if (dp.aum == 0) {
            dp.nav = 0;
        } else {
            dp.nav = dp.aum * UNIT / dp.totalSupply;
        }
        dp.nominalFinalAum = dp.aum + _getUsdValue(NATIVE_TOKEN, amount);
        require(dp.assets.length == dataList.length, "l");


        // perform swaps
        for (uint256 i = 0; i < dp.assets.length; i++) {
            if (dp.assets[i] == NATIVE_TOKEN) {
                continue;
            }

            ONE_INCH_AGG_ROUTER.functionCallWithValue(dataList[i], nativeAmounts[i]);
        }

        if (dp.nav != 0) {
            uint256 endAum = _postSwapHandler(NATIVE_TOKEN, dp);
            sharesToMint = (endAum * UNIT / dp.nav) - dp.totalSupply;

            require(sharesToMint >= minSharesToReceive, "s4");
            _mint(msg.sender, sharesToMint);
            require(absSlippage(dp.nav, getNav(), UNIT) <= slippageTolerances[SlippageType.NAV], "s3");
        } else { // cold start
            _updatePortfolio(ERC20(NATIVE_TOKEN));
            sharesToMint = _getAum();
            _mint(msg.sender, sharesToMint);
        }
        emit Transaction(true, msg.sender, NATIVE_TOKEN, msg.value, sharesToMint);
    }

    /* Private Write Functions */

    function _directSwapForFee(
        uint256 amountIn,
        uint256 amountOutMin,
        address srcToken,
        address dstToken
    ) private returns (uint256 actualAmountOut){
        if (useUniswap) {
            IUniswapRouterV3.ExactInputSingleParams memory data;
            data.amountIn = amountIn;
            data.amountOutMinimum = amountOutMin;
            data.tokenIn = srcToken == NATIVE_TOKEN ? IUniswapRouterV3(DIRECT_SWAP_ROUTER).WETH9() : srcToken;
            data.tokenOut = dstToken;
            data.recipient = address(this);
            data.sqrtPriceLimitX96 = 0;
            data.fee = directPoolSwapFee[srcToken];
            data.deadline = block.timestamp + 60;
            actualAmountOut = srcToken == NATIVE_TOKEN ?
                IUniswapRouterV3(DIRECT_SWAP_ROUTER).exactInputSingle{value: amountIn}(data) :
                IUniswapRouterV3(DIRECT_SWAP_ROUTER).exactInputSingle(data);
        } else {
            IPancakeRouterV3.ExactInputSingleParams memory data;
            data.amountIn = amountIn;
            data.amountOutMinimum = amountOutMin;
            data.tokenIn = srcToken == NATIVE_TOKEN ? IPancakeRouterV3(DIRECT_SWAP_ROUTER).WETH9() : srcToken;
            data.tokenOut = dstToken;
            data.recipient = address(this);
            data.sqrtPriceLimitX96 = 0;
            data.fee = directPoolSwapFee[srcToken];
            actualAmountOut = srcToken == NATIVE_TOKEN ?
                IPancakeRouterV3(DIRECT_SWAP_ROUTER).exactInputSingle{value: amountIn}(data) :
                IPancakeRouterV3(DIRECT_SWAP_ROUTER).exactInputSingle(data);
        }
    }

    function _preSwapHandler(
        ERC20 token,
        uint256 minSharesToReceive
    ) private returns (TxParams memory dp) {
        require(depositableAssets.contains(address(token)), "da");
        (dp.aum, dp.assets, dp.prices, dp.usdValues) = _getAllocations(0);
        dp.nav = dp.aum == 0 ? 0 : getNav();
        return dp;
    }

    function _postSwapHandler(address token, TxParams memory dp)
    private returns (uint256 endAum) {
        if (!portfolio.contains(token)) {
                require(
                (token == NATIVE_TOKEN ? address(this).balance: ERC20(token).balanceOf(address(this))) == 0, "b1");
            }
        uint256[] memory newUsdValues;
        (endAum, newUsdValues) = _getAllocationsWithPrices(dp.assets, dp.prices);
        require(absSlippage(dp.nominalFinalAum, endAum, UNIT) <= slippageTolerances[SlippageType.AUM], "s2");

        // check that the allocations are not unreasonably skewed
        for (uint256 i = 0; i < dp.assets.length; i++) {
            uint256 initialAlloc = dp.usdValues[i] * UNIT / dp.aum;
            uint256 newAlloc = newUsdValues[i] * UNIT / endAum;
            require(absSlippage(initialAlloc, newAlloc, UNIT) <= slippageTolerances[SlippageType.SWAP], "s1");
        }
    }

    function _updatePortfolio(ERC20 token) private {
        uint256 balance = address(token) == NATIVE_TOKEN ? address(this).balance : token.balanceOf(address(this));
        if (balance > 0) {
            require(oracle.isTokenSupported(address(token)), "st");
            portfolio.add(address(token));
        } else {
            require(address(token) != NATIVE_TOKEN, "p1");
            require(address(token) != feeAsset, "p2");
            portfolio.remove(address(token));
        }
    }

    /* View Functions */

    function getAllocations()
    external view
    returns (uint256 aumInUsd, address[] memory assets, uint256[] memory prices, uint256[] memory usdValues)
    {
        return _getAllocations(0);
    }

    function getDepositableAssets()
    external view
    returns (address[] memory)
    {
        return depositableAssets.values();
    }

    function getNav() public view returns (uint256 nav) {
        return _getAum() * UNIT / totalSupply();
    }

    function _getAllocations(uint256 nativeIn) private view
    returns (uint256 aumInUsd, address[] memory assets, uint256[] memory prices, uint256[] memory usdValues)
    {
        uint256 len = portfolio.length();
        aumInUsd = 0;
        assets = new address[](len);
        usdValues = new uint256[](len);
        prices = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            address token = portfolio.at(i);
            uint256 size = address(token) == NATIVE_TOKEN ? address(this).balance - nativeIn : ERC20(token).balanceOf(address(this));
            uint256 priceUnit18 = _getPriceUnit18(token);
            uint256 usdValue = _getUsdValueUnit18(token, size, priceUnit18);
            aumInUsd += usdValue;
            assets[i] = token;
            usdValues[i] = usdValue;
            prices[i] = priceUnit18;
        }
    }

    function _getAllocationsWithPrices(address[] memory tokens, uint256[] memory prices) private view
    returns (uint256 aumInUsd, uint256[] memory usdValues)
    {
        uint256 len = tokens.length;
        aumInUsd = 0;
        usdValues = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            address token = tokens[i];
            uint256 size = address(token) == NATIVE_TOKEN ? address(this).balance : ERC20(token).balanceOf(address(this));
            uint256 usdValue = _getUsdValueUnit18(token, size, prices[i]);
            aumInUsd += usdValue;
            usdValues[i] = usdValue;
        }
    }

    function _getAum() private view returns (uint256 aum) {
        (aum, , ,) = _getAllocations(0);
    }

    function _getPriceUnit18(address token) private view returns (uint256 priceUnit18) {
        (int256 price, uint8 priceDecimals, ) = oracle.getPriceInUsd(token);
        priceUnit18 = uint256(price) * (10 ** (18 - priceDecimals));  // does not support assets with decimals > 18
    }

    function _getUsdValue(address token, uint256 size) private view returns (uint256 usdValue) {
        uint256 unit = token == NATIVE_TOKEN ? 1e18 : 10 ** ERC20(token).decimals();
        (int256 price, uint8 priceDecimals, uint256 timestamp) = oracle.getPriceInUsd(token);
        usdValue = uint256(price) * size * UNIT / unit / (10 ** priceDecimals);
    }

    function _getUsdValueUnit18(address token, uint256 size, uint256 priceUnit18) private view returns (uint256 usdValueUnit18) {
        uint8 _decimals = token == NATIVE_TOKEN ? 18 : ERC20(token).decimals();
        usdValueUnit18 = priceUnit18 * size / (10 ** _decimals);
    }
}
