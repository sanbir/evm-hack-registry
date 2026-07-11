// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @notice Minimal ERC20 interface for asset token operations
interface IERC20 {
    /// @notice Get balance of an account
    function balanceOf(address account) external view returns (uint256);
    /// @notice Transfer tokens
    function transfer(address to, uint256 value) external returns (bool);
    /// @notice Transfer approved tokens
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    /// @notice Approve token spending
    function approve(address spender, uint256 value) external returns (bool);
    /// @notice Get token decimals
    function decimals() external view returns (uint8);
}

interface IUniswapV3PoolMinimal {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function slot0() external view returns (
        uint160 sqrtPriceX96, int24 tick,
        uint16, uint16, uint16, uint8, bool
    );
}

/// @notice Uniswap SwapRouter02 (chain-specific, set at deploy)
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut);
}

/// @notice Minimal interface for Uniswap V3 strategy contract
interface IStrategyUniswapV3 {
    /// @notice Set the Vault address
    function setVault(address vault_) external;
    /// @notice Set strategy parameters (pool, range, etc.)
    function setParams(address pool_, uint24 feeTier_, int24 tickLower_, int24 tickUpper_, uint16 slippageBps_, uint32 twapWindowSeconds_) external;
    /// @notice Mint a Uniswap V3 position with the specified amounts
    function mintPosition(uint256 amount0Desired, uint256 amount1Desired) external returns (uint256 liquidity);
    /// @notice Collect accumulated fees
    function collectFees() external returns (uint256 amount0, uint256 amount1);
    /// @notice Rebalance to a new tick range
    function rebalance(int24 newTickLower, int24 newTickUpper, uint256 amount0Min, uint256 amount1Min)
        external
        returns (uint256 liquidity);
    /// @notice Withdraw liquidity and send to Vault
    function withdrawToVault(uint128 liquidity, uint256 amount0Min, uint256 amount1Min)
        external
        returns (uint256 amount0, uint256 amount1);
    /// @notice Get current liquidity
    function currentLiquidity() external view returns (uint128);
    /// @notice Return token0/token1 balances held by Strategy
    function getBalances() external view returns (uint256 amount0, uint256 amount1);
    /// @notice Emergency withdraw: unwinds LP and sends ALL tokens to the Vault.
    /// @dev    `to` must equal the registered vault address; the Strategy reverts otherwise.
    function emergencyWithdraw(address to) external returns (uint256 amount0, uint256 amount1);
    /// @notice Transfer specified token to any address (used for fee distribution)
    function sweepToken(address token, uint256 amount, address to) external;
    /// @notice Return idle (un-minted) tokens to Vault
    function sweepIdleToVault() external;
    /// @notice Add idle balance as liquidity to existing position (for compounding)
    function addLiquidity() external returns (uint128 addedLiquidity, uint256 amount0, uint256 amount1);
    /// @notice Unpause the contract
    function unpause() external;
}

/**
 * @title Vault4626
 * @notice ERC4626-like Vault skeleton that executes Uniswap V3 strategies
 * @dev Pricing is determined off-chain by the Keeper; on-chain only performs guarded execution
 */
import {VaultMathLib} from "./VaultMathLib.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IRoleHub, DEFAULT_ADMIN_ROLE, UPGRADER_ROLE, KEEPER_ROLE} from "./access/RoleHub.sol";

