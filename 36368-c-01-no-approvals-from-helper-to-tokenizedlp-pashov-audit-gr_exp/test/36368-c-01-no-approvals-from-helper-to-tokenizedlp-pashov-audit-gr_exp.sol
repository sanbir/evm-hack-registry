// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    HelperFixed,
    TokenizedLp,
    Weth
} from "./36368-c-01-no-approvals-from-helper-to-tokenizedlp-pashov-audit-gr.sol";

contract Finding36368Test is Test {
    function test_exploit_zap_reverts_and_weth_stays() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.zapReverted(), "deposit reverted");
        assertEq(e.kept(), 100 ether, "100 WETH stayed with the caller");
        assertEq(e.lpMinted(), 0, "caller received 0 LP");
        assertEq(e.weth().balanceOf(address(e.helper())), 0, "helper did not keep WETH");
        assertEq(e.helper().allowanceToLp(), 0, "helper never approved TokenizedLp");
    }

    function test_control_approval_mints_lp_to_the_caller() public {
        Weth weth = new Weth();
        TokenizedLp lp = new TokenizedLp(weth);
        HelperFixed helper = new HelperFixed(weth, lp, address(this));

        weth.mint(address(this), 100 ether);
        weth.approve(address(helper), 100 ether);
        uint256 liquidity = helper.zapWETH(100 ether);

        assertEq(liquidity, 100 ether, "deposit returned the LP amount");
        assertEq(lp.balanceOf(address(this)), 100 ether, "caller received 100 LP");
        assertEq(weth.balanceOf(address(this)), 0, "caller WETH was taken");
        assertEq(weth.balanceOf(address(lp)), 100 ether, "TokenizedLp holds the WETH");
        assertEq(weth.balanceOf(address(helper)), 0, "helper is empty");
    }
}
