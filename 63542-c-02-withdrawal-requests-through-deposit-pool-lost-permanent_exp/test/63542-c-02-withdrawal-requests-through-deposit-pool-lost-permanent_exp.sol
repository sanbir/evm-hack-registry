// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    MockERC20,
    ElytraConfig,
    ElytraUnstakingVaultV1,
    ElytraUnstakingVaultV1Fixed,
    ElytraDepositPoolV1,
    ElytraDepositPoolV1Fixed,
    ElytraConstants
} from "./63542-c-02-withdrawal-requests-through-deposit-pool-lost-permanent.sol";

contract WithdrawalRequestLostPermanentlyTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant WITHDRAW_AMOUNT = 6 ether;

    function test_exploit_requestOwnedByPool_userWithdrawalLockedForever() public {
        Exploit e = new Exploit();
        e.run();

        // The vault recorded the DEPOSIT POOL as the request owner, not the user.
        assertEq(e.recordedRequestUser(), e.poolAddr(), "request wrongly owned by the deposit pool");

        // The real user's completeWithdrawal() reverts permanently (msg.sender != request.user).
        assertTrue(e.userCompleteReverted(), "user's completeWithdrawal must revert");

        // 6e18 underlying HYPE is stranded in the vault, unrecoverable by the user.
        assertEq(e.lockedInVault(), WITHDRAW_AMOUNT, "6e18 underlying locked in vault");
        MockERC20 hype = MockERC20(address(ElytraUnstakingVaultV1(e.vaultAddr()).underlying()));
        assertEq(hype.balanceOf(e.vaultAddr()), WITHDRAW_AMOUNT, "vault still holds the locked underlying");

        // The user's elyAsset receipt token was consumed (burned) on request.
        MockERC20 ely = MockERC20(address(ElytraUnstakingVaultV1(e.vaultAddr()).elyAsset()));
        assertEq(ely.totalSupply(), 0, "elyAsset burned: user has nothing left to redeem");

        // Locked magnitude recorded on the marker at the SINK.
        MockERC20 marker = MockERC20(e.markerAddr());
        assertEq(marker.balanceOf(SINK), WITHDRAW_AMOUNT, "marker records 6e18 locked at SINK");
    }

    function test_control_fixedRecordsRealUser_completeSucceeds() public {
        address user = address(0xBEEF);

        MockERC20 ely = new MockERC20("Elytra HYPE", "elyHYPE");
        MockERC20 hype = new MockERC20("Hyperliquid", "HYPE");
        ElytraConfig config = new ElytraConfig();
        ElytraUnstakingVaultV1Fixed vault = new ElytraUnstakingVaultV1Fixed(address(ely), address(hype));
        ElytraDepositPoolV1Fixed pool = new ElytraDepositPoolV1Fixed(address(config));

        config.setElyAsset(address(ely));
        config.setContract(ElytraConstants.ELYTRA_UNSTAKING_VAULT, address(vault));
        pool.setSupportedAsset(address(hype), true);

        hype.mint(address(vault), WITHDRAW_AMOUNT);
        ely.mint(user, WITHDRAW_AMOUNT);

        vm.startPrank(user);
        ely.approve(address(pool), WITHDRAW_AMOUNT);
        uint256 requestId = pool.requestWithdrawal(address(hype), WITHDRAW_AMOUNT);

        // FIX records the real user as the owner.
        (address recordedUser,,,,,) = vault.withdrawalRequests(requestId);
        assertEq(recordedUser, user, "fixed vault records the real user");

        // The user completes their own withdrawal and receives the assets.
        uint256 paid = vault.completeWithdrawal(requestId);
        vm.stopPrank();

        assertEq(paid, WITHDRAW_AMOUNT, "user completes and is paid");
        assertEq(hype.balanceOf(user), WITHDRAW_AMOUNT, "user recovered the underlying");
        assertEq(hype.balanceOf(address(vault)), 0, "vault paid out fully, nothing locked");
    }
}
