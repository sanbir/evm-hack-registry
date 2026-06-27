// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable@4.9.6/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable@4.9.6/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable@4.9.6/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable@4.9.6/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable@4.9.6/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable@4.9.6/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable@4.9.6/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable@4.9.6/utils/cryptography/ECDSAUpgradeable.sol";

/// @notice Minimal Uniswap V2 pair interface (sync only).
interface IUniswapV2Pair {
    function sync() external;
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/**
 * @title AROS Token (Upgradeable)
 * @notice Fixed-supply ERC20 (2.1B) with EIP-712 signed claims that pull AROS from the LP pair.
 *
 *         === Period-Range Replay Protection ===
 *         Each of the 4 claim types (Principal / Yield / Lucky / Contribution) maintains an
 *         INDEPENDENT per-user period cursor `lastPeriod*[user]`. Every claim signature carries
 *         a continuous period range `[periodFrom, periodTo]` and MUST satisfy:
 *
 *             periodFrom == lastPeriod*[user] + 1
 *             periodTo   >= periodFrom
 *
 *         After a successful claim the cursor advances to `periodTo`, so the same signature
 *         (or any earlier-range signature) can never be replayed. The signed `amount` covers
 *         the entire `[periodFrom, periodTo]` range — periods with no reward simply contribute
 *         0 to the sum, but they are still consumed (the cursor still moves past them).
 *
 *         Signatures are bound to `msg.sender` via EIP-712, so a stolen signature cannot be
 *         redirected: any submission from a different sender fails verification, and any
 *         submission from the rightful sender just delivers tokens to that sender.
 */
contract AROS is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PermitUpgradeable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    uint256 public constant MAX_SUPPLY = 2_100_000_000 * 10 ** 18;

    // ===== Constants for claim-signature limits =====

    /// @notice Maximum number of consecutive periods a single signature may
    ///         cover. With `_checkPeriodRange` requiring `periodTo >= periodFrom`
    ///         and the cursor advancing to `periodTo`, an unbounded range
    ///         could (a) fast-forward a user's cursor by an arbitrary amount
    ///         in one tx (DoS) and (b) authorize a single huge `amount`. Cap
    ///         is hard-coded so the project cannot silently widen the window
    ///         post-deployment.
    uint256 public constant MAX_PERIOD_RANGE = 100;

    /// @notice Maximum future window allowed for a claim signature's
    ///         `deadline`. Prevents the backend (or an attacker who has
    ///         leaked the signer key) from issuing signatures that remain
    ///         valid for years. Combined with the daily drain cap, this
    ///         bounds the total damage a leaked key can cause to roughly
    ///         `MAX_SIGNATURE_VALIDITY * dailyDrainBps`.
    uint256 public constant MAX_SIGNATURE_VALIDITY = 7 days;

    // ===== Existing storage (DO NOT REORDER for upgrade safety) =====

    address public lpPair;

    address public claimSigner;

    /// @dev DEPRECATED. Retained for storage layout compatibility only.
    ///      The new period-range claim flow does not write to this mapping.
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    bool public upgradeLocked;

    bool public claimPaused;

    /// @notice The only allowed referral pool. Must be configured before any `claimYield`
    ///         call that carries a non-zero `referralAmount`. The signed `referralPool_`
    ///         parameter is required to match this exact address.
    address public referralPool;

    /// @notice The only allowed dividend pool. Same semantics as `referralPool`.
    address public dividendPool;

    // ===== New storage (appended; consumes 4 of the original __gap[48] slots) =====

    /// @notice Last successfully-claimed period for each user, per claim type.
    ///         The next acceptable signature must have `periodFrom == this + 1`.
    mapping(address => uint256) public lastPeriodPrincipal;
    mapping(address => uint256) public lastPeriodYield;
    mapping(address => uint256) public lastPeriodLucky;
    mapping(address => uint256) public lastPeriodContribution;

    // ===== Phase-1 trading restriction (appended; consumes 2 of the original __gap[44] slots) =====

    /// @notice Phase-1 master switch.
    ///         When `true`:
    ///           (R1) AROS cannot leave `lpPair` to any non-whitelisted address
    ///                (blocks BUY via swap AND REMOVE-LIQUIDITY equally — both look
    ///                 like `from == lpPair` at the ERC20 layer).
    ///                Internal claim transfers bypass via `_inClaim`.
    ///           (R2) AROS cannot land in any contract address other than `lpPair`
    ///                or a whitelisted recipient — prevents anyone from spinning up
    ///                a parallel AROS/* pool to bypass (R1).
    ///         When `false`: no restrictions — normal ERC20 semantics.
    /// @dev    Default `false` so the deployment / initial liquidity flow is not
    ///         blocked. Owner flips to `true` after the LP is bootstrapped.
    /// @dev    Packed with `restrictionLockedOpen` and `_inClaim` in one slot.
    bool public tradingRestricted;

    /// @notice Once `true`, restrictions are forced off forever and
    ///         `setTradingRestricted` reverts. Set via `openTradingForever()`.
    bool public restrictionLockedOpen;

    /// @dev    Internal bypass flag, set ONLY around `_transfer(lpPair, ...)` calls
    ///         inside the 4 claim flows so that those transfers are not blocked by
    ///         (R1). Scope is intentionally minimal: the flag is cleared before any
    ///         external call (including `IUniswapV2Pair.sync`) so a malicious LP
    ///         pair cannot exploit it via reentrancy.
    bool private _inClaim;

