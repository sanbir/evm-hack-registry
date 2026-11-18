// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, CrvUsd, FeeSource, FeeCollectorFixed} from
    "./66509-h-08-access-control-missing-on-fee-functions-enables-misuse.sol";

contract Finding66509Test is Test {
    function test_exploit_royalty_fee_takes_corp_crvusd() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.token().balanceOf(address(e.ve())), 100_000 ether, "ve received 100000");
        assertEq(e.token().balanceOf(address(e.corp())), 0, "corp received 0");
        assertEq(e.token().balanceOf(address(e.source())), 0, "source empty");
    }

    function test_control_only_owner_pays_corp() public {
        CrvUsd token = new CrvUsd();
        FeeSource source = new FeeSource();
        address corp = address(0xC0FFEE);
        FeeCollectorFixed fixedCollector = new FeeCollectorFixed(token, corp);
        fixedCollector.whitelist(address(source));
        token.mint(address(source), 100_000 ether);
        source.approve(token, address(fixedCollector), 100_000 ether);

        vm.expectRevert(bytes("owner"));
        vm.prank(address(0xBEEF));
        fixedCollector.claimNFTUnderlying(address(token), address(source), 100_000 ether, keccak256("ROYALTY_FEE"));

        fixedCollector.claimNFTUnderlying(address(token), address(source), 100_000 ether, keccak256("ROYALTY_FEE"));
        assertEq(token.balanceOf(corp), 100_000 ether, "corp received 100000");
        assertEq(token.balanceOf(address(source)), 0, "source empty");
    }
}