contract Vault4626 is UUPSUpgradeable {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;

    /// @notice ERC4626 inflation attack mitigation: virtual offset for convertToShares/convertToAssets
    /// @dev Prevents exchange rate manipulation via donation after a 1 wei deposit
    uint256 private constant _DEAD_SHARES = 1e6; // 6dec USDC: ~1 USDC equivalent; 18dec WETH: sufficient attack cost
    // --- Roles ---
    /// @notice Admin address
    address public admin;
    /// @notice Keeper (operator) address
    address public keeper;

    // --- Asset / Shares ---
    /// @notice Underlying asset token
    IERC20 public asset;
    /// @notice Total shares issued
    uint256 public totalSupply;
    /// @notice Share balance per address
    mapping(address => uint256) public balanceOf;

    // --- Strategy Params ---
    /// @notice Target pool
    address public pool;
    /// @notice Fee tier
    uint24 public feeTier;
    /// @notice Lower tick
    int24 public tickLower;
    /// @notice Upper tick
    int24 public tickUpper;
    /// @notice Range width in bps
    uint16 public rangeBps;
    /// @notice Allowed slippage in bps
    uint16 public slippageBps;
    /// @notice Allowed slippage in bps for redeem
    uint16 public redeemSlippageBps;
    /// @notice Rebalance cooldown in seconds
    uint32 public cooldownSeconds;
    /// @notice Timestamp of last rebalance
    uint256 public lastRebalanceAt;
    /// @notice Strategy contract
    address public strategy;
    /// @notice TWAP observation window (seconds)
    uint32 public twapWindowSeconds;

    // --- Safety ---
    /// @notice Pause flag
    bool public paused;

    // --- Daily Limits ---
    // (removed — now enforced off-chain by the keeper for contract-size reasons)

    // --- Performance Fee ---
    /// @notice Performance fee rate (bps, max 3000 = 30%)
    uint16 public performanceFeeBps;
    /// @notice Fee recipient address
    address public feeRecipient;

    // --- Referral ---
    /// @notice Referral fee rates per level [L1, L2, L3] (bps)
    uint16[3] public referralFeeBps;
    /// @notice User -> direct referrer
    mapping(address => address) public referrer;
    /// @notice referrer -> total shares of L1 referees
    mapping(address => uint256) public level1Shares;
    /// @notice referrer -> total shares of L2 referees
    mapping(address => uint256) public level2Shares;
    /// @notice referrer -> total shares of L3 referees
    mapping(address => uint256) public level3Shares;
    /// @notice List of all referrers (for batch distribution)
    address[] private _referrerList;
    /// @notice Referrer deduplication flag
    mapping(address => bool) private _isReferrer;
    /// @notice Pending token0 referral fees
    uint256 public pendingReferralFees0;
    /// @notice Pending token1 referral fees
    uint256 public pendingReferralFees1;

    // --- Events (MVP required + operational) ---
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event WithdrawNonAsset(address indexed receiver, address indexed token, uint256 amount);
    event MintPosition(address indexed pool, int24 tickLower, int24 tickUpper, uint256 liquidity);
    event CollectFees(address indexed pool, uint256 amount0, uint256 amount1);
    event Rebalance(address indexed pool, int24 tickLower, int24 tickUpper, uint256 liquidity);
    event Paused(address indexed caller);
    event Unpaused(address indexed caller);
    event EmergencyWithdraw(address indexed caller, address indexed to, uint256 amount0, uint256 amount1);
    event StrategyParamsUpdated(
        address indexed pool,
        uint24 feeTier,
        int24 tickLower,
        int24 tickUpper,
        uint16 rangeBps,
        uint16 slippageBps,
        uint32 cooldownSeconds
    );
    event KeeperUpdated(address indexed newKeeper);
    event AdminUpdated(address indexed newAdmin);
    event StrategyUpdated(address indexed newStrategy);
    event RoleHubSet(address indexed roleHub);
    event StrategyFunded(address indexed token0, address indexed token1, uint256 amount0, uint256 amount1);
    event StrategyWithdrawn(uint256 amount0, uint256 amount1);
    event TwapWindowUpdated(uint32 secondsAgo);
    event RedeemSlippageUpdated(uint16 slippageBps);
    event PerformanceFeeUpdated(uint16 feeBps, address indexed recipient);
    event PerformanceFeePaid(uint256 amount0, uint256 amount1, address indexed recipient);
    event SystemFeePaid(uint256 amount0, uint256 amount1, address indexed recipient);
    event VaultTokenSwapped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event Compound(address indexed pool, int24 tickLower, int24 tickUpper, uint128 addedLiquidity, uint256 amount0, uint256 amount1);
    event ReferrerSet(address indexed user, address indexed referrer_);
    event ReferralFeesAccrued(uint256 amount0, uint256 amount1);
    event ReferralFeePaid(address indexed referrer_, uint256 amount0, uint256 amount1);
    event ReferralFeeBpsUpdated(uint16[3] bps);
    event ReferralDistributionStarted(uint256 reserved0, uint256 reserved1);
    event ReferralDistributionEnded(uint256 returnedToPending0, uint256 returnedToPending1);

    // --- Errors ---
    error NotAuthorized();
    error PausedError();
    error CooldownActive();
    error InvalidParams();
    error Reentrancy();
    /// @notice Admin only — pre-V2 falls back to legacy `admin` var.
    modifier onlyAdmin() {
        _checkAdmin();
        _;
    }

    /// @notice Keeper or admin only — pre-V2 falls back to legacy `admin`/`keeper`.
    modifier onlyKeeperOrAdmin() {
        _checkKeeperOrAdmin();
        _;
    }

    /// @notice Role-gated (post-V2 only — reverts pre-V2 since roleHub is unset).
    modifier onlyRole(bytes32 role) {
        if (!IRoleHub(roleHub).hasRole(role, msg.sender)) revert NotAuthorized();
        _;
    }

    /// @dev De-duplicated permission helpers — kept private so the compiler
    ///      can avoid inlining (saves bytecode at every modifier call site).
    function _checkAdmin() private view {
        address h = roleHub;
        if (h == address(0)) {
            if (msg.sender != admin) revert NotAuthorized();
        } else {
            if (!IRoleHub(h).hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotAuthorized();
        }
    }

    function _checkKeeperOrAdmin() private view {
        address h = roleHub;
        if (h == address(0)) {
            if (msg.sender != admin && msg.sender != keeper) revert NotAuthorized();
        } else {
            IRoleHub r = IRoleHub(h);
            if (!r.hasRole(KEEPER_ROLE, msg.sender) && !r.hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
                revert NotAuthorized();
            }
        }
    }


    /// @notice Reverts when paused
    modifier whenNotPaused() {
        if (paused) revert PausedError();
        _;
    }

    /// @notice Prevents reentrancy
    modifier nonReentrant() {
        if (_status == _ENTERED) revert Reentrancy();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {}

    bool private _initialized;

    /// @notice Initialize the Vault (called once via proxy)
    function initialize(address asset_, address admin_, address swapRouter_, uint16 systemFeeBps_, address systemFeeRecipient_) external {
        if (_initialized) revert InvalidParams();
        _initialized = true;
        if (asset_ == address(0) || admin_ == address(0) || swapRouter_ == address(0)) revert InvalidParams();
        if (systemFeeBps_ > 1000) revert InvalidParams(); // max 10%
        if (systemFeeBps_ > 0 && systemFeeRecipient_ == address(0)) revert InvalidParams();
        asset = IERC20(asset_);
        admin = admin_;
        SWAP_ROUTER = swapRouter_;
        systemFeeBps = systemFeeBps_;
        systemFeeRecipient = systemFeeRecipient_;
        referrer[admin_] = admin_;
        _isReferrer[admin_] = true;
        _referrerList.push(admin_);
    }

    /// @notice UUPS: only admin (legacy) or UPGRADER_ROLE holder (Hub) can upgrade.
    /// @dev    Backward compat: if roleHub is unset (pre-V2), falls back to legacy
    ///         admin EOA check. Post-V2: only UPGRADER_ROLE holder via Hub.
    function _authorizeUpgrade(address) internal view override {
        if (roleHub != address(0)) {
            if (!IRoleHub(roleHub).hasRole(UPGRADER_ROLE, msg.sender)) revert NotAuthorized();
            return;
        }
        if (msg.sender != admin) revert NotAuthorized();
    }

    /// @notice V2 reinitializer — wires this proxy to a RoleHub.
    /// @dev    Atomic via `upgradeToAndCall(newImpl, encodeCall(reinitV2_setRoleHub, hub))`.
    ///         Caller must be the legacy `admin` EOA. After this completes:
    ///           - `_initializedV2` flag set true (idempotency)
    ///           - `roleHub` points to the hub
    ///           - All future role checks dispatch through the hub
    ///         The legacy `admin` var stays as-is (read-only compat); to retire
    ///         legacy fallback after a stable observation period, deploy a
    ///         second impl that doesn't read `admin` in modifiers.
    function reinitializeV2_setRoleHub(address newRoleHub) external {
        if (_initializedV2) revert InvalidParams();
        if (msg.sender != admin) revert NotAuthorized();
        if (newRoleHub == address(0)) revert InvalidParams();
        _initializedV2 = true;
        roleHub = newRoleHub;
        emit RoleHubSet(newRoleHub);
    }

    // --- ERC4626-like Surface (skeleton) ---
    // NOTE: This is intentionally minimal and omits ERC20 allowance/transfer
    //       logic for shares. Add full ERC4626 compliance later.
    /// @notice Deposit assets and receive shares
    /// @dev ERC20 share transfer is not implemented in MVP
    function deposit(uint256 assets, address receiver) external whenNotPaused nonReentrant returns (uint256 shares) {
        if (assets == 0 || receiver == address(0)) revert InvalidParams();
        if (totalSupply > 0 && totalAssets() == 0) revert InvalidParams();
        shares = convertToShares(assets);
        if (shares == 0) revert InvalidParams();
        bool ok = asset.transferFrom(msg.sender, address(this), assets);
        if (!ok) revert InvalidParams();
        totalSupply += shares;
        balanceOf[receiver] += shares;
        // [FRB fix] Only the depositor may establish their OWN referrer (msg.sender == receiver).
        // A third party depositing on behalf of `receiver` must not be able to bind that
        // account's permanent referrer. Admin can still set it later via setReferrerAdmin.
        if (msg.sender == receiver && referrer[receiver] == address(0)) {
            referrer[receiver] = admin;
            emit ReferrerSet(receiver, admin);
        }
        _updateReferralShares(receiver, shares, true);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Deposit with a specified referrer
    function depositWithReferral(uint256 assets, address receiver, address referrer_)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0 || receiver == address(0)) revert InvalidParams();
        if (totalSupply > 0 && totalAssets() == 0) revert InvalidParams();
        shares = convertToShares(assets);
        if (shares == 0) revert InvalidParams();
        bool ok = asset.transferFrom(msg.sender, address(this), assets);
        if (!ok) revert InvalidParams();
        totalSupply += shares;
        balanceOf[receiver] += shares;
        // [FRB fix] Only the depositor may establish their OWN referrer (msg.sender == receiver),
        // preventing a third party from front-running a victim's first deposit to bind an
        // attacker-chosen referrer. Third-party deposits still succeed (referrer left unset).
        if (msg.sender == receiver && referrer[receiver] == address(0)) {
            if (referrer_ == address(0) || referrer_ == receiver) revert InvalidParams();
            // referrer_ must be a member (has referrer set)
            if (referrer[referrer_] == address(0)) revert InvalidParams();
            // Circular reference check (3 hops)
            if (referrer[referrer_] == receiver) revert InvalidParams();
            address ref2 = referrer[referrer_];
            if (ref2 != address(0)) {
                if (referrer[ref2] == receiver) revert InvalidParams();
                address ref3 = referrer[ref2];
                if (ref3 != address(0) && referrer[ref3] == receiver) revert InvalidParams();
            }
            referrer[receiver] = referrer_;
            if (!_isReferrer[referrer_]) {
                _isReferrer[referrer_] = true;
                _referrerList.push(referrer_);
            }
            emit ReferrerSet(receiver, referrer_);
        }
        _updateReferralShares(receiver, shares, true);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Redeem shares and receive assets
    /// @dev Only callable by the owner.
    ///      With LP: calculates USDC via TWAP (optimizes withdrawal if LP is sufficient)
    ///      Without LP: sweeps Strategy idle to Vault and returns USDC + WETH proportionally based on actual balance
    function redeem(uint256 shares, address receiver, address owner)
        external
        nonReentrant
        returns (uint256 assets)
    {
        // Intentionally NOT gated by whenNotPaused: users can always redeem their
        // proportional assets even while the Vault is paused. Withdrawals cannot be
        // blocked by the operator.
        if (shares == 0 || receiver == address(0) || owner == address(0)) revert InvalidParams();
        if (owner != msg.sender) revert NotAuthorized();
        if (balanceOf[owner] < shares) revert InvalidParams();

        // 1) Calculate expected USDC amount based on TWAP
        assets = convertToAssets(shares);

        // 2) Withdraw from Strategy
        uint128 liq = _liquidityToWithdraw(shares);
        bool idleOnlyRedeem = false;
        uint256 nonAssetToSend = 0;
        address nonAssetToken;

        if (liq > 0) {
            _collectPerformanceFees();
            // Temporarily store fee WETH balance in nonAssetToSend (reused later in step 6).
            // MUST use _availableBalance (excludes pendingReferralFees), NOT raw balanceOf:
            // step 6 computes _lpNa = _availableBalance(after) - this snapshot. If the snapshot
            // were the raw balance (incl. pendingReferralFees) while _naBal nets it out, then
            // _lpNa = withdrawnLP - pendingReferralFees, so a small redeemer whose withdrawn LP
            // is <= the pending referral reserve gets ~0 of their LP-origin non-asset (it stays
            // stranded in the Vault). Using _availableBalance on both sides cancels the reserve.
            if (pool != address(0)) {
                address _t0 = IUniswapV3PoolMinimal(pool).token0();
                nonAssetToken = address(asset) == _t0 ? IUniswapV3PoolMinimal(pool).token1() : _t0;
                nonAssetToSend = _availableBalance(nonAssetToken);
            }
            if (_availableBalance(address(asset)) < assets || assets == 0) {
                {
                    (uint256 b0, uint256 b1) = IStrategyUniswapV3(strategy).getBalances();
                    (uint256 m0, uint256 m1) = _computeWithdrawMinsByShare(shares, b0, b1);
                    try IStrategyUniswapV3(strategy).withdrawToVault(liq, m0, m1) returns (uint256, uint256) {}
                    catch { _withdrawFromStrategyInternal(liq, 0, 0); }
                }
            }
            if (_availableBalance(address(asset)) < assets || assets == 0) {
                assets = _availableBalance(address(asset));
                idleOnlyRedeem = true;
            }
        } else if (strategy != address(0)) {
            _collectPerformanceFees();
            IStrategyUniswapV3(strategy).sweepIdleToVault();
            assets = totalSupply > 0 ? (_availableBalance(address(asset)) * shares) / totalSupply : 0;
            // After pause() the LP is unwound back into the Vault, so the Vault holds
            // both token0 and token1. The non-asset token (e.g. WETH) must be paid out
            // pro-rata from idle balance at the same ratio as the asset; otherwise the
            // redeemer's non-asset share is stranded in the Vault and permanently locked.
            if (pool != address(0) && totalSupply > 0) {
                address _t0 = IUniswapV3PoolMinimal(pool).token0();
                nonAssetToken = address(asset) == _t0 ? IUniswapV3PoolMinimal(pool).token1() : _t0;
                nonAssetToSend = (_availableBalance(nonAssetToken) * shares) / totalSupply;
            }
            idleOnlyRedeem = true;
        }

        // 4) Update referral share totals & burn shares
        _updateReferralShares(owner, shares, false);
        balanceOf[owner] -= shares;
        totalSupply -= shares;

        // 5) Transfer USDC
        if (_availableBalance(address(asset)) < assets) revert InvalidParams();
        if (assets > 0) {
            bool ok = asset.transfer(receiver, assets);
            if (!ok) revert InvalidParams();
        }

        // 6) Transfer non-asset (WETH)
        if (liq == 0) {
            // Idle-only redeem (liq==0, including the post-pause case): nonAssetToSend
            // was already computed pro-rata from idle balance in the liq==0 branch above.
            // Do not recompute it here.
        } else if (idleOnlyRedeem && nonAssetToken != address(0)) {
            // liq>0 that fell through to the idle fallback: nonAssetToSend holds the
            // fee-WETH snapshot set in step 2. Separate LP-origin WETH from fee-origin WETH.
            uint256 _feeNa = nonAssetToSend; // snapshot: fee WETH (belongs to all → proportional)
            uint256 _naBal = _availableBalance(nonAssetToken);
            uint256 _lpNa = _naBal > _feeNa ? _naBal - _feeNa : 0; // LP WETH (already proportional)
            // Guard on _feeNa only: the divisor (totalSupply + shares) reconstructs the
            // pre-burn supply and is always >= shares >= 1, so the last redeemer
            // (post-burn totalSupply == 0) still receives their fee-WETH share.
            uint256 _feeShare = _feeNa > 0 ? (_feeNa * shares) / (totalSupply + shares) : 0;
            nonAssetToSend = _lpNa + _feeShare;
        } else {
            nonAssetToSend = 0;
        }
        if (nonAssetToSend > 0 && nonAssetToken != address(0)) {
            _safeTransfer(nonAssetToken, receiver, nonAssetToSend);
            emit WithdrawNonAsset(receiver, nonAssetToken, nonAssetToSend);
        }

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @notice Return total assets of the Vault
    /// @dev In addition to Strategy LP value + idle, also adds non-asset tokens (e.g. WETH)
    ///      in the Vault converted via TWAP. Prevents TVL from appearing lower than actual
    ///      when non-asset tokens remain in Vault after pause or during rebalance.
    function totalAssets() public view returns (uint256) {
        uint256 idle = asset.balanceOf(address(this));
        if (strategy == address(0) || pool == address(0)) {
            return idle;
        }

        (uint256 amount0, uint256 amount1) = IStrategyUniswapV3(strategy).getBalances();
        address token0 = IUniswapV3PoolMinimal(pool).token0();
        address token1 = IUniswapV3PoolMinimal(pool).token1();
        // [USI fix] twapWindowSeconds == 0 → spot pricing (consistent with the strategy's
        // spot-pricing mode); otherwise TWAP. Previously this returned idle-only when twap==0,
        // excluding live LP/non-asset value and underpricing share issuance (convertToShares).
        // _consultTwap(0) would divide-by-zero, so read slot0 spot tick directly.
        int24 tick;
        if (twapWindowSeconds > 0) {
            tick = _consultTwap(twapWindowSeconds);
        } else {
            (, int24 spotTick,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
            tick = spotTick;
        }

        bool isToken0 = address(asset) == token0;
        if (!isToken0 && address(asset) != token1) return idle;

        // [RSNR fix] exclude both live pending fees and the in-flight distribution snapshot
        // from TVL so reserved referral funds are not counted as vault assets (share price).
        uint256 pendingAsset    = (isToken0 ? pendingReferralFees0 : pendingReferralFees1)
                                + (isToken0 ? snapshotPending0 : snapshotPending1);
        uint256 pendingNonAsset = (isToken0 ? pendingReferralFees1 : pendingReferralFees0)
                                + (isToken0 ? snapshotPending1 : snapshotPending0);
        uint256 assetInLP       = isToken0 ? amount0 : amount1;
        uint256 nonAssetInLP    = isToken0 ? amount1 : amount0;
        address nonAssetToken   = isToken0 ? token1 : token0;

        if (pendingAsset > 0 && idle >= pendingAsset) idle -= pendingAsset;
        uint256 quoted = nonAssetInLP > 0 ? VaultMathLib.getQuoteAtTick(tick, nonAssetInLP, nonAssetToken, address(asset)) : 0;
        uint256 vaultNonAsset = IERC20(nonAssetToken).balanceOf(address(this));
        if (pendingNonAsset > 0 && vaultNonAsset >= pendingNonAsset) vaultNonAsset -= pendingNonAsset;
        uint256 vaultNonAssetQuoted = vaultNonAsset > 0 ? VaultMathLib.getQuoteAtTick(tick, vaultNonAsset, nonAssetToken, address(asset)) : 0;
        return idle + assetInLP + quoted + vaultNonAssetQuoted;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return (assets * (totalSupply + _DEAD_SHARES)) / (totalAssets() + _DEAD_SHARES);
    }
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return (shares * (totalAssets() + _DEAD_SHARES)) / (totalSupply + _DEAD_SHARES);
    }

    // --- Admin / Keeper Controls ---
    /// @notice Update the Keeper address
    function setKeeper(address newKeeper) external onlyAdmin {
        if (newKeeper == address(0)) revert InvalidParams();
        keeper = newKeeper;
        emit KeeperUpdated(newKeeper);
    }

    /// @notice Update the admin address (legacy var only — post-V2, this does NOT
    ///         change DEFAULT_ADMIN_ROLE on the Hub. Use Hub.grantRole/revokeRole
    ///         to actually transfer admin authority. Provided for legacy ABI compat.
    /// @dev    For autoLP fork: admin should call Hub.grantRole(DEFAULT_ADMIN, newAdmin)
    ///         then Hub.revokeRole(DEFAULT_ADMIN, oldAdmin) instead of this function.
    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert InvalidParams();
        admin = newAdmin;
        emit AdminUpdated(newAdmin);
    }

    /// @notice Update the TWAP observation window
    function setTwapWindowSeconds(uint32 secondsAgo) external onlyAdmin {
        twapWindowSeconds = secondsAgo;
        emit TwapWindowUpdated(secondsAgo);
    }

    /// @notice Update the redeem slippage tolerance
    /// @dev 0 for strict, max 10000
    function setRedeemSlippageBps(uint16 bps) external onlyAdmin {
        if (bps > 10_000) revert InvalidParams();
        redeemSlippageBps = bps;
        emit RedeemSlippageUpdated(bps);
    }

    /// @notice Set performance fee rate and recipient address
    function setPerformanceFee(uint16 feeBps_, address recipient_) external onlyAdmin {
        if (feeBps_ > 5000) revert InvalidParams(); // max 50%
        // [MZAC — Acknowledged] recipient_ == 0 with feeBps_ > 0 is an INTENTIONAL
        // "performance fee disabled" mode: _collectPerformanceFees() skips the transfer
        // when feeRecipient == 0, so fees are never sent to a dead sink (they stay in the
        // Vault for shareholders). Enforcing recipient != 0 here would break that mode.
        performanceFeeBps = feeBps_;
        feeRecipient = recipient_;
        emit PerformanceFeeUpdated(feeBps_, recipient_);
    }

    /// @notice Update the strategy contract
    /// @dev strategy.setVault() is onlyAdmin, so call it directly from Deploy.s.sol
    function setStrategy(address newStrategy) external onlyAdmin {
        if (newStrategy == address(0)) revert InvalidParams();
        // Guard: old strategy must be drained before switching, otherwise its LP position
        // becomes orphaned (totalAssets no longer accounts for it, and Vault loses permission
        // to call withdrawToVault/emergencyWithdraw on it).
        if (strategy != address(0)) {
            if (IStrategyUniswapV3(strategy).currentLiquidity() != 0) revert InvalidParams();
            (uint256 bal0, uint256 bal1) = IStrategyUniswapV3(strategy).getBalances();
            if (bal0 != 0 || bal1 != 0) revert InvalidParams();
        }
        strategy = newStrategy;
        emit StrategyUpdated(newStrategy);
    }

    /// @notice Clamp outgoing token0/token1 amounts so the referral reserve stays in Vault.
    /// @dev Shared by fundStrategy and fundAndMint to guarantee the same referral reserve guard.
    ///      [2026-06-11 fix] The reserve is pendingReferralFees + snapshotPending: after
    ///      startReferralDistribution() the pot moves pending -> snapshotPending, so clamping
    ///      on pending alone left the reserve unprotected for the whole active session.
    ///      A compound/fund during a (stuck) session then swept the backing into the LP
    ///      (observed on autoLP eth-usdc-aggressive, ~$870).
    function _clampForReferralReserve(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint256, uint256) {
        if (pool == address(0)) return (amount0, amount1);
        address tok0 = IUniswapV3PoolMinimal(pool).token0();
        address tok1 = IUniswapV3PoolMinimal(pool).token1();
        // _availableBalance reserves pendingReferralFees + snapshotPending (the same guard
        // used by swapVaultToken / redemptions), so the two guards can never drift apart again.
        if (token0 == tok0) {
            uint256 maxSend0 = _availableBalance(token0);
            if (amount0 > maxSend0) amount0 = maxSend0;
        }
        if (token1 == tok1) {
            uint256 maxSend1 = _availableBalance(token1);
            if (amount1 > maxSend1) amount1 = maxSend1;
        }
        return (amount0, amount1);
    }

    /// @notice Transfer token0/token1 from Vault to Strategy
    /// @dev In MVP, amounts are specified by admin/keeper; no swaps are performed.
    ///      pendingReferralFees are kept in Vault (protected from being included in compound).
    function fundStrategy(address token0, address token1, uint256 amount0, uint256 amount1)
        external
        onlyKeeperOrAdmin
        whenNotPaused
        nonReentrant
    {
        if (strategy == address(0)) revert InvalidParams();
        if (token0 == address(0) || token1 == address(0)) revert InvalidParams();
        // Refuse to pump tokens into Strategy when no depositors exist — otherwise the keeper
        // can auto-create an "orphan" LP from post-redeem dust (see keeper.ts autoFund path).
        if (totalSupply == 0) revert InvalidParams();

        (amount0, amount1) = _clampForReferralReserve(token0, token1, amount0, amount1);

        if (amount0 > 0) {
            _safeTransfer(token0, strategy, amount0);
        }
        if (amount1 > 0) {
            _safeTransfer(token1, strategy, amount1);
        }
        emit StrategyFunded(token0, token1, amount0, amount1);
    }

    /// @notice Safe wrapper for ERC20 transfer
    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok) revert InvalidParams();
        if (data.length > 0 && !abi.decode(data, (bool))) revert InvalidParams();
    }

    /// @notice Internal fee collection (called before rebalance / compound / redeem)
    /// @dev Collects LP fees via Strategy.collectFees() and deducts in this order:
    ///      1. System fee (immutable, deducted from gross)
    ///      2. Performance fee (performanceFeeBps, calculated from net after system fee)
    ///      3. Referral fee (calculated from net after performance fee)
    ///      Each sweepToken is wrapped in try/catch so one failure does not block others.
    function _collectPerformanceFees() internal {
        if (strategy == address(0) || pool == address(0)) return;
        bool hasSystemFee = systemFeeBps > 0 && systemFeeRecipient != address(0);
        bool hasPerfFee = performanceFeeBps > 0 && feeRecipient != address(0);
        uint16 sumRefBps = referralFeeBps[0] + referralFeeBps[1] + referralFeeBps[2];
        if (!hasSystemFee && !hasPerfFee && sumRefBps == 0) return;
        try IStrategyUniswapV3(strategy).collectFees() returns (uint256 amount0, uint256 amount1) {
            if (amount0 == 0 && amount1 == 0) return;
            address tok0 = IUniswapV3PoolMinimal(pool).token0();
            address tok1 = IUniswapV3PoolMinimal(pool).token1();
            uint256 net0 = amount0;
            uint256 net1 = amount1;
            // (1) System fee (deducted from gross, immutable)
            if (hasSystemFee) {
                uint256 sys0 = amount0 * systemFeeBps / 10_000;
                uint256 sys1 = amount1 * systemFeeBps / 10_000;
                if (sys0 > 0) try IStrategyUniswapV3(strategy).sweepToken(tok0, sys0, systemFeeRecipient) {} catch {}
                if (sys1 > 0) try IStrategyUniswapV3(strategy).sweepToken(tok1, sys1, systemFeeRecipient) {} catch {}
                net0 -= sys0;
                net1 -= sys1;
                emit SystemFeePaid(sys0, sys1, systemFeeRecipient);
            }
            // (2) Performance fee (calculated from net after system fee)
            if (hasPerfFee) {
                uint256 fee0 = net0 * performanceFeeBps / 10_000;
                uint256 fee1 = net1 * performanceFeeBps / 10_000;
                if (fee0 > 0) try IStrategyUniswapV3(strategy).sweepToken(tok0, fee0, feeRecipient) {} catch {}
                if (fee1 > 0) try IStrategyUniswapV3(strategy).sweepToken(tok1, fee1, feeRecipient) {} catch {}
                net0 -= fee0;
                net1 -= fee1;
                emit PerformanceFeePaid(fee0, fee1, feeRecipient);
            }
            // (3) Referral fee accrual (calculated from net after all fee deductions)
            if (sumRefBps > 0 && (net0 > 0 || net1 > 0)) {
                _accrueReferralFees(net0, net1, sumRefBps, tok0, tok1);
            }
        } catch {
            // positionTokenId == 0, etc. -- skip
        }
    }

    function _withdrawFromStrategyInternal(uint128 liquidity, uint256 amount0Min, uint256 amount1Min)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        if (strategy == address(0) || liquidity == 0) revert InvalidParams();
        (amount0, amount1) = IStrategyUniswapV3(strategy).withdrawToVault(liquidity, amount0Min, amount1Min);
        emit StrategyWithdrawn(amount0, amount1);
    }

    function _liquidityToWithdraw(uint256 shares) internal view returns (uint128) {
        if (strategy == address(0) || totalSupply == 0) return 0;
        uint128 totalLiq = IStrategyUniswapV3(strategy).currentLiquidity();
        // Bug M4: Use ceiling division to prevent small shareholders from getting zero LP
        uint256 portion = (uint256(totalLiq) * shares + totalSupply - 1) / totalSupply;
        if (portion > type(uint128).max) return type(uint128).max;
        return uint128(portion);
    }

    function _computeWithdrawMins(uint256 assets) internal view returns (uint256 amount0Min, uint256 amount1Min) {
        if (pool == address(0) || assets == 0 || slippageBps >= 10_000) return (0, 0);
        if (strategy == address(0)) return (0, 0);

        // Get per-token actual balances (LP + idle + uncollected fees) via getBalances()
        // and apply slippage independently to each.
        // Old impl: set asset-side minimum based on totalAssets(), but in-range LP splits
        // tokens ~50/50, so asset side only returns ~50% of totalAssets, causing 85% min
        // to always trigger "Price slippage check".
        (uint256 exp0, uint256 exp1) = IStrategyUniswapV3(strategy).getBalances();

        // If baseAmount < totalAssets, scale down proportionally to relax minimums
        uint256 total = totalAssets();
        if (total > 0 && assets < total) {
            exp0 = (exp0 * assets) / total;
            exp1 = (exp1 * assets) / total;
        }

        amount0Min = (exp0 * (10_000 - slippageBps)) / 10_000;
        amount1Min = (exp1 * (10_000 - slippageBps)) / 10_000;
    }

    function _computeWithdrawMinsByShare(uint256 shares, uint256 bal0, uint256 bal1)
        internal
        view
        returns (uint256 amount0Min, uint256 amount1Min)
    {
        uint16 bps = redeemSlippageBps;
        if (bps == 0) bps = 50; // default 0.5% minimum slippage protection
        if (totalSupply == 0 || bps >= 10_000) return (0, 0);
        uint256 ratio = (shares * 1e18) / totalSupply;
        uint256 expected0 = (bal0 * ratio) / 1e18;
        uint256 expected1 = (bal1 * ratio) / 1e18;
        amount0Min = (expected0 * (10_000 - bps)) / 10_000;
        amount1Min = (expected1 * (10_000 - bps)) / 10_000;
    }

    /// @notice Validate that the pool address is a valid Uniswap V3 pool
    function _validatePool(address pool_, uint24 feeTier_) internal view {
        (bool ok, bytes memory d) = pool_.staticcall(abi.encodeWithSignature("fee()"));
        if (!ok || d.length < 32) revert InvalidParams();
        if (abi.decode(d, (uint24)) != feeTier_) revert InvalidParams();
    }

    function _consultTwap(uint32 secondsAgo) internal view returns (int24 tick) {
        uint32[] memory secs = new uint32[](2);
        secs[0] = secondsAgo;
        // Fall back to slot0 spot tick on observe() revert (e.g. OLD from insufficient cardinality).
        // Without this, new pools or ones with small observation windows DoS the entire Vault
        // (totalAssets -> convertToShares/Assets -> deposit/redeem all revert).
        try IUniswapV3PoolMinimal(pool).observe(secs) returns (
            int56[] memory tickCumulatives,
            uint160[] memory /*secondsPerLiquidityCumulativeX128s*/
        ) {
            int56 delta = tickCumulatives[1] - tickCumulatives[0];
            tick = int24(delta / int56(uint56(secondsAgo)));
            if (delta < 0 && (delta % int56(uint56(secondsAgo)) != 0)) tick--;
        } catch {
            (, int24 spotTick,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
            tick = spotTick;
        }
    }

    // _getQuoteAtTick moved to VaultMathLib (external library)

    // pauseAndWithdrawTo(address) removed (2026-05, non-custodial hardening):
    // it allowed the admin to drain all Vault assets to an arbitrary address and
    // zero out totalSupply. Emergency stop is now pause() only, which unwinds the
    // position into the Vault so each user redeems their proportional share —
    // funds can never be sent to an external (operator-chosen) address.

    /// @notice Pause the Vault. Automatically unwinds Strategy position if one exists
    function pause() external onlyAdmin nonReentrant {
        _collectPerformanceFees(); // Collect only LP fee portion (do not charge principal)
        // [Audit fix A] If a referral distribution cycle is active, unwind it first: return the
        // reserved snapshot pot to pending and clear distributionActive. Otherwise the snapshot
        // would be permanently locked and distributionActive would stay stuck true, DoS-ing all
        // future distribution cycles (startReferralDistribution reverts while active).
        if (distributionActive) {
            if (snapshotPending0 > 0) pendingReferralFees0 += snapshotPending0;
            if (snapshotPending1 > 0) pendingReferralFees1 += snapshotPending1;
            snapshotPending0 = 0;
            snapshotPending1 = 0;
            distributionActive = false;
        }
        _clearPendingReferralFees(); // Clear referral dust before emergency
        paused = true;
        emit Paused(msg.sender);
        if (strategy != address(0)) {
            (uint256 a0, uint256 a1) = IStrategyUniswapV3(strategy).emergencyWithdraw(address(this));
            emit EmergencyWithdraw(msg.sender, address(this), a0, a1);
        }
    }

    /// @notice Unpause the Vault (also unpauses Strategy)
    function unpause() external onlyAdmin {
        paused = false;
        if (strategy != address(0)) {
            try IStrategyUniswapV3(strategy).unpause() {} catch {}
        }
        emit Unpaused(msg.sender);
    }

    /// @notice Update strategy parameters
    function setStrategyParams(
        address pool_,
        uint24 feeTier_,
        int24 tickLower_,
        int24 tickUpper_,
        uint16 rangeBps_,
        uint16 slippageBps_,
        uint32 cooldownSeconds_
    ) external onlyKeeperOrAdmin {
        // SECURITY: pool is validated via _validatePool (prevents malicious pool even if Keeper is compromised)
        if (pool_ == address(0)) revert InvalidParams();
        if (slippageBps_ > 10_000) revert InvalidParams();
        _validatePool(pool_, feeTier_);
        pool = pool_;
        feeTier = feeTier_;
        tickLower = tickLower_;
        tickUpper = tickUpper_;
        rangeBps = rangeBps_;
        slippageBps = slippageBps_;
        cooldownSeconds = cooldownSeconds_;
        if (strategy != address(0)) {
            IStrategyUniswapV3(strategy).setParams(pool_, feeTier_, tickLower_, tickUpper_, slippageBps_, twapWindowSeconds);
        }
        emit StrategyParamsUpdated(
            pool_,
            feeTier_,
            tickLower_,
            tickUpper_,
            rangeBps_,
            slippageBps_,
            cooldownSeconds_
        );
    }

    /// @notice Set all strategy parameters in a single transaction
    /// @dev Combines setStrategyParams + setTwapWindowSeconds + setRedeemSlippageBps + setPerformanceFee
    function setAllParams(
        address pool_,
        uint24 feeTier_,
        int24 tickLower_,
        int24 tickUpper_,
        uint16 rangeBps_,
        uint16 slippageBps_,
        uint32 cooldownSeconds_,
        uint32 twapWindowSeconds_,
        uint16 redeemSlippageBps_,
        uint16 performanceFeeBps_,
        address feeRecipient_
    ) external onlyAdmin {
        if (pool_ == address(0)) revert InvalidParams();
        if (slippageBps_ > 10_000) revert InvalidParams();
        if (redeemSlippageBps_ > 10_000) revert InvalidParams();
        if (performanceFeeBps_ > 5000) revert InvalidParams(); // max 50% (consistent with setPerformanceFee)
        _validatePool(pool_, feeTier_);
        pool = pool_;
        feeTier = feeTier_;
        tickLower = tickLower_;
        tickUpper = tickUpper_;
        rangeBps = rangeBps_;
        slippageBps = slippageBps_;
        cooldownSeconds = cooldownSeconds_;
        twapWindowSeconds = twapWindowSeconds_;
        redeemSlippageBps = redeemSlippageBps_;
        performanceFeeBps = performanceFeeBps_;
        feeRecipient = feeRecipient_;
        if (strategy != address(0)) {
            IStrategyUniswapV3(strategy).setParams(pool_, feeTier_, tickLower_, tickUpper_, slippageBps_, twapWindowSeconds_);
        }
        emit StrategyParamsUpdated(pool_, feeTier_, tickLower_, tickUpper_, rangeBps_, slippageBps_, cooldownSeconds_);
        emit TwapWindowUpdated(twapWindowSeconds_);
        emit RedeemSlippageUpdated(redeemSlippageBps_);
        emit PerformanceFeeUpdated(performanceFeeBps_, feeRecipient_);
    }

    // --- Strategy Actions (Keeper-triggered) ---
    /// @notice Forward mint to strategy with explicit desired amounts.
    /// @dev For MVP, caller provides amounts; off-chain computes optimal sizing.
    /// @notice Forward mint to strategy with specified amounts
    /// @dev In MVP, amounts are computed off-chain; on-chain only executes
    function mintPosition(uint256 amount0Desired, uint256 amount1Desired)
        external
        onlyKeeperOrAdmin
        whenNotPaused
        nonReentrant
        returns (uint256 liquidity)
    {
        if (strategy == address(0)) revert InvalidParams();
        liquidity = IStrategyUniswapV3(strategy).mintPosition(amount0Desired, amount1Desired);
        emit MintPosition(pool, tickLower, tickUpper, liquidity);
    }

    /// @notice Transfer from Vault to Strategy & mint LP in one tx
    /// @dev Combined fundStrategy() + mintPosition(). mintAmount0/1 are computed off-chain by the caller
    function fundAndMint(
        address token0_,
        address token1_,
        uint256 fundAmount0,
        uint256 fundAmount1,
        uint256 mintAmount0,
        uint256 mintAmount1
    ) external onlyKeeperOrAdmin whenNotPaused nonReentrant returns (uint256 liquidity) {
        if (strategy == address(0)) revert InvalidParams();
        if (token0_ == address(0) || token1_ == address(0)) revert InvalidParams();
        // Block orphan LP creation — if there are no depositors, keeper should not mint.
        if (totalSupply == 0) revert InvalidParams();
        // Apply the same referral-reserve clamp as fundStrategy so pendingReferralFees cannot
        // be swept into the Strategy via fundAndMint.
        (fundAmount0, fundAmount1) = _clampForReferralReserve(token0_, token1_, fundAmount0, fundAmount1);
        if (fundAmount0 > 0) _safeTransfer(token0_, strategy, fundAmount0);
        if (fundAmount1 > 0) _safeTransfer(token1_, strategy, fundAmount1);
        if (fundAmount0 > 0 || fundAmount1 > 0) emit StrategyFunded(token0_, token1_, fundAmount0, fundAmount1);
        if (mintAmount0 > 0 || mintAmount1 > 0) {
            liquidity = IStrategyUniswapV3(strategy).mintPosition(mintAmount0, mintAmount1);
            emit MintPosition(pool, tickLower, tickUpper, liquidity);
        }
    }

    /// @notice Reinvest collected fees (Strategy idle balance) into the existing position
    function compound()
        external
        onlyKeeperOrAdmin
        whenNotPaused
        nonReentrant
        returns (uint128 addedLiquidity)
    {
        if (strategy == address(0)) revert InvalidParams();
        _collectPerformanceFees(); // Deduct performance fees before compounding
        uint256 compoundAmount0;
        uint256 compoundAmount1;
        (addedLiquidity, compoundAmount0, compoundAmount1) = IStrategyUniswapV3(strategy).addLiquidity();
        if (addedLiquidity > 0) emit Compound(pool, tickLower, tickUpper, addedLiquidity, compoundAmount0, compoundAmount1);
    }

    /// @notice Instruct strategy to collect fees
    /// @dev Delegates to internal _collectPerformanceFees() to avoid duplicated logic
    function collectFees() external onlyKeeperOrAdmin whenNotPaused nonReentrant {
        if (strategy == address(0)) revert InvalidParams();
        _collectPerformanceFees();
        emit CollectFees(pool, 0, 0); // Actual amounts tracked via PerformanceFeePaid / ReferralFeesAccrued events
    }

    /// @notice Rebalance with TWAP-based minimum amount calculation
    /// @param baseAmount Base asset amount for minimum calculation (in asset units)
    function rebalanceWithTwap(int24 newTickLower, int24 newTickUpper, uint256 baseAmount)
        external
        onlyKeeperOrAdmin
        whenNotPaused
        nonReentrant
    {
        if (block.timestamp < lastRebalanceAt + cooldownSeconds) revert CooldownActive();
        if (strategy == address(0)) revert InvalidParams();
        _collectPerformanceFees(); // Collect uncollected LP fees first
        if (baseAmount == 0) {
            baseAmount = totalAssets();
        }
        (uint256 amount0Min, uint256 amount1Min) = _computeWithdrawMins(baseAmount);
        uint256 liquidity = IStrategyUniswapV3(strategy).rebalance(newTickLower, newTickUpper, amount0Min, amount1Min);
        // Sync Vault's tickLower/tickUpper to the new range (prevent Compound event display mismatch)
        tickLower = newTickLower;
        tickUpper = newTickUpper;
        lastRebalanceAt = block.timestamp;
        emit Rebalance(pool, newTickLower, newTickUpper, liquidity);
    }

    /// @notice Calculate base amount from TVL bps
    function computeBaseAmountBps(uint16 bps) external view returns (uint256) {
        if (bps > 10_000) revert InvalidParams();
        return (totalAssets() * bps) / 10_000;
    }

    // --- System Fee (OEM, immutable) ---
    /// @notice System fee rate (bps, fixed at deploy, max 1000 = 10%)
    uint16 public systemFeeBps;
    /// @notice System fee recipient address (fixed at deploy)
    address public systemFeeRecipient;

    // --- Swap ---
    /// @notice Uniswap SwapRouter02 (chain-specific, set at deploy)
    address private SWAP_ROUTER;

    /// @notice Swap tokens in the Vault via Uniswap V3 (used to acquire tokens for LP)
    /// @dev Used by Keeper to convert investor USDC to WETH etc. for LP. Keeper/Admin only.
    function swapVaultToken(
        address tokenIn,
        address tokenOut,
        uint24  fee,
        uint256 amountIn,
        uint256 amountOutMinimum
    ) external onlyKeeperOrAdmin whenNotPaused nonReentrant returns (uint256 amountOut) {
        if (tokenIn == address(0) || tokenOut == address(0)) revert InvalidParams();
        if (amountIn == 0) revert InvalidParams();
        // Restrict to the pool's token0/token1 pair only (2026-05, non-custodial
        // hardening). The legitimate use (keeper inventory conversion) is always
        // within the pair; this guarantees the TWAP floor below always applies, so a
        // non-pair swap into an attacker-controlled pool at amountOutMinimum=0 — which
        // would drain idle Vault funds into a worthless token — is no longer possible.
        if (pool == address(0)) revert InvalidParams();
        {
            address _p0 = IUniswapV3PoolMinimal(pool).token0();
            address _p1 = IUniswapV3PoolMinimal(pool).token1();
            if (!((tokenIn == _p0 && tokenOut == _p1) || (tokenIn == _p1 && tokenOut == _p0)))
                revert InvalidParams();
        }
        // Reserve guard: never spend pendingReferralFees as swap input. Without this clamp
        // a keeper-driven inventory rebalance can drain the referral reserve, after which
        // distributeReferralFees / sweepReferralDust revert (incident 2026-04-30).
        uint256 _avail = _availableBalance(tokenIn);
        if (amountIn > _avail) amountIn = _avail;
        if (amountIn == 0) revert InvalidParams();
        // TWAP-based minimum floor: even if keeper/admin key leaks, the swap cannot settle at
        // worse than (TWAP-quoted expected out) * (1 - slippageBps). A larger `amountOutMinimum`
        // from the caller is still respected; only zero / below-floor values are rejected.
        // Only applied to the pool's token0/token1 pair — _getQuoteAtTick uses this pool's tick
        // and would produce a nonsense quote for a third-token swap, so skip the floor in that case
        // (such a swap should only be used for admin recovery of unrelated tokens anyway).
        if (pool != address(0) && twapWindowSeconds > 0) {
            address tok0 = IUniswapV3PoolMinimal(pool).token0();
            address tok1 = IUniswapV3PoolMinimal(pool).token1();
            bool isPoolPair =
                (tokenIn == tok0 && tokenOut == tok1) ||
                (tokenIn == tok1 && tokenOut == tok0);
            if (isPoolPair) {
                int24 twapTick = _consultTwap(twapWindowSeconds);
                uint256 expectedOut = VaultMathLib.getQuoteAtTick(twapTick, amountIn, tokenIn, tokenOut);
                uint256 floorOut = (expectedOut * (10_000 - slippageBps)) / 10_000;
                if (amountOutMinimum < floorOut) amountOutMinimum = floorOut;
            }
        }
        IERC20(tokenIn).approve(SWAP_ROUTER, amountIn);
        // Execute exactInputSingle via try, ensuring approve is reset even on revert
        try ISwapRouter02(SWAP_ROUTER).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn:           tokenIn,
                tokenOut:          tokenOut,
                fee:               fee,
                recipient:         address(this),
                amountIn:          amountIn,
                amountOutMinimum:  amountOutMinimum,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 out) {
            amountOut = out;
        } catch {
            IERC20(tokenIn).approve(SWAP_ROUTER, 0);
            revert InvalidParams();
        }
        IERC20(tokenIn).approve(SWAP_ROUTER, 0);
        emit VaultTokenSwapped(tokenIn, tokenOut, amountIn, amountOut);
    }

    // --- Referral Functions ---

    /// @notice Return available balance of a token in Vault, excluding pendingReferralFees
    function _availableBalance(address token) internal view returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (pool == address(0)) return bal;
        address tok0 = IUniswapV3PoolMinimal(pool).token0();
        address tok1 = IUniswapV3PoolMinimal(pool).token1();
        // [RSNR fix] reserve BOTH live pending fees AND the in-flight distribution snapshot,
        // so an active referral distribution pot cannot be consumed by redemptions or keeper
        // swaps before it is fully paid out.
        if (token == tok0) {
            uint256 reserved0 = pendingReferralFees0 + snapshotPending0;
            bal = bal > reserved0 ? bal - reserved0 : 0;
        }
        if (token == tok1) {
            uint256 reserved1 = pendingReferralFees1 + snapshotPending1;
            bal = bal > reserved1 ? bal - reserved1 : 0;
        }
        return bal;
    }

    /// @notice External view: balance excluding pendingReferralFees (for keeper / off-chain)
    /// @dev Wraps _availableBalance for external callers. Backend uses this so the keeper
    ///      cannot accidentally consume the referral reserve via swap or fund operations.
    function availableBalance(address token) external view returns (uint256) {
        return _availableBalance(token);
    }

    /// @notice Transfer pending referral fees to recipient and zero out storage
    function _sendPendingReferralFees(address recipient) internal {
        if (pendingReferralFees0 == 0 && pendingReferralFees1 == 0) return;
        address tok0 = IUniswapV3PoolMinimal(pool).token0();
        address tok1 = IUniswapV3PoolMinimal(pool).token1();
        if (pendingReferralFees0 > 0) { _safeTransfer(tok0, recipient, pendingReferralFees0); pendingReferralFees0 = 0; }
        if (pendingReferralFees1 > 0) { _safeTransfer(tok1, recipient, pendingReferralFees1); pendingReferralFees1 = 0; }
    }

    /// @notice Send pendingReferralFees to feeRecipient/admin and zero out storage
    function _clearPendingReferralFees() internal {
        if (pendingReferralFees0 == 0 && pendingReferralFees1 == 0) return;
        if (pool == address(0)) { pendingReferralFees0 = 0; pendingReferralFees1 = 0; return; }
        _sendPendingReferralFees(feeRecipient != address(0) ? feeRecipient : admin);
    }

    /// @notice Accrue referral fees (called internally during fee collection)
    function _accrueReferralFees(uint256 amount0, uint256 amount1, uint16 sumBps, address tok0, address tok1) internal {
        uint256 ref0 = amount0 * sumBps / 10_000;
        uint256 ref1 = amount1 * sumBps / 10_000;
        if (ref0 == 0 && ref1 == 0) return;
        pendingReferralFees0 += ref0;
        pendingReferralFees1 += ref1;
        // Move from Strategy to Vault (excluded from compound)
        if (ref0 > 0) IStrategyUniswapV3(strategy).sweepToken(tok0, ref0, address(this));
        if (ref1 > 0) IStrategyUniswapV3(strategy).sweepToken(tok1, ref1, address(this));
        emit ReferralFeesAccrued(ref0, ref1);
    }

    /// @notice Update referral share totals on deposit/redeem
    /// @dev Prevents double-counting at L2/L3 in self-referral chains (admin->admin)
    function _updateReferralShares(address user, uint256 shares, bool isDeposit) internal {
        address ref1 = referrer[user];
        if (ref1 == address(0)) return;
        if (isDeposit) { level1Shares[ref1] += shares; }
        else { level1Shares[ref1] = level1Shares[ref1] >= shares ? level1Shares[ref1] - shares : 0; }
        address ref2 = referrer[ref1];
        if (ref2 == address(0) || ref2 == ref1 || ref2 == user) return; // prevent self-referral loop
        if (isDeposit) { level2Shares[ref2] += shares; }
        else { level2Shares[ref2] = level2Shares[ref2] >= shares ? level2Shares[ref2] - shares : 0; }
        address ref3 = referrer[ref2];
        // Include `ref3 == user` to block depth-4 cycles (user -> ref1 -> ref2 -> ref3 -> user).
        // Without this a constructed chain would credit level3Shares[user] from user's own deposits.
        if (ref3 == address(0) || ref3 == ref2 || ref3 == ref1 || ref3 == user) return;
        if (isDeposit) { level3Shares[ref3] += shares; }
        else { level3Shares[ref3] = level3Shares[ref3] >= shares ? level3Shares[ref3] - shares : 0; }
    }

    /// @notice Snapshot for paginated distribution (auto-set when offset=0)
    uint256 public snapshotPending0;
    uint256 public snapshotPending1;
    uint256 public snapshotTotalSupply;

    /// @notice RoleHub proxy address — wired via `reinitializeV2_setRoleHub`.
    /// @dev    Slot 25. While zero, modifiers fall back to legacy `admin`/`keeper`
    ///         vars for full pre-V2 compatibility. Once set, hub.hasRole(...)
    ///         is the source of truth.
    address public roleHub;

    /// @notice V2 reinitializer guard.
    /// @dev    Slot 26. Packed at byte offset 20 inside slot 25 alongside roleHub
    ///         (address fills 20 bytes, bool takes 1 byte → no new slot used).
    bool private _initializedV2;

    /// @notice True while a referral distribution cycle is in progress (B-2 model).
    /// @dev    Packed into the SAME slot as roleHub (20 bytes) + _initializedV2 (1 byte):
    ///         20 + 1 + 1 = 22 bytes, still within the 32-byte slot. This byte was zero
    ///         before the upgrade → reads false, so no reinitializer is needed. Layout is
    ///         preserved (no new slot consumed; existing slots unchanged).
    bool public distributionActive;

    // ─────────────────────────────────────────────────────────────────────────
    // Referral distribution — B-2 model (off-chain computed amounts + on-chain cap)
    //
    // Fixes the prior paginated design's RSNR/SWD/LRU/DSR findings:
    //  - Amounts are computed off-chain from a single frozen snapshot block, so per-referrer
    //    weights cannot drift between pages (SWD) and later pages are not underpaid (LRU).
    //  - The snapshot pot is RESERVED via _availableBalance()/totalAssets() while a cycle is
    //    active, so it cannot be consumed by redemptions/keeper swaps mid-distribution (RSNR).
    //  - A cycle must be explicitly started/ended and cannot be restarted while active (DSR).
    //  - On-chain only verifies that the sum paid never exceeds the reserved pot, so the keeper
    //    cannot over-pay or drain (the residual trust — the exact split — is bounded by the cap).
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Begin a referral distribution cycle: snapshot & reserve the current pending pot.
    /// @dev    Reverts if a cycle is already active (DSR guard). No-op if nothing pending.
    function startReferralDistribution() external onlyKeeperOrAdmin nonReentrant {
        if (distributionActive) revert InvalidParams();
        if (pendingReferralFees0 == 0 && pendingReferralFees1 == 0) return;
        snapshotPending0 = pendingReferralFees0;
        snapshotPending1 = pendingReferralFees1;
        pendingReferralFees0 = 0;
        pendingReferralFees1 = 0;
        distributionActive = true;
        emit ReferralDistributionStarted(snapshotPending0, snapshotPending1);
    }

    /// @notice Pay a page of referrers their off-chain computed amounts (capped by the reserve).
    /// @dev    Callable repeatedly (paginated) while a cycle is active. Each amount must fit in
    ///         the remaining reserved snapshot pot; otherwise the whole page reverts.
    function distributeReferralFeesExact(
        address[] calldata refs,
        uint256[] calldata amounts0,
        uint256[] calldata amounts1
    ) external onlyKeeperOrAdmin nonReentrant {
        if (!distributionActive) revert InvalidParams();
        uint256 n = refs.length;
        if (amounts0.length != n || amounts1.length != n) revert InvalidParams();
        address tok0 = IUniswapV3PoolMinimal(pool).token0();
        address tok1 = IUniswapV3PoolMinimal(pool).token1();
        uint256 rem0 = snapshotPending0;
        uint256 rem1 = snapshotPending1;
        for (uint256 i = 0; i < n; i++) {
            address r = refs[i];
            // [Audit fix B] Only registered referrers may be paid. Bounds a compromised keeper
            // to the existing referral tree (cannot redirect the pot to an arbitrary address).
            if (r == address(0) || !_isReferrer[r]) revert InvalidParams();
            uint256 p0 = amounts0[i];
            uint256 p1 = amounts1[i];
            // Cap: never pay more than the reserved pot (prevents over-pay / drain).
            if (p0 > rem0 || p1 > rem1) revert InvalidParams();
            rem0 -= p0;
            rem1 -= p1;
            if (p0 > 0) _safeTransfer(tok0, r, p0);
            if (p1 > 0) _safeTransfer(tok1, r, p1);
            if (p0 > 0 || p1 > 0) emit ReferralFeePaid(r, p0, p1);
        }
        snapshotPending0 = rem0;
        snapshotPending1 = rem1;
    }

    /// @notice End the cycle: return any undistributed remainder to pending for the next round.
    function endReferralDistribution() external onlyKeeperOrAdmin nonReentrant {
        if (!distributionActive) revert InvalidParams();
        // [Audit fix D] emit the amount actually returned (not the post-add cumulative pending,
        // which would also include fees that accrued mid-cycle).
        uint256 returned0 = snapshotPending0;
        uint256 returned1 = snapshotPending1;
        if (returned0 > 0) pendingReferralFees0 += returned0;
        if (returned1 > 0) pendingReferralFees1 += returned1;
        snapshotPending0 = 0;
        snapshotPending1 = 0;
        distributionActive = false;
        emit ReferralDistributionEnded(returned0, returned1);
    }

    /// @notice Send referral fee dust (remainder after distribution) to feeRecipient
    function sweepReferralDust() external onlyKeeperOrAdmin {
        if (pool == address(0)) return;
        _sendPendingReferralFees(feeRecipient != address(0) ? feeRecipient : admin);
    }

    /// @notice Set referral fee rates for each level
    function setReferralFeeBps(uint16[3] calldata bps) external onlyAdmin {
        // [2026-05-25] Cap raised 10% → 20% for autoLP whitelabel which uses
        // a higher referral budget (10% / 4% / 2% = 16% total). The fee is
        // calculated from net after system+performance fee deductions, so
        // any sum < 100% is mathematically safe; this cap is a policy guard.
        if (uint256(bps[0]) + uint256(bps[1]) + uint256(bps[2]) > 2000) revert InvalidParams(); // total max 20%
        referralFeeBps = bps;
        emit ReferralFeeBpsUpdated(bps);
    }

    /// @notice Admin or Keeper manually sets a referrer (for exceptional cases / cross-vault propagation cron)
    /// @dev    2026-05-19: extended to onlyKeeperOrAdmin so the backend cron can
    ///         auto-propagate referrer relationships across vaults (previously onlyAdmin,
    ///         which made the keeper PRIVATE_KEY signature revert with NotAuthorized).
    ///         This operation moves no funds, so widening Keeper access is low-risk.
    function setReferrerAdmin(address user, address referrer_) external onlyKeeperOrAdmin {
        if (user == address(0) || referrer_ == address(0)) revert InvalidParams();
        if (referrer_ == user && user != admin) revert InvalidParams(); // self-referral forbidden (except admin)
        // Circular reference check (3 hops)
        address r1 = referrer[referrer_];
        if (r1 == user) revert InvalidParams();
        if (r1 != address(0)) {
            address r2 = referrer[r1];
            if (r2 == user) revert InvalidParams();
            if (r2 != address(0) && referrer[r2] == user) revert InvalidParams();
        }
        // Remove from old chain if existing shares
        uint256 shares = balanceOf[user];
        if (shares > 0 && referrer[user] != address(0)) {
            _updateReferralShares(user, shares, false);
        }
        referrer[user] = referrer_;
        if (!_isReferrer[referrer_]) {
            _isReferrer[referrer_] = true;
            _referrerList.push(referrer_);
        }
        // Add shares to new chain
        if (shares > 0) {
            _updateReferralShares(user, shares, true);
        }
        emit ReferrerSet(user, referrer_);
    }

    /// @notice Check if a user is a member (has referrer registered)
    function isMember(address user) external view returns (bool) {
        return referrer[user] != address(0);
    }

    /// @notice Return the user's referral chain [L1, L2, L3]
    function getReferralChain(address user) external view returns (address[3] memory chain) {
        chain[0] = referrer[user];
        if (chain[0] != address(0)) chain[1] = referrer[chain[0]];
        if (chain[1] != address(0)) chain[2] = referrer[chain[1]];
    }

    /// @notice Return the number of registered referrers
    function referrerCount() external view returns (uint256) {
        return _referrerList.length;
    }

    /// @notice Paginated read of the referrer list (for off-chain B-2 distribution).
    /// @dev    `_referrerList` is private; the keeper enumerates referrers via this getter
    ///         to compute per-referrer payout amounts off-chain.
    function referrerListPage(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory page)
    {
        uint256 len = _referrerList.length;
        if (offset >= len) return new address[](0);
        uint256 end = offset + limit;
        if (end > len) end = len;
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = _referrerList[i];
        }
    }

    // --- Emergency ---
    /// @notice Rescue mistakenly sent tokens remaining in the Vault
    /// @dev Cannot sweep asset (USDC) or pool token0/token1 (user asset protection)
    function rescueToken(address token, address to) external onlyAdmin nonReentrant {
        if (token == address(0) || to == address(0)) revert InvalidParams();
        // Tokens comprising user assets cannot be swept
        if (token == address(asset)) revert InvalidParams();
        if (pool != address(0)) {
            if (token == IUniswapV3PoolMinimal(pool).token0()) revert InvalidParams();
            if (token == IUniswapV3PoolMinimal(pool).token1()) revert InvalidParams();
        }
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) _safeTransfer(token, to, bal);
    }

    // emergencyWithdraw(address) removed (2026-05, non-custodial hardening):
    // it allowed the admin to drain all Vault assets to an arbitrary address.
    // Emergency stop is now pause() only (unwinds the position into the Vault;
    // users redeem their proportional share). See the pauseAndWithdrawTo note above.
}

/// @notice 512-bit precision mulDiv
library FullMath {
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) {
                if (denominator == 0) revert();
                assembly {
                    result := div(prod0, denominator)
                }
                return result;
            }
            if (denominator <= prod1) revert();
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            result = prod0 * inv;
            return result;
        }
    }
}

/// @notice Simplified Uniswap V3 TickMath implementation
library TickMath {
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = -MIN_TICK;
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = uint256(int256(tick < 0 ? -tick : tick));
        if (absTick > uint256(int256(MAX_TICK))) revert();

        uint256 ratio = absTick & 0x1 != 0
            ? 0xfffcb933bd6fad37aa2d162d1a594001
            : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;
        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
        if (sqrtPriceX96 < MIN_SQRT_RATIO || sqrtPriceX96 >= MAX_SQRT_RATIO) revert();
    }
}