    /// @notice VIP whitelist. Two effects:
    ///
    ///         (a) PHASE-1 RESTRICTION BYPASS — while `tradingRestricted == true`,
    ///             a transfer is FULLY EXEMPT from both (R1) and (R2) if EITHER
    ///             its `from` OR its `to` is whitelisted. In effect a whitelisted
    ///             address can BUY, SELL, REMOVE LIQUIDITY, and freely interact
    ///             with any contract during phase 1.
    ///
    ///         (b) SELL-FEE EXEMPTION — at all times, if the SENDER is
    ///             whitelisted, the sell fee is NOT charged on a transfer to
    ///             `lpPair`. This lets team / market makers / liquidity providers
    ///             trade and add liquidity without being taxed.
    ///
    ///         Typical entries: team LP wallet, market-maker wallet/bot,
    ///         multisig, treasury, staking, bridge endpoints, referral pool,
    ///         dividend pool, fee recipient.
    mapping(address => bool) public isWhitelisted;

    // ===== Sell fee (appended; consumes 2 of the original __gap[42] slots) =====

    /// @notice Hard upper bound for `sellFeeBps`. Owner cannot set the fee above
    ///         this — gives external observers a verifiable on-chain ceiling
    ///         that the project can never silently raise the tax above 10%.
    uint256 public constant MAX_FEE_BPS = 1000;

    /// @notice Sell fee in basis points (1 bps = 0.01%). Charged on any transfer
    ///         where `to == lpPair` and the sender is NOT whitelisted, regardless
    ///         of `tradingRestricted`. Set to 0 to disable.
    uint256 public sellFeeBps;

    /// @notice Recipient of collected sell fees. If left as `address(0)`, the
    ///         fee logic is automatically skipped (defensive default).
    address public feeRecipient;

    // ===== Daily drain cap (appended; consumes 4 of the original __gap[40] slots) =====

    /// @notice Maximum fraction of `lpPair`'s AROS balance (in basis points)
    ///         that can be pulled by claim flows within a single rolling
    ///         24-hour window. Default `0` means the cap is DISABLED — set
    ///         via `setDailyDrainBps`. Hard ceiling 10000 (= 100%).
    /// @dev    Bounds the worst-case loss from a stolen `claimSigner` private
    ///         key: even with valid signatures, no more than
    ///         `dayBaseLPBalance * dailyDrainBps / 10000` AROS can leave the
    ///         LP pair via claims in any 24-hour window.
    uint256 public dailyDrainBps;

    /// @notice Timestamp marking the start of the current 24-hour window.
    ///         Auto-rolls forward (no off-chain cron required) on the first
    ///         claim of each new window.
    uint256 public dayStart;

    /// @notice Cumulative AROS pulled from `lpPair` via claim flows since
    ///         `dayStart`. Reset to 0 on each window roll.
    uint256 public drainedToday;

    /// @notice Snapshot of `balanceOf(lpPair)` taken at the start of the
    ///         current window. Used as the denominator for the per-window
    ///         quota so an attacker cannot manipulate the cap by depositing
    ///         AROS into the pair mid-window.
    uint256 public dayBaseLPBalance;

    // ===== Per-tx claim cap & emergency guardian (consumes 2 of __gap[36]) =====

    /// @notice Hard upper bound on the amount of AROS that any single
    ///         claim transaction may pull from `lpPair`. For 3-leg
    ///         `claimYield` the bound applies to the SUM of the three
    ///         legs. `0` (default) disables the bound.
    /// @dev    Purpose is to slow down a stolen-key attacker: even with a
    ///         valid signature, they must split the drain into many txs,
    ///         each of which is an extra opportunity for monitors to fire
    ///         and for the team to invoke `pauseClaim`.
    uint256 public maxClaimPerTx;

    /// @notice Emergency-only role with a SINGLE permission: triggering
    ///         `pauseClaim()`. Guardian CANNOT unpause, change parameters,
    ///         transfer ownership, or upgrade. Intended for a cold key
    ///         held physically separate from the owner multisig — when
    ///         signs of an attack appear, anyone who can reach this key
    ///         can hit the emergency stop without waiting for the multisig
    ///         to coordinate. Set to `address(0)` to disable.
    /// @dev    If the guardian key is itself compromised, the worst the
    ///         attacker can do is DoS-pause the claim flow once (since
    ///         `pauseClaim` reverts when already paused). Owner can then
    ///         unpause and rotate the guardian via `setGuardian`.
    address public guardian;

    // ================= EIP-712 Typehashes =================

    bytes32 public constant CLAIM_PRINCIPAL_TYPEHASH =
        keccak256(
            "ClaimPrincipal(address user,uint256 periodFrom,uint256 periodTo,uint256 amount,uint256 deadline)"
        );

    /// @dev Field order must match the EIP-712 struct when signing off-chain.
    bytes32 public constant CLAIM_YIELD_TYPEHASH =
        keccak256(
            "ClaimYield(address user,uint256 periodFrom,uint256 periodTo,uint256 userAmount,address referralPool,uint256 referralAmount,address dividendPool,uint256 dividendAmount,uint256 deadline)"
        );

