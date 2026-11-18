// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Pool, Cash, HonestLoan} from
    "./47890-loan-address-validation-ottersec-none-opentrade-pdf.sol";

contract Finding47890Test is Test {
    function test_exploit_fake_prior_loan_drains_the_pool() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stolen(), 1000 ether, "stolen");
        assertEq(e.token().balanceOf(address(e.pool())), 0, "pool");
        assertEq(e.token().balanceOf(e.ADMIN_LOAN()), 1000 ether, "admin loan");
    }

    function test_control_active_loan_check_moves_110() public {
        Cash token = new Cash();
        HonestLoan honest = new HonestLoan();
        Pool pool = new Pool(token, address(this), address(honest));
        token.mint(address(pool), 1000 ether);
        address nextLoan = address(uint160(0xA1));

        require(address(honest) == pool.activeLoan(), "active");
        uint256 amount = pool.calculateRollover(pool.activeLoan());
        pool.initiateRollover(nextLoan, pool.activeLoan());

        assertEq(amount, 110 ether, "honest");
        assertEq(token.balanceOf(nextLoan), 110 ether, "moved");
        assertEq(token.balanceOf(address(pool)), 890 ether, "left");
    }
}
