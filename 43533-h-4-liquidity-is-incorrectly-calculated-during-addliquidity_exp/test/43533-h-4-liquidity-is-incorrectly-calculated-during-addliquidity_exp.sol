// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, ERC20, SolidlyV3Pool, AMOFixed} from
    "./43533-h-4-liquidity-is-incorrectly-calculated-during-addliquidity.sol";

contract Finding43533Test is Test {
    function test_exploit_inflated_quote_locks_1000_usd() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.quoted(), 4000 ether, "quoted 4000");
        assertEq(e.locked(), 1000 ether, "1000 locked");
        assertEq(e.usd().balanceOf(address(e.amo())), 1000 ether, "amo holds it");
        assertEq(e.usd().balanceOf(address(e.pool())), 1000 ether, "pool did not take it");
    }

    function test_control_amount1_quote_deploys_the_1000_usd() public {
        ERC20 usd = new ERC20("USD");
        ERC20 boost = new ERC20("BOOST");
        SolidlyV3Pool pool = new SolidlyV3Pool(boost, usd);
        AMOFixed amo = new AMOFixed(boost, usd, pool);
        boost.mint(address(this), 3000 ether);
        boost.approve(address(pool), 3000 ether);
        pool.mintUnbalanced(3000 ether);
        usd.mint(address(amo), 1000 ether);
        uint256 liquidity = amo.addLiquidity(1000 ether);
        assertEq(liquidity, 1000 ether, "fair liquidity");
        assertEq(usd.balanceOf(address(amo)), 0, "amo empty");
        assertEq(usd.balanceOf(address(pool)), 2000 ether, "pool received 1000");
    }
}