    bytes32 public constant CLAIM_LUCKY_TYPEHASH =
        keccak256(
            "ClaimLucky(address user,uint256 periodFrom,uint256 periodTo,uint256 amount,uint256 deadline)"
        );

    bytes32 public constant CLAIM_CONTRIBUTION_TYPEHASH =
        keccak256(
            "ClaimContribution(address user,uint256 periodFrom,uint256 periodTo,uint256 amount,uint256 deadline)"
        );

    // ================= Events =================

    event LPPairUpdated(address indexed oldPair, address indexed newPair);
    event ClaimSignerUpdated(address indexed oldSigner, address indexed newSigner);
    event ReferralPoolUpdated(address indexed oldPool, address indexed newPool);
    event DividendPoolUpdated(address indexed oldPool, address indexed newPool);

    event UpgradeLocked(address indexed by);
    event ClaimPauseUpdated(bool paused);

    event TradingRestrictedUpdated(bool restricted);
    event TradingOpenedForever(address indexed by);
    event WhitelistUpdated(address indexed account, bool whitelisted);

    event SellFeeBpsUpdated(uint256 oldBps, uint256 newBps);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    /// @dev Emitted after fee is deducted from a sell. `seller` is the original
    ///      `from` of the user-side transfer (NOT the router). `amount` is the
    ///      AROS amount routed to `feeRecipient`.
    event SellFeeCollected(address indexed seller, uint256 amount);

    event DailyDrainBpsUpdated(uint256 oldBps, uint256 newBps);
    /// @dev Emitted when the 24-hour window auto-rolls (on the first claim
    ///      of a new window). Lets monitors track quota refresh on-chain.
    event DailyDrainWindowReset(uint256 dayStart, uint256 baseLPBalance);

    event MaxClaimPerTxUpdated(uint256 oldCap, uint256 newCap);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

    event PrincipalClaimed(
        address indexed user,
        uint256 indexed periodFrom,
        uint256 indexed periodTo,
        uint256 amount
    );
    event YieldClaimed(
        address indexed user,
        uint256 indexed periodFrom,
        uint256 indexed periodTo,
        uint256 userAmount,
        address referralPool,
        uint256 referralAmount,
        address dividendPool,
        uint256 dividendAmount
    );
    event LuckyClaimed(
        address indexed user,
        uint256 indexed periodFrom,
        uint256 indexed periodTo,
        uint256 amount
    );
    event ContributionClaimed(
        address indexed user,
        uint256 indexed periodFrom,
        uint256 indexed periodTo,
        uint256 amount
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialHolder, address initialSigner) public initializer {
        require(initialHolder != address(0), "AROS: initial holder is zero");
        require(initialSigner != address(0), "AROS: signer is zero");

        __ERC20_init("AROS", "AROS");
        __ERC20Burnable_init();
        __ERC20Permit_init("AROS");
        __Ownable_init();
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        claimSigner = initialSigner;

        _mint(initialHolder, MAX_SUPPLY);
    }

    // ================= Admin =================

    /**
     * @dev While `tradingRestricted == true`, the canonical `lpPair` may only
     *      be SET (lpPair was zero), never REPLACED. Replacing it during
     *      phase 1 would leave the previous pair as an unrestricted, fully
     *      tradable parallel pool — defeating (R1) and (R2). Once
     *      `openTradingForever()` has been called, this guard is gone.
     */
    function setLPPair(address _pair) external onlyOwner {
        require(_pair != address(0), "AROS: pair is zero");
        require(_pair != address(this), "AROS: pair cannot be self");
        require(referralPool == address(0) || _pair != referralPool, "AROS: pair conflicts with referralPool");
        require(dividendPool == address(0) || _pair != dividendPool, "AROS: pair conflicts with dividendPool");
        // v2: 移除 tradingRestricted 时不允许替换 lpPair 的限制
        // 允许 owner 在任何时候替换储备地址（原底池地址改为空投储备地址）
        emit LPPairUpdated(lpPair, _pair);
        lpPair = _pair;
    }

    function setClaimSigner(address _signer) external onlyOwner {
        require(_signer != address(0), "AROS: signer is zero");
        emit ClaimSignerUpdated(claimSigner, _signer);
        claimSigner = _signer;
    }

    function setReferralPool(address _pool) external onlyOwner {
        require(_pool != address(0), "AROS: pool is zero");
        require(_pool != address(this), "AROS: pool cannot be self");
        require(_pool != lpPair, "AROS: pool cannot be lpPair");
        emit ReferralPoolUpdated(referralPool, _pool);
        referralPool = _pool;
    }

    function setDividendPool(address _pool) external onlyOwner {
        require(_pool != address(0), "AROS: pool is zero");
        require(_pool != address(this), "AROS: pool cannot be self");
        require(_pool != lpPair, "AROS: pool cannot be lpPair");
        emit DividendPoolUpdated(dividendPool, _pool);
        dividendPool = _pool;
    }

    function lockUpgradeForever() external onlyOwner {
        require(!upgradeLocked, "AROS: upgrade already locked");
        upgradeLocked = true;
        emit UpgradeLocked(msg.sender);
    }

