// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    VaultEscrowFixed,
    Token
} from "./61456-h-03-incorrect-erc20-transfer-implementation-between-evm-and.sol";

contract Finding61456Test is Test {
    address constant LEGACY = 0x2222222222222222222222222222222222222222;
    address constant CORE = 0x20000000000000000000000000000000000000C8;

    function test_exploit_sends_N_to_the_legacy_bridge() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.token().balanceOf(LEGACY), e.N(), "1000 USDC went to 0x2222");
        assertEq(e.token().balanceOf(CORE), 0, "token-index address got nothing");
        assertEq(e.escrow().HYPERLIQUID_SPOT_BRIDGE(), LEGACY, "constant is the legacy bridge");
    }

    function test_control_sends_N_to_the_token_system_address() public {
        Token token = new Token("USD Coin", "USDC", 6);
        VaultEscrowFixed escrow = new VaultEscrowFixed(token);
        assertEq(escrow.systemAddress(200), CORE, "index 200 encodes 0x2000...00c8");
        token.mint(address(escrow), 1_000_000_000);
        escrow.deposit(1_000_000_000);

        assertEq(token.balanceOf(CORE), 1_000_000_000, "control sends N to the core address");
        assertEq(token.balanceOf(LEGACY), 0, "legacy bridge receives nothing");
        assertEq(token.balanceOf(address(escrow)), 0, "escrow is empty");
    }
}
