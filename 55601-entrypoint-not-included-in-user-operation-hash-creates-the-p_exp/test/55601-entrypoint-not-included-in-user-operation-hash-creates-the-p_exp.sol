// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {
    Exploit,
    EntryPoint,
    DGUSD,
    PackedUserOperation,
    IDeleGator,
    Op
} from "./55601-entrypoint-not-included-in-user-operation-hash-creates-the-p.sol";

/// @dev Recommended fix: the typed struct hash includes the executing EntryPoint.
contract FixedDeleGator is IDeleGator {
    DGUSD public immutable token;
    bytes32 public constant FIXED_TYPEHASH = keccak256(
        "PackedUserOperation(address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,address entryPoint)"
    );

    constructor(DGUSD token_) {
        token = token_;
    }

    function digest(PackedUserOperation calldata op, address entryPoint) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                FIXED_TYPEHASH,
                op.sender,
                op.nonce,
                keccak256(op.initCode),
                keccak256(op.callData),
                op.accountGasLimits,
                op.preVerificationGas,
                op.gasFees,
                keccak256(op.paymasterAndData),
                entryPoint
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("EIP7702StatelessDeleGator")),
                keccak256(bytes("1")),
                block.chainid,
                Op.ACCOUNT
            )
        );
        return keccak256(abi.encodePacked(hex"1901", domain, structHash));
    }

    function validateUserOp(PackedUserOperation calldata op) external {
        address signer = _recover(digest(op, msg.sender), op.signature);
        if (signer != Op.ACCOUNT) revert("sig");
        (address to, uint256 amount) = abi.decode(op.callData, (address, uint256));
        if (!token.transfer(to, amount)) revert("transfer");
    }

    function _recover(bytes32 hash, bytes calldata signature) internal pure returns (address) {
        if (signature.length != 65) revert("siglen");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        return ecrecover(hash, v, r, s);
    }
}

contract Finding55601Test is Test {
    uint256 internal constant ALICE_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    bytes32 internal constant DIGEST = 0xace15e2941db2ccac5ece460277467ac54871b0334bfec46f8003720c08f9e1b;

    function setUp() public {
        vm.chainId(1);
    }

    function test_second_entrypoint_replays_signature_and_pays_again() public {
        Exploit e = new Exploit();
        assertEq(e.account().getPackedUserOperationTypedDataHash(e.userOp()), DIGEST, "digest drifted");

        e.run();

        console2.log("paidOnA", e.paidOnA());
        console2.log("replayedOnB", e.replayed());
        console2.log("bobBalance", e.token().balanceOf(Op.BOB));
        console2.log("accountLeft", e.token().balanceOf(address(e.account())));

        assertEq(e.paidOnA(), Op.PAYMENT, "first EntryPoint did not pay 1 DGUSD");
        assertEq(e.replayed(), Op.PAYMENT, "second EntryPoint did not move 1 DGUSD");
        assertEq(e.token().balanceOf(Op.BOB), Op.PAYMENT * 2, "Bob did not receive 2 DGUSD");
        assertEq(e.token().balanceOf(address(e.account())), 0, "account was not debited twice");
        assertEq(e.entryA().nonces(Op.ACCOUNT), 1, "EntryPoint A nonce");
        assertEq(e.entryB().nonces(Op.ACCOUNT), 1, "EntryPoint B nonce");
        assertTrue(address(e.entryA()) != address(e.entryB()), "entry points are the same");
    }

    function test_control_entrypoint_in_hash_reverts_the_replay() public {
        DGUSD token = new DGUSD();
        FixedDeleGator guarded = new FixedDeleGator(token);
        token.mint(address(guarded), Op.PAYMENT * 2);
        EntryPoint a = new EntryPoint(guarded);
        EntryPoint b = new EntryPoint(guarded);

        Exploit e = new Exploit();
        PackedUserOperation memory op = e.userOp();
        bytes32 digest = guarded.digest(op, address(a));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ALICE_PK, digest);
        op.signature = abi.encodePacked(r, s, v);

        a.handleOps(op);
        assertEq(token.balanceOf(Op.BOB), Op.PAYMENT, "authorized payment missing");

        vm.expectRevert(bytes("sig"));
        b.handleOps(op);

        assertEq(token.balanceOf(Op.BOB), Op.PAYMENT, "second execution moved funds");
        assertEq(token.balanceOf(address(guarded)), Op.PAYMENT, "replay debited the account");
        assertEq(b.nonces(Op.ACCOUNT), 0, "reverted replay consumed a nonce");
    }
}