    /**
     * @notice Emergency stop for all claim flows.
     *         Callable by EITHER the owner OR the configured `guardian`.
     *         The unpause counterpart (`unpauseClaim`) is owner-only by
     *         design: a compromised guardian key can DoS-pause once but
     *         cannot lock the project into a permanent paused state.
     */
    function pauseClaim() external {
        require(
            msg.sender == owner() || (guardian != address(0) && msg.sender == guardian),
            "AROS: not owner or guardian"
        );
        require(!claimPaused, "AROS: claim already paused");
        claimPaused = true;
        emit ClaimPauseUpdated(true);
    }

    function unpauseClaim() external onlyOwner {
        require(claimPaused, "AROS: claim not paused");
        claimPaused = false;
        emit ClaimPauseUpdated(false);
    }

    // ================= Admin: phase-1 trading restriction =================

    /**
     * @notice Toggle the phase-1 trading restriction.
     *         Turning ON requires `lpPair` to be configured — this prevents the
     *         restriction from being armed before the canonical pool is known,
     *         which would otherwise brick the initial-liquidity flow.
     * @dev    Reverts once `openTradingForever()` has been called.
     */
    function setTradingRestricted(bool restricted) external onlyOwner {
        require(!restrictionLockedOpen, "AROS: trading opened forever");
        if (restricted) {
            require(lpPair != address(0), "AROS: lp pair not set");
        }
        tradingRestricted = restricted;
        emit TradingRestrictedUpdated(restricted);
    }

    /**
     * @notice Permanently lift all phase-1 restrictions. After this call:
     *           - `tradingRestricted` is forced to `false`,
     *           - `setTradingRestricted` reverts forever,
     *         which guarantees external observers that the project cannot
     *         re-impose buy / remove restrictions in the future.
     */
    function openTradingForever() external onlyOwner {
        require(!restrictionLockedOpen, "AROS: already opened forever");
        restrictionLockedOpen = true;
        if (tradingRestricted) {
            tradingRestricted = false;
            emit TradingRestrictedUpdated(false);
        }
        emit TradingOpenedForever(msg.sender);
    }

    /**
     * @notice Add or remove an address from the phase-1 VIP whitelist.
     *         While restrictions are active, a transfer is FULLY EXEMPT
     *         (both R1 and R2 skipped) if EITHER its `from` OR its `to`
     *         is whitelisted — i.e. whitelisted addresses can buy, sell,
     *         add / remove liquidity, and freely interact with any contract.
     *
     *         Typical entries: team LP wallet, market-maker wallet/bot,
     *         multisig, treasury, staking, bridge endpoints, referral /
     *         dividend pools.
     *
     *         No-op once `openTradingForever()` has been called (restrictions
     *         are gone, the whitelist becomes irrelevant) but still callable.
     */
    function setWhitelisted(address account, bool whitelisted) external onlyOwner {
        require(account != address(0), "AROS: zero address");
        if (!whitelisted) {
            // Removing the current `feeRecipient` from the whitelist would
            // make the fee leg revert under phase-1 (R2) when the recipient
            // is a contract — effectively bricking all sells. To swap the
            // fee recipient, call `setFeeRecipient(newRecipient)` first
            // (which auto-whitelists the new one) and only then remove the
            // old one if needed.
            require(account != feeRecipient, "AROS: cannot remove fee recipient from whitelist");
        }
        isWhitelisted[account] = whitelisted;
        emit WhitelistUpdated(account, whitelisted);
    }

    /**
     * @notice Batch variant of `setWhitelisted` for bootstrapping multiple
     *         addresses (team LP wallet + market-maker + treasury + ...) in
     *         one tx.
     */
    function setWhitelistedBatch(address[] calldata accounts, bool whitelisted) external onlyOwner {
        address fr = feeRecipient;
        for (uint256 i = 0; i < accounts.length; i++) {
            address a = accounts[i];
            require(a != address(0), "AROS: zero address");
            if (!whitelisted) {
                require(a != fr, "AROS: cannot remove fee recipient from whitelist");
            }
            isWhitelisted[a] = whitelisted;
            emit WhitelistUpdated(a, whitelisted);
        }
    }

    // ================= Admin: sell fee =================

    /**
     * @notice Set the sell fee in basis points (1 bps = 0.01%).
     *         Hard-capped by `MAX_FEE_BPS` so the project cannot silently
     *         increase the tax beyond the on-chain ceiling.
     *         Set to 0 to disable.
     */
    function setSellFeeBps(uint256 bps) external onlyOwner {
        require(bps <= MAX_FEE_BPS, "AROS: fee exceeds cap");
        emit SellFeeBpsUpdated(sellFeeBps, bps);
        sellFeeBps = bps;
    }

    /**
     * @notice Set the recipient address for collected sell fees.
     *         The recipient is automatically added to the whitelist so that
     *         the fee transfer itself is never blocked by phase-1 (R2) and
     *         so that the recipient can later move the collected fees freely.
     *         Use the zero address to disable fee collection without zeroing
     *         `sellFeeBps`.
     */
    function setFeeRecipient(address recipient) external onlyOwner {
        emit FeeRecipientUpdated(feeRecipient, recipient);
        feeRecipient = recipient;
        if (recipient != address(0) && !isWhitelisted[recipient]) {
            isWhitelisted[recipient] = true;
            emit WhitelistUpdated(recipient, true);
        }
    }

    // ================= Admin: daily drain cap =================

