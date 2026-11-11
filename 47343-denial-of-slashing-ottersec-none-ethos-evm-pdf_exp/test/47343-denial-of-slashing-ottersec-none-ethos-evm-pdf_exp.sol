// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, ServiceManager, MockToken} from "./47343-denial-of-slashing-ottersec-none-ethos-evm-pdf.sol";

contract DenialOfSlashingTest is Test {
    address internal constant TREASURY = 0x0000000000000000000000000000000000000eE1;
    address internal constant OPERATOR = 0x0000000000000000000000000000000000000a11;
    uint256 internal constant N = 1000 ether;

    function test_exploit_griefedSlashRevertsAndStakeStays() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.entries(), 6, "delegatedValidators length");
        assertFalse(e.slashOk(), "slash should revert");
        assertEq(e.revertBytes(), 0, "out-of-gas return data is empty");
        assertEq(e.kept(), N, "offender did not keep N");
        assertEq(e.stakeToken().balanceOf(e.OFFENDER()), N, "stake token left the offender");
        assertEq(e.paidToTreasury(), 0, "treasury was paid");
        assertEq(e.mgr().slashedAmount(), 0, "slashed amount was recorded");
    }

    function test_control_oneDelegationSlashesN() public {
        MockToken token = new MockToken("Stake", "STAKE");
        ServiceManager mgr = new ServiceManager(address(token), OPERATOR, address(this), TREASURY, 8);
        token.mint(address(this), N);
        token.approve(address(mgr), N);
        mgr.updateDelegation("ethos-validator-pubkey");

        (bool ok, bytes memory ret) = mgr.attemptSlash("ethos-validator-pubkey");

        assertTrue(ok, "short slash failed");
        assertEq(ret.length, 0, "successful slash returned data");
        assertEq(token.balanceOf(address(this)), 0, "offender kept stake");
        assertEq(token.balanceOf(TREASURY), N, "treasury did not receive N");
        assertEq(mgr.slashedAmount(), N, "slashed amount");
    }

    function test_control_lengthCapRejectsFurtherDelegations() public {
        MockToken token = new MockToken("Stake", "STAKE");
        ServiceManager mgr = new ServiceManager(address(token), OPERATOR, address(this), TREASURY, 8);
        for (uint256 i = 0; i < 8; i++) {
            mgr.updateDelegation("ethos-validator-pubkey");
        }
        vm.expectRevert(bytes("length cap"));
        mgr.updateDelegation("ethos-validator-pubkey");
        assertEq(mgr.delegatedCount(), 8, "cap did not hold");
    }
}
