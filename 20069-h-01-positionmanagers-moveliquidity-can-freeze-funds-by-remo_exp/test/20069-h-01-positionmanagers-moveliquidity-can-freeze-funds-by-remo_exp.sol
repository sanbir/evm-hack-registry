// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./20069-h-01-positionmanagers-moveliquidity-can-freeze-funds-by-remo.sol";

contract AjnaMoveLiquidityPartialFreezeTest is Test {
    function test_exploit_partialMoveFreezesResidualLP() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.residualLps(), e.TOTAL_LP() - e.DEPOSIT_AVAILABLE(), "residual LP");
        assertEq(e.movedToLps(), e.DEPOSIT_AVAILABLE(), "moved to toIndex");
        assertTrue(e.fromIndexDropped(), "fromIndex removed from set");
        assertTrue(e.redeemFrozen(), "residual unredeemable");
        assertTrue(e.pm().hasIndex(e.tokenId(), e.TO()), "toIndex tracked");
    }

    function test_control_fullDepositClearsWithoutResidual() public {
        // When deposit >= LP, full move leaves zero residual (still drops fromIndex — correct).
        MockPool pool = new MockPool();
        PositionManager pm = new PositionManager();
        uint256 from = 1;
        uint256 to = 2;
        uint256 lp = 10 ether;
        pool.setBucket(from, lp, 0, 0, lp); // deposit == lp → full move
        pool.setBucket(to, 0, 0, 0, 0);
        pool.setLenderLP(from, address(pm), lp);
        uint256 tokenId = pm.mint(address(pool), address(this));
        pm.seedPosition(tokenId, from, lp, 1);

        pm.moveLiquidity(
            MoveLiquidityParams({tokenId: tokenId, pool: address(pool), fromIndex: from, toIndex: to, expiry: type(uint256).max})
        );
        (uint256 residual,) = pm.getPosition(tokenId, from);
        (uint256 moved,) = pm.getPosition(tokenId, to);
        assertEq(residual, 0, "no residual on full move");
        assertEq(moved, lp, "all moved");
        assertFalse(pm.hasIndex(tokenId, from), "from dropped");
        assertTrue(pm.hasIndex(tokenId, to), "to added");
    }
}