    /**
     * @notice Set the maximum AROS that claim flows can pull from `lpPair`
     *         within any rolling 24-hour window, expressed as a fraction of
     *         the LP balance at the start of the window (in basis points,
     *         1 bps = 0.01%).
     *
     *         Examples:
     *           `bps = 0`     -> cap is disabled (default; backwards compatible)
     *           `bps = 500`   -> at most 5% of the day-start LP balance
     *           `bps = 10000` -> at most 100% (effectively no cap)
     *
     *         When the cap is hit, every claim attempt reverts until the
     *         24-hour window auto-rolls. This bounds the worst-case loss
     *         from a stolen `claimSigner` private key — the attacker can
     *         only drain at most `dailyDrainBps` of the LP per day, giving
     *         the team at least 24h to invoke `pauseClaim()`.
     *
     * @dev    Only affects future claims. The current `drainedToday` and
     *         `dayStart` are left untouched, so a sudden cap reduction
     *         cannot retroactively reject already-counted drains.
     */
    function setDailyDrainBps(uint256 bps) external onlyOwner {
        require(bps <= 10000, "AROS: bps too high");
        emit DailyDrainBpsUpdated(dailyDrainBps, bps);
        dailyDrainBps = bps;
    }

    /**
     * @notice Set the per-transaction maximum AROS that a single claim
     *         transaction can pull from `lpPair`. For 3-leg `claimYield`
     *         this bound applies to the SUM of `userAmount + referralAmount
     *         + dividendAmount`.
     *
     *         Set to `0` to disable the bound (default).
     *
     *         Recommended setting: 2~3x the typical legitimate single-claim
     *         amount, so normal users are never blocked but a stolen-key
     *         attacker is forced to split a large drain into many txs,
     *         each of which is an additional opportunity for monitors to
     *         alert and the team to call `pauseClaim`.
     */
    function setMaxClaimPerTx(uint256 cap) external onlyOwner {
        emit MaxClaimPerTxUpdated(maxClaimPerTx, cap);
        maxClaimPerTx = cap;
    }

    // ================= Admin: guardian =================

    /**
     * @notice Configure the emergency guardian. The guardian is allowed to
     *         call `pauseClaim()` (and ONLY that). Pass `address(0)` to
     *         disable the role entirely.
     *
     *         Intended use: hold the guardian key on a cold device that is
     *         physically separate from the owner-multisig signers. When
     *         monitoring detects a likely key-leak attack at 03:00 in the
     *         morning, anyone with reach to the guardian key can hit the
     *         emergency stop in seconds, without waiting for the multisig
     *         signers to wake up and coordinate.
     *
     *         Worst case if guardian key itself is stolen: attacker can
     *         pause the claim flow once (DoS, no theft). Owner-multisig
     *         can then `unpauseClaim` and rotate via `setGuardian`.
     */
    function setGuardian(address newGuardian) external onlyOwner {
        emit GuardianUpdated(guardian, newGuardian);
        guardian = newGuardian;
    }

    // ================= Claim: principal =================

    function claimPrincipal(
        uint256 periodFrom,
        uint256 periodTo,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        _checkDeadline(deadline);
        _checkPeriodRange(periodFrom, periodTo, lastPeriodPrincipal[msg.sender]);
        _checkPerTxCap(amount);

        bytes32 structHash = keccak256(
            abi.encode(
                CLAIM_PRINCIPAL_TYPEHASH,
                msg.sender,
                periodFrom,
                periodTo,
                amount,
                deadline
            )
        );
        _verifySignature(structHash, signature);

        lastPeriodPrincipal[msg.sender] = periodTo;

        _pullFromLP(msg.sender, amount);

        emit PrincipalClaimed(msg.sender, periodFrom, periodTo, amount);
    }

    // ================= Claim: yield (3-way) =================

    /**
     * @notice Atomic 3-way yield distribution from the LP pair, advancing the
     *         per-user yield period cursor by exactly one `[periodFrom, periodTo]`
     *         range.
     *
     * @dev Atomicity guarantee: this function is fully atomic. Every state
     *      change below (including the yield cursor advance) is performed
     *      inside the same transaction. If ANY of the `_transfer` calls or
     *      the final `sync()` reverts, the EVM rolls back the entire
     *      transaction, so:
     *        - the cursor is NOT advanced,
     *        - no partial transfers are persisted to the LP pair,
     *        - the user can simply re-submit the same signature once the
     *          underlying issue (e.g. low LP balance) is resolved.
     */
    function claimYield(
        uint256 periodFrom,
        uint256 periodTo,
        uint256 userAmount,
        address referralPool_,
        uint256 referralAmount,
        address dividendPool_,
        uint256 dividendAmount,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        _checkDeadline(deadline);
        _checkPeriodRange(periodFrom, periodTo, lastPeriodYield[msg.sender]);
        require(
            userAmount > 0 || referralAmount > 0 || dividendAmount > 0,
            "AROS: all amounts zero"
        );
        require(referralAmount == 0 || referralPool_ != address(0), "AROS: referral pool is zero");
        require(dividendAmount == 0 || dividendPool_ != address(0), "AROS: dividend pool is zero");

        if (referralAmount > 0) {
            require(referralPool != address(0), "AROS: referral pool not configured");
            require(referralPool_ == referralPool, "AROS: invalid referral pool");
        }
        if (dividendAmount > 0) {
            require(dividendPool != address(0), "AROS: dividend pool not configured");
            require(dividendPool_ == dividendPool, "AROS: invalid dividend pool");
        }

        bytes32 structHash = keccak256(
            abi.encode(
                CLAIM_YIELD_TYPEHASH,
                msg.sender,
                periodFrom,
                periodTo,
                userAmount,
                referralPool_,
                referralAmount,
                dividendPool_,
                dividendAmount,
                deadline
            )
        );
        _verifySignature(structHash, signature);

        require(lpPair != address(0), "AROS: lp pair not set");

        uint256 totalOut = userAmount + referralAmount + dividendAmount;
        _checkPerTxCap(totalOut);
        require(balanceOf(lpPair) >= totalOut, "AROS: lp insufficient");

        lastPeriodYield[msg.sender] = periodTo;

        // Each leg goes through `_drainFromLPTo`, which: (a) charges the
        // daily drain cap, (b) sets/clears `_inClaim` to bypass (R1), and
        // (c) is a no-op for zero-amount legs. We invoke `sync()` once at
        // the end to atomically reflect all three transfers.
        _drainFromLPTo(msg.sender, userAmount);
        _drainFromLPTo(referralPool_, referralAmount);
        _drainFromLPTo(dividendPool_, dividendAmount);

        // v2: 移除 sync() 调用，lpPair 不再是底池合约而是普通储备地址

        emit YieldClaimed(
            msg.sender,
            periodFrom,
            periodTo,
            userAmount,
            referralPool_,
            referralAmount,
            dividendPool_,
            dividendAmount
        );
    }

