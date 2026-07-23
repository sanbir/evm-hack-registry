// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./61477-c-02-missing-asset-index-check-allows-any-token-to-mint-shar.sol";

contract Blueberry61477Test is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.bobUsdcStolen(), 50e8, "50 USDC stolen via junk deposit");
        assertEq(e.tvlAfterJunkDeposit(), 100e18, "tvl not inflated by junk");
        assertEq(e.shareSupplyAfterJunk(), 200e18, "share supply inflated");
    }

    function test_registeredTokenStillWorks() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 8);
        ShareToken share = new ShareToken();
        HyperVaultRouter router = new HyperVaultRouter(usdc, share);
        usdc.mint(address(this), 10e8);
        usdc.approve(address(router), 10e8);
        router.deposit(address(usdc), 10e8);
        assertEq(share.balanceOf(address(this)), 10e18);
        assertEq(router.tvl(), 10e18);
    }
}
