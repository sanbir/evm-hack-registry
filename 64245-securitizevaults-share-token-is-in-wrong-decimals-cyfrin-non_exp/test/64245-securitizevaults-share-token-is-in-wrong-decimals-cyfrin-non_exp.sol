// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./64245-securitizevaults-share-token-is-in-wrong-decimals-cyfrin-non.sol";

contract Finding64245Test is Test {
    function test_exploit_1000_assets_mint_1e9_shares_priced_as_dust() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.vault().decimals(), 18);
        assertEq(e.vault().balanceOf(address(e)), 1_000_000_000);
        assertEq(e.priced(), 1_000_000_000);
        assertEq(e.asset().balanceOf(address(e.vault())), 1000 ether);
    }

    function test_control_fixed_conversion_mints_1000_whole_shares() public {
        Exploit e = new Exploit();
        e.nav().setRate(1e6);
        uint256 shares = e.vault().convertToSharesFixed(1000 ether);
        assertEq(shares, 1000 ether, "18 decimal shares");
    }
}
