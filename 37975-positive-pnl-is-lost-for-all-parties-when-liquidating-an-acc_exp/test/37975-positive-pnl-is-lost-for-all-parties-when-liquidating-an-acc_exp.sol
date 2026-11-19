// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, USDZ, EngineFixed} from
    "./37975-positive-pnl-is-lost-for-all-parties-when-liquidating-an-acc.sol";

contract Finding37975Test is Test {
    address internal constant USER = 0x2222222222222222222222222222222222222222;
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_discards_300_pnl_and_pays_only_collateral() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.engine().collateral(USER), 0, "account emptied");
        assertEq(e.usdz().balanceOf(address(e)), 900 ether, "liquidator received 900");
        assertEq(e.marker().balanceOf(SINK), 300 ether, "300 pnl lost");
    }

    function test_control_mints_pnl_then_pays_maintenance() public {
        USDZ usdz = new USDZ();
        EngineFixed engine = new EngineFixed(usdz);
        usdz.mint(address(engine), 900 ether);
        engine.seed(USER, 900 ether, int256(300 ether), 1100 ether);
        engine.liquidate(USER);
        assertEq(engine.collateral(USER), 100 ether, "100 remains");
        assertEq(usdz.balanceOf(address(this)), 1100 ether, "liquidator receives 1100");
        assertEq(engine.unrealizedPnl(USER), 0, "pnl was minted onto collateral");
    }
}
