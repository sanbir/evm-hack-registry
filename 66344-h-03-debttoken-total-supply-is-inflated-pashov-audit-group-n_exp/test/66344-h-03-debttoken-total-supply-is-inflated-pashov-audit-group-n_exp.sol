// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit, DebtToken, LendingPool, RayMath} from "./66344-h-03-debttoken-total-supply-is-inflated-pashov-audit-group-n.sol";

contract FixedDebtToken is DebtToken {
    using RayMath for uint256;
    function mint(address onBehalfOf, uint256 amountScaled, uint256 poolUsageIndex) public override {
        require(msg.sender == _lendingPool, "pool");
        _mint(onBehalfOf, uint256(amountScaled.toUint128()));
        userIndex[onBehalfOf] = poolUsageIndex;
    }
}

contract Finding66344Test is Test {
    function test_exploit_inflated_supply_denies_a_borrow_that_fits() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.debt().totalSupply(), 4100 ether, "reported");
        assertEq(e.pool().realDebt(), 2100 ether, "real");
        assertFalse(e.pool().canBorrow(400 ether), "denied");
        assertTrue(e.pool().realDebt() + 400 ether <= e.pool().supplyCap(), "fits");
    }

    function test_control_principal_only_mint_matches_real_debt() public {
        FixedDebtToken d = new FixedDebtToken();
        LendingPool p = new LendingPool(DebtToken(address(d)));
        d.setLendingPool(address(p));
        p.borrow(address(this), 1000 ether);
        p.accrue(2e27);
        p.borrow(address(this), 100 ether);
        assertEq(d.totalSupply(), 2100 ether, "reported equals real");
        assertEq(p.realDebt(), 2100 ether, "real");
        assertTrue(p.canBorrow(400 ether), "borrow fits");
    }
}
