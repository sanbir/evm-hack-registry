// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Asset10416} from "./10416-rounding-up-in-minting-shares-openzeppelin-pods-finance-ethe.sol";

contract FixedVault10416 {
    Asset10416 public asset;
    uint256 public totalSupply = 100;
    mapping(address => uint256) public balanceOf;

    constructor(Asset10416 _asset) {
        asset = _asset;
    }

    function process(address owner, uint256 amount) external returns (uint256 shares) {
        uint256 currentAssets = 1000 ether;
        asset.pull(msg.sender, amount);
        shares = currentAssets == 0 || totalSupply == 0 ? amount : amount * totalSupply / currentAssets;
        totalSupply += shares;
        balanceOf[owner] += shares;
    }
}

contract Finding10416Test is Test {
    function test_exploit_one_wei_mints_a_share() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.vault().balanceOf(address(e)), 0, "share redeemed");
        assertEq(e.asset().balanceOf(address(e)), e.WITHDRAWN(), "assets out");
        assertEq(e.EXTRA_SHARES(), 1, "one extra share");
    }

    function test_control_rounds_down_to_zero_shares() public {
        Asset10416 asset = new Asset10416();
        FixedVault10416 vault = new FixedVault10416(asset);
        asset.mint(address(vault), 1000 ether);
        asset.mint(address(this), 1);
        uint256 shares = vault.process(address(this), 1);
        assertEq(shares, 0, "round down");
        assertEq(vault.balanceOf(address(this)), 0, "no share to redeem");
        assertEq(asset.balanceOf(address(this)), 0, "withdrew nothing");
    }
}
