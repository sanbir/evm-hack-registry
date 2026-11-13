// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, Pool, Token} from "./47332-missing-decimal-correction-ottersec-none-folks-finance-x-cha.sol";

contract Finding47332Test is Test {
    function test_one_dai_borrows_4e11_usdc() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.borrowed(), 4e17, "atomic USDC");
        assertEq(e.fair(), 4e5, "0.4 USDC");
        assertEq(e.cashLeft(), 0, "pool emptied");
        console2.log("borrowed", e.borrowed());
        console2.log("fair", e.fair());
    }

    function test_control_capacity_is_point_four_usdc() public {
        Token dai = new Token(18);
        Token usdc = new Token(6);
        Pool pool = new Pool(address(dai), address(usdc));
        dai.mint(address(this), 1e18);
        usdc.mint(address(pool), 4e17);
        dai.approve(address(pool), 1e18);
        pool.depositCollateral(1e18);

        uint256 fair = pool.fairCapacity(address(this));
        assertEq(fair, 4e5, "0.4 USDC");
        assertEq(usdc.balanceOf(address(pool)), 4e17, "lenders unpaid");
        console2.log("control cap", fair);
    }
}
