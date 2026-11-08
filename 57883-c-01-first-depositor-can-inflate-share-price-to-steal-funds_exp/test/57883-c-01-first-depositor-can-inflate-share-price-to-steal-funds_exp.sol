// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, AssetToken, BalanceBox} from "./57883-c-01-first-depositor-can-inflate-share-price-to-steal-funds.sol";

/// Virtual offset of 10**3 shares, the dead-share mitigation from the review.
/// The same donation no longer rounds the second deposit to zero shares.
contract FundOffset {
    uint256 public constant OFFSET = 1000;

    AssetToken public asset;
    address public balanceContract;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(address _asset, address _box) {
        asset = AssetToken(_asset);
        balanceContract = _box;
        BalanceBox(_box).bind(address(this));
    }

    function deposit(uint256 amount, address receiver) external returns (uint256 shares) {
        asset.transferFrom(msg.sender, balanceContract, amount);
        uint256 assetsBefore = asset.balanceOf(balanceContract) - amount;
        shares = amount * (totalSupply + OFFSET) / (assetsBefore + 1);
        totalSupply += shares;
        balanceOf[receiver] += shares;
    }
}

contract VictimOffset {
    function deposit(FundOffset fund, uint256 amount) external returns (uint256 shares) {
        AssetToken(fund.asset()).approve(address(fund), amount);
        shares = fund.deposit(amount, address(this));
    }
}

contract Finding57883Test is Test {
    function test_exploit_second_depositor_gets_zero_shares() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.victimShares(), 0, "second depositor share balance is 0");
        assertEq(e.attackerProfit(), 100e18, "attacker profit is the victim deposit");
        assertEq(e.asset().balanceOf(address(e.victim())), 0, "victim lost the deposit");
        assertEq(e.fund().balanceOf(address(e.victim())), 0, "victim shares stay 0");
        assertEq(e.fund().totalSupply(), 0, "attacker redeemed the only share");
    }

    function test_control_virtual_offset_mints_shares_to_second_depositor() public {
        AssetToken asset = new AssetToken();
        BalanceBox box = new BalanceBox(address(asset));
        FundOffset fund = new FundOffset(address(asset), address(box));
        VictimOffset victim = new VictimOffset();

        asset.mint(address(this), 1000e18 + 2);
        asset.mint(address(victim), 100e18);
        asset.approve(address(fund), type(uint256).max);

        uint256 first = fund.deposit(2, address(this));
        assertEq(first, 2000, "offset turns 2 wei into 2000 shares");

        asset.transfer(address(box), 1000e18);
        uint256 minted = victim.deposit(fund, 100e18);
        assertGt(minted, 0, "second depositor receives shares");
        assertEq(fund.balanceOf(address(victim)), minted, "share balance matches the mint");
        assertEq(minted, 299, "virtual offset of 1000 shares");
        assertEq(asset.balanceOf(address(victim)), 0, "victim did pay the 100");
        assertGt(fund.balanceOf(address(victim)), 0, "victim can still redeem");
    }
}
