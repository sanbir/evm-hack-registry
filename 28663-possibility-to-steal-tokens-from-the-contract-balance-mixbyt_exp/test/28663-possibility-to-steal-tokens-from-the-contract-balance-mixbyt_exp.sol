// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Collateral,
    CoverRouterFixed,
    Depositor,
    Exploit
} from "./28663-possibility-to-steal-tokens-from-the-contract-balance-mixbyt.sol";

contract HonestProtocol {
    function addCover(uint256) external pure returns (bool) {
        return true;
    }
}

contract Finding28663Test is Test {
    function test_unlimited_approve_drains_the_router() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stolen(), 1000 ether, "attacker holds N");
        assertEq(e.routerLeft(), 0, "router balance is 0");
        assertEq(e.depositorLeft(), 0, "depositor lost 1000");
        assertEq(e.allowanceToAttacker(), type(uint256).max, "allowance is max");
    }

    function test_control_refunds_when_addCover_returns_false() public {
        Collateral token = new Collateral();
        HonestProtocol honest = new HonestProtocol();
        CoverRouterFixed router = new CoverRouterFixed(token, address(honest));
        Depositor depositor = new Depositor(token);
        token.mint(address(depositor), 1000 ether);
        // Attacker protocol is not the allowed one, and a false addCover cannot keep funds.
        (bool ok,) = address(depositor).call(
            abi.encodeWithSelector(depositor.fundAndBuy.selector, router, address(this), 1000 ether)
        );
        assertTrue(!ok, "unchecked protocol is rejected");
        assertEq(token.balanceOf(address(depositor)), 1000 ether, "depositor still holds N");
        assertEq(token.balanceOf(address(router)), 0, "router stays empty");
        assertEq(token.balanceOf(address(this)), 0, "attacker received nothing");
    }
}
