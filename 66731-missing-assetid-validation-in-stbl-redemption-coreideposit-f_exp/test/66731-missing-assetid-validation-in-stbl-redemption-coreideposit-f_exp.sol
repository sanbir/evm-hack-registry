// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, ValueToken, YLD, Splitter, RedemptionCore, Lp} from
    "./66731-missing-assetid-validation-in-stbl-redemption-coreideposit-f.sol";

contract Finding66731Test is Test {
    function test_exploit_wrong_asset_locks_1_ether_and_bricks_pool() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.locked(), 1 ether, "1 locked");
        assertEq(e.valueToken().balanceOf(address(e.core())), 1 ether, "pool holds 1");
        assertEq(e.core().NFTID(), 2, "poisoned id");
        assertTrue(e.lpReverted(), "lp reverted");
        assertTrue(e.redeemReverted(), "redeem reverted");
        assertEq(e.yld().ownerOf(1), address(e.lp()), "honest nft stays");
        assertEq(e.valueToken().balanceOf(address(e.lp())), 10000 ether, "honest value stays");
    }

    function test_control_asset_check_rejects_wrong_nft_and_redeems() public {
        ValueToken valueToken = new ValueToken();
        YLD yld = new YLD();
        Splitter splitter = new Splitter(yld);
        RedemptionCore core = new RedemptionCore(yld, splitter, valueToken, 1);
        yld.mint(address(this), 2, 2, 1 ether);
        yld.mint(address(this), 1, 1, 10000 ether);
        valueToken.mint(address(this), 10001 ether);
        valueToken.approve(address(core), type(uint256).max);

        YLD.Meta memory wrong = yld.getNFTData(2);
        require(wrong.assetID != core.AssetID(), "pre");
        vm.expectRevert(bytes("STBL_InvalidAsset"));
        this.depositChecked(core, yld, 2);

        this.depositChecked(core, yld, 1);
        assertEq(core.NFTID(), 1, "correct id");
        assertEq(valueToken.balanceOf(address(core)), 10000 ether, "deposited");
        core.redeem(10000 ether);
        assertEq(valueToken.balanceOf(address(core)), 0, "redeemed");
        assertEq(valueToken.balanceOf(address(this)), 10001 ether, "returned plus rejected");
    }

    function depositChecked(RedemptionCore core, YLD yld, uint256 id) external {
        YLD.Meta memory meta = yld.getNFTData(id);
        require(meta.assetID == core.AssetID(), "STBL_InvalidAsset");
        core.iDeposit(id);
    }
}
