// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Erc20, StakedCSX} from "./44005-h-01-unclaimed-user-staking-rewards-are-going-to-get-lost-on.sol";

/// stake() saves the pending reward into credit before moving the checkpoint.
contract StakedCSXFixed {
    uint256 private constant _DIVISION = 10 ** 33;
    Erc20 public immutable TOKEN_CSX;
    Erc20 public immutable TOKEN_USDC;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    mapping(address => uint256) public lastRewardRate;
    mapping(address => mapping(address => uint256)) public rewardRate;
    mapping(address => mapping(address => uint256)) public credit;
    mapping(address => uint256) public nonDistributed;

    constructor(Erc20 csx, Erc20 usdc) {
        TOKEN_CSX = csx;
        TOKEN_USDC = usdc;
    }

    function stake(uint256 amount) external {
        _claimToCredit(msg.sender);
        totalSupply += amount;
        balanceOf[msg.sender] += amount;
        TOKEN_CSX.transferFrom(msg.sender, address(this), amount);
    }

    function depositAndDistribute(uint256 reward) external {
        TOKEN_USDC.transferFrom(msg.sender, address(this), reward);
        lastRewardRate[address(TOKEN_USDC)] += (reward * _DIVISION) / totalSupply;
    }

    function rewardOf(address account) public view returns (uint256 usdcAmount) {
        uint256 deposited = balanceOf[account];
        if (deposited != 0) {
            usdcAmount = (deposited * (lastRewardRate[address(TOKEN_USDC)] - rewardRate[address(TOKEN_USDC)][account])) / _DIVISION;
        }
        usdcAmount += credit[address(TOKEN_USDC)][account];
    }

    function claim() external returns (uint256 usdcAmount) {
        usdcAmount = rewardOf(msg.sender);
        if (usdcAmount > 0) {
            credit[address(TOKEN_USDC)][msg.sender] = 0;
            rewardRate[address(TOKEN_USDC)][msg.sender] = lastRewardRate[address(TOKEN_USDC)];
            TOKEN_USDC.transfer(msg.sender, usdcAmount);
        }
    }

    function _claimToCredit(address user) internal {
        uint256 owed = rewardOf(user);
        if (owed > 0) credit[address(TOKEN_USDC)][user] = owed;
        rewardRate[address(TOKEN_USDC)][user] = lastRewardRate[address(TOKEN_USDC)];
    }
}

contract Finding44005Test is Test {
    function test_exploit_second_stake_wipes_1000_usdc() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.owedBefore(), 1000e18, "user was owed 1000 before stake");
        assertEq(e.owedAfter(), 0, "second stake wiped the reward");
        assertEq(e.claimed(), 0, "claim paid 0");
        assertEq(e.stuck(), 1000e18, "1000 USDC stuck in StakedCSX");
        assertEq(e.usdc().balanceOf(address(e)), 0, "user received 0");
    }

    function test_control_claim_to_credit_on_stake_pays_1000() public {
        Erc20 csx = new Erc20("CSX", "CSX");
        Erc20 usdc = new Erc20("USD Coin", "USDC");
        StakedCSXFixed staking = new StakedCSXFixed(csx, usdc);
        csx.mint(address(this), 100e18 + 1);
        usdc.mint(address(this), 1000e18);
        csx.approve(address(staking), type(uint256).max);
        usdc.approve(address(staking), 1000e18);

        staking.stake(100e18);
        staking.depositAndDistribute(1000e18);
        assertEq(staking.rewardOf(address(this)), 1000e18, "owed 1000 before the second stake");

        staking.stake(1);
        assertEq(staking.rewardOf(address(this)), 1000e18, "credit kept the 1000");

        uint256 paid = staking.claim();
        assertEq(paid, 1000e18, "claim pays 1000");
        assertEq(usdc.balanceOf(address(this)), 1000e18, "user received 1000");
        assertEq(usdc.balanceOf(address(staking)), 0, "nothing stuck");
    }
}