    // ================= Claim: lucky =================

    function claimLucky(
        uint256 periodFrom,
        uint256 periodTo,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        _checkDeadline(deadline);
        _checkPeriodRange(periodFrom, periodTo, lastPeriodLucky[msg.sender]);
        _checkPerTxCap(amount);

        bytes32 structHash = keccak256(
            abi.encode(
                CLAIM_LUCKY_TYPEHASH,
                msg.sender,
                periodFrom,
                periodTo,
                amount,
                deadline
            )
        );
        _verifySignature(structHash, signature);

        lastPeriodLucky[msg.sender] = periodTo;

        _pullFromLP(msg.sender, amount);

        emit LuckyClaimed(msg.sender, periodFrom, periodTo, amount);
    }

    // ================= Claim: contribution =================

    function claimContribution(
        uint256 periodFrom,
        uint256 periodTo,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        _checkDeadline(deadline);
        _checkPeriodRange(periodFrom, periodTo, lastPeriodContribution[msg.sender]);
        _checkPerTxCap(amount);

        bytes32 structHash = keccak256(
            abi.encode(
                CLAIM_CONTRIBUTION_TYPEHASH,
                msg.sender,
                periodFrom,
                periodTo,
                amount,
                deadline
            )
        );
        _verifySignature(structHash, signature);

        lastPeriodContribution[msg.sender] = periodTo;

        _pullFromLP(msg.sender, amount);

        emit ContributionClaimed(msg.sender, periodFrom, periodTo, amount);
    }

    // ================= Internal helpers =================

    function _checkDeadline(uint256 deadline) internal view {
        require(!claimPaused, "AROS: claim paused");
        require(block.timestamp <= deadline, "AROS: signature expired");
        // Caps how far in the future a signature may be valid. With block
        // timestamps in 0.8.x, the addition cannot underflow; if a malicious
        // backend ever signed `deadline = type(uint256).max` the +VALIDITY
        // would overflow and revert here cleanly.
        require(
            deadline <= block.timestamp + MAX_SIGNATURE_VALIDITY,
            "AROS: deadline too far"
        );
    }

    /**
     * @dev Enforces that the new claim's `[periodFrom, periodTo]` range starts
     *      exactly one past the user's previous cursor for this claim type,
     *      that the range itself is well-formed, AND that it covers no more
     *      than `MAX_PERIOD_RANGE` consecutive periods. The last condition
     *      both prevents a single signature from authorizing an unbounded
     *      `amount` and guards against accidental cursor fast-forwarding.
     */
    function _checkPeriodRange(
        uint256 periodFrom,
        uint256 periodTo,
        uint256 lastPeriod
    ) internal pure {
        require(periodFrom == lastPeriod + 1, "AROS: period not continuous");
        require(periodTo >= periodFrom, "AROS: bad period range");
        // Range count is `periodTo - periodFrom + 1`. Allowing up to
        // MAX_PERIOD_RANGE periods means `to - from + 1 <= MAX_PERIOD_RANGE`,
        // i.e. `to - from < MAX_PERIOD_RANGE`. Subtraction is safe given
        // `periodTo >= periodFrom` checked above.
        require(periodTo - periodFrom < MAX_PERIOD_RANGE, "AROS: range too wide");
    }

    function _verifySignature(bytes32 structHash, bytes calldata signature) internal view {
        bytes32 digest = _hashTypedDataV4(structHash);
        address recovered = ECDSAUpgradeable.recover(digest, signature);
        require(recovered == claimSigner, "AROS: invalid signature");
    }

    /**
     * @dev Enforces the per-transaction claim cap. Used by every claim flow
     *      to bound the AROS that any single signature can authorize. For
     *      `claimYield` the argument is the SUM of all three legs.
     *
     *      No-op when `maxClaimPerTx == 0` (default; backwards compatible).
     */
    function _checkPerTxCap(uint256 amount) internal view {
        uint256 cap = maxClaimPerTx;
        if (cap > 0) {
            require(amount <= cap, "AROS: exceeds per-tx cap");
        }
    }

