// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./20070-h-02-positionmanagers-moveliquidity-can-set-wrong-deposit-ti.sol";

contract AjnaWrongDepositTimeTest is Test {
    function test_exploit_staleDepositTimeFreezesMovedLP() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.toDepositTimeAfterMove(), e.FROM_DEPOSIT_TIME(), "stale time copied");
        assertLe(e.toDepositTimeAfterMove(), e.TO_BANKRUPTCY(), "stale is bankrupt");
        assertEq(e.poolCorrectToTime(), e.TO_BANKRUPTCY() + 1, "pool renewed time");
        assertTrue(e.redeemBricked(), "redeem bricked");
    }

    function test_control_healthyDestinationKeepsRedeemable() public {
        MockPool pool = new MockPool();
        PositionManager pm = new PositionManager();
        uint256 from = 1;
        uint256 to = 2;
        uint256 lp = 10 ether;
        uint256 depositTime = 100;
        pool.setBucket(from, lp, 0, 0, lp);
        pool.setBucket(to, 0, 0, 0, 0); // no bankruptcy on destination
        pool.setLenderLP(from, address(pm), lp, depositTime);
        uint256 tokenId = pm.mint(address(pool), address(this));
        pm.seedPosition(tokenId, from, lp, depositTime);

        pm.moveLiquidity(
            MoveLiquidityParams({tokenId: tokenId, pool: address(pool), fromIndex: from, toIndex: to, expiry: type(uint256).max})
        );
        (, uint256 toDt) = pm.getPosition(tokenId, to);
        assertEq(toDt, depositTime);
        uint256[] memory idxs = new uint256[](1);
        idxs[0] = to;
        // Should NOT revert when destination has no bankruptcy.
        pm.redeemPositions(RedeemPositionsParams({tokenId: tokenId, pool: address(pool), indexes: idxs}));
    }
}
