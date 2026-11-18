// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, WETH, CurveV2Pool, CurveConvex2TokenFixed} from "./62490-h-9-hardcoded-useeth-true-in-remove-liquidity-one-coin-or-re.sol";

contract Finding62490Test is Test {
    function test_exploit_weth_vault_receives_native_eth_and_pays_zero() public {
        Exploit e = new Exploit();
        e.run{value: 10 ether}();
        assertEq(e.vault().lastAssetsWithdrawn(), 0, "weth delta");
        assertEq(address(e.vault()).balance, 10 ether, "stuck eth");
        assertEq(e.weth().balanceOf(address(e)), 0, "user weth");
        assertEq(e.weth().balanceOf(address(e.vault())), 0, "vault weth");
    }

    function test_control_use_eth_false_returns_weth() public {
        WETH w = new WETH();
        CurveV2Pool p = new CurveV2Pool(w);
        CurveConvex2TokenFixed v = new CurveConvex2TokenFixed(w, p);
        w.deposit{value: 10 ether}();
        w.approve(address(v), 10 ether);
        v.deposit(10 ether);
        uint256 got = v.redeem();
        assertEq(got, 10 ether, "paid");
        assertEq(w.balanceOf(address(this)), 10 ether, "user");
        assertEq(address(v).balance, 0, "no stuck eth");
    }
}