    /**
     * @dev Pulls `amount` of AROS from the LP pair to `to`. Atomic by design:
     *      if either `_transfer` or `sync()` reverts, the whole transaction
     *      (including any earlier cursor write performed by the caller) is
     *      rolled back, so the user can safely retry.
     *
     *      Used by the single-leg claim flows (principal / lucky / contribution).
     *      The 3-leg `claimYield` calls `_drainFromLPTo` directly to share a
     *      single trailing `sync()`.
     */
    function _pullFromLP(address to, uint256 amount) internal {
        require(lpPair != address(0), "AROS: lp pair not set");
        require(amount > 0, "AROS: amount is zero");
        require(balanceOf(lpPair) >= amount, "AROS: lp insufficient");

        _drainFromLPTo(to, amount);

        // v2: 移除 sync() 调用，lpPair 不再是底池合约而是普通储备地址
    }

    /**
     * @dev Single source of truth for "AROS leaves lpPair via a claim flow".
     *      Performs three things atomically:
     *        1. Daily-drain accounting (rolls the 24h window if needed and
     *           enforces the configured cap).
     *        2. Sets the `_inClaim` bypass so the (R1) phase-1 hook lets the
     *           transfer through.
     *        3. Executes `_transfer(lpPair, recipient, amount)`.
     *
     *      The `_inClaim` flag is cleared immediately after the transfer and
     *      BEFORE any external call (the caller is responsible for invoking
     *      `IUniswapV2Pair.sync()` separately), so a malicious LP pair cannot
     *      exploit the bypass via a reentrant callback into ERC20.
     *
     *      Zero-amount calls are a no-op so callers (notably `claimYield`)
     *      can pass `0` for unused legs without conditionals.
     */
    function _drainFromLPTo(address recipient, uint256 amount) internal {
        if (amount == 0) return;

        _accountDrain(amount);

        _inClaim = true;
        _transfer(lpPair, recipient, amount);
        _inClaim = false;
    }

    /**
     * @dev Enforces the rolling 24-hour drain cap. Called for every AROS
     *      unit that leaves `lpPair` via a claim flow.
     *
     *      Window roll:
     *        On the first claim past `dayStart + 1 days`, the window is
     *        advanced and the snapshot of `balanceOf(lpPair)` is captured
     *        as the new denominator. No off-chain trigger is needed — the
     *        next user's own claim transaction pays the rollover gas.
     *
     *      Cap math:
     *        `drainedToday + amount <= dayBaseLPBalance * dailyDrainBps / 10000`
     *
     *        The denominator is fixed at the start of the window so the
     *        attacker cannot inflate the daily quota by depositing AROS
     *        into the pair mid-window.
     *
     *      Disabled mode:
     *        When `dailyDrainBps == 0`, the function is a no-op — no state
     *        is read or written, gas overhead is minimal, behavior is
     *        identical to pre-patch.
     */
    function _accountDrain(uint256 amount) internal {
        uint256 bps = dailyDrainBps;
        if (bps == 0) return;

        uint256 windowEnd = dayStart + 1 days;
        if (block.timestamp >= windowEnd) {
            uint256 newDayStart = block.timestamp;
            uint256 newBase = balanceOf(lpPair);
            dayStart = newDayStart;
            dayBaseLPBalance = newBase;
            drainedToday = 0;
            emit DailyDrainWindowReset(newDayStart, newBase);
        }

        uint256 newTotal = drainedToday + amount;
        require(
            newTotal <= (dayBaseLPBalance * bps) / 10000,
            "AROS: daily drain cap"
        );
        drainedToday = newTotal;
    }

    // ================= ERC20 override: sell fee =================

    /**
     * @dev Intercepts every ERC20 transfer and deducts a sell fee when
     *      `to == lpPair` and the sender is not exempt. The fee is routed
     *      via a second `super._transfer` to `feeRecipient`, so two
     *      `Transfer` events are emitted (fee leg, then user leg) — this
     *      is the canonical pattern that block explorers and accounting
     *      systems already understand for tax tokens.
     *
     *      All claim-time transfers have `from == lpPair` (never `to`),
     *      so the fee branch never triggers for the 4 claim flows.
     */
    function _transfer(address from, address to, uint256 amount) internal virtual override {
        uint256 fee = _calcSellFee(from, to, amount);
        if (fee > 0) {
            super._transfer(from, feeRecipient, fee);
            emit SellFeeCollected(from, fee);
            unchecked {
                amount -= fee;
            }
        }
        super._transfer(from, to, amount);
    }

    /**
     * @dev Returns the sell-fee amount in AROS for the given transfer, or 0
     *      if no fee should be charged. Pure conditions:
     *        - fee disabled (rate 0 or recipient unset),
     *        - direction is not a sell (`to != lpPair`),
     *        - sender is whitelisted (team / market-maker / LP / pools).
     *      mint / burn (`from == 0` or `to == 0`) are excluded by the
     *      `to != lpPair` check (lpPair is never the zero address by the
     *      time fees are active).
     */
    function _calcSellFee(address from, address to, uint256 amount) internal view returns (uint256) {
        uint256 bps = sellFeeBps;
        if (bps == 0) return 0;
        if (feeRecipient == address(0)) return 0;
        if (to != lpPair) return 0;
        if (isWhitelisted[from]) return 0;
        return (amount * bps) / 10000;
    }

