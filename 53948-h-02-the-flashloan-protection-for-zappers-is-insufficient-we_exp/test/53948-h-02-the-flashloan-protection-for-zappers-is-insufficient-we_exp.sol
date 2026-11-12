// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Coll,
    Exploit,
    FlashLoanProvider,
    LeverDownTroveParams,
    Trove,
    ZapperFixed
} from "./53948-h-02-the-flashloan-protection-for-zappers-is-insufficient-we.sol";

contract Finding53948Test is Test {
    function test_exploit_unsolicited_flash_loan_extracts_equity() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.taken(), 60, "60 equity extracted");
        assertEq(e.coll().balanceOf(address(this)), 60, "caller received 60");
        assertEq(e.trove().collateral(address(0xBEEF)), 0, "victim trove unwound");
    }

    function test_control_operation_id_blocks_the_flash_loan() public {
        Coll coll = new Coll();
        Trove trove = new Trove(address(coll));
        FlashLoanProvider flash = new FlashLoanProvider();
        ZapperFixed zapper = new ZapperFixed(address(flash), address(trove));
        trove.open(address(0xBEEF), 100, 40);

        bytes memory data = abi.encode(LeverDownTroveParams(address(0xBEEF), address(this)));
        vm.expectRevert(bytes("callback was started by this contract"));
        flash.flashLoan(address(zapper), 40, data);

        assertEq(trove.collateral(address(0xBEEF)), 100, "collateral stayed");
        assertEq(coll.balanceOf(address(this)), 0, "control paid nothing");
        assertEq(zapper.pulled(), 0, "zapper did not take");
    }
}