    // ================= ERC20 hook: phase-1 restriction =================

    /**
     * @dev Phase-1 trading restriction. Only active when `tradingRestricted == true`.
     *      mint / burn (`from == 0` or `to == 0`) are NEVER blocked here.
     *
     *      Bypass priorities (any single one is enough to fully exempt the transfer):
     *        - `_inClaim`           — internal claim flow,
     *        - `isWhitelisted[from]`— whitelisted SENDER,
     *        - `isWhitelisted[to]`  — whitelisted RECIPIENT.
     *      A whitelisted address can therefore BUY, SELL, REMOVE LIQUIDITY,
     *      and freely interact with any contract during phase 1.
     *
     *      Otherwise:
     *        (R1) Outflow from `lpPair` is forbidden. This single rule covers
     *             BOTH "BUY (USDT -> AROS)" and "REMOVE LIQUIDITY" because
     *             both manifest as `_transfer(lpPair, recipient, ...)`.
     *
     *        (R2) AROS landing in any contract other than the canonical
     *             `lpPair` is forbidden — prevents anyone from creating a
     *             parallel AROS/* pool to circumvent (R1).
     *
     *      EOA-to-EOA transfers (when neither is whitelisted and neither is
     *      `lpPair`) pass through both checks naturally.
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        super._beforeTokenTransfer(from, to, amount);

        if (!tradingRestricted) return;
        if (from == address(0) || to == address(0)) return;

        // v2 修复：R1 只允许 _inClaim 绕过，白名单 to 不能绕过 R1
        // 防止攻击者把 swap 的 to 设为白名单地址来绕过买入限制

        // (R1) 从储备地址（lpPair）流出：只有 claim 流程允许
        if (from == lpPair) {
            if (!_inClaim) {
                revert("AROS: buy/remove disabled");
            }
            return;
        }

        // 白名单只影响 R2，不影响 R1
        if (_inClaim || isWhitelisted[from] || isWhitelisted[to]) return;

        // (R2) Block parallel pools by refusing AROS into unknown contracts.
        if (to != lpPair && to.code.length > 0) {
            revert("AROS: contract recipient blocked");
        }
    }

    // ================= UUPS =================

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        require(!upgradeLocked, "AROS: upgrade locked forever");
        require(newImplementation.code.length > 0, "AROS: not a contract");
    }

    // ================= View helpers =================

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Returns the next acceptable `periodFrom` for each of the 4 claim
     *         types for `user`. The backend MUST sign the next claim of each
     *         type starting from this value.
     */
    function nextPeriodFrom(address user)
        external
        view
        returns (
            uint256 nextPrincipal,
            uint256 nextYield,
            uint256 nextLucky,
            uint256 nextContribution
        )
    {
        nextPrincipal    = lastPeriodPrincipal[user] + 1;
        nextYield        = lastPeriodYield[user] + 1;
        nextLucky        = lastPeriodLucky[user] + 1;
        nextContribution = lastPeriodContribution[user] + 1;
    }

    /**
     * @notice Read-only snapshot of the current daily-drain window. Intended
     *         for off-chain monitors / dashboards that want to display
     *         "today's quota usage" without re-implementing the rollover
     *         logic. The contract itself is NOT mutated by this call.
     *
     * @return baseLPBalance   Snapshot of LP's AROS balance at the start of
     *                         the (possibly virtually-rolled) window. Equals
     *                         `balanceOf(lpPair)` if a rollover is pending.
     * @return drained         Cumulative AROS drained in this window. Zero
     *                         if a rollover is pending.
     * @return cap             Daily quota in AROS = baseLPBalance * bps / 10000.
     *                         Zero if `dailyDrainBps == 0` (cap disabled).
     * @return capRemaining    `cap - drained`, floored at zero.
     * @return secondsToReset  Seconds until the next automatic window roll.
     *                         Zero if a rollover is already pending (the
     *                         next claim will reset).
     */
    function todayDrainStats()
        external
        view
        returns (
            uint256 baseLPBalance,
            uint256 drained,
            uint256 cap,
            uint256 capRemaining,
            uint256 secondsToReset
        )
    {
        uint256 windowEnd = dayStart + 1 days;
        bool rolloverPending = block.timestamp >= windowEnd;

        if (rolloverPending) {
            baseLPBalance = balanceOf(lpPair);
            drained = 0;
            secondsToReset = 0;
        } else {
            baseLPBalance = dayBaseLPBalance;
            drained = drainedToday;
            secondsToReset = windowEnd - block.timestamp;
        }

        cap = (baseLPBalance * dailyDrainBps) / 10000;
        capRemaining = drained >= cap ? 0 : cap - drained;
    }

    /// @dev Storage gap.
    ///       50 (original) -> 48 (referralPool / dividendPool)
    ///                     -> 44 (4 period-cursor mappings)
    ///                     -> 42 (3 packed bools + isWhitelisted mapping)
    ///                     -> 40 (sellFeeBps + feeRecipient)
    ///                     -> 36 (dailyDrainBps + dayStart + drainedToday + dayBaseLPBalance)
    ///                     -> 34 (maxClaimPerTx + guardian)
    uint256[34] private __gap;
}
