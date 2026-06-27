// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {TokenDistributor} from "./TokenDistributor.sol";
import {IUniswapV2Router} from "./interfaces/IUniswapV2Router.sol";
import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IWETH} from "./interfaces/IWETH.sol";

interface IJoeAgentDividendHook {
    function setLPWeight(address account, uint256 weight) external;
}

interface IJoeAgentNodeRegistryHook {
    function registered(address user) external view returns (bool);
    function inviterOf(address user) external view returns (address);
    function isEligibleLpParent(address parent) external view returns (bool);
    function bindParentForLp(address user, address parent) external;
}

interface IJoeAgentStakingHook {
    function setWalletLpValue(address user, uint256 newValue) external;
}

contract JoeAgentToken is
    Initializable,
    ERC20Upgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    uint256 private constant DIVIDEND_WEIGHT_SCALE = 1 ether;

    struct Fee {
        uint256 high;    // 0~30min
        uint256 middle;  // 30min~24h
        uint256 normal;  // after 24h
    }

    struct LPInfo {
        uint256 lpAmount;         // protocol-held LP units credited to the account
        uint256 lastAddLpTime;
    }

    uint256 public constant TOTAL_SUPPLY = 210_000_000 * 1 ether;
    uint256 public constant BASE_FEE = 10_000;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ---- v7.5 launch (硬编码) ----
    /// 2026-05-07 20:30:00 CST = 12:30:00 UTC = unix 1778157000。
    /// `_beforeTokenTransfer` 在第一笔涉及 pair 的 tx 中 lazy 把
    /// `startTradeBlock / startTradeTime` 锚定到此值，无需 owner 调
    /// `startTrade()`。
    uint256 public constant TRADING_START_TS = 1778157000;
    /// 4 阶税衰减时长（每阶 1h，4h 后回落 normal 默认）。
    uint256 public constant LAUNCH_TIER_STEP = 1 hours;
    /// 默认早期窗口长度（5 min）；当 `earlyTradingDuration == 0` 用此兜底。
    uint256 public constant DEFAULT_EARLY_TRADING_DURATION = 5 minutes;

    // Configurable time/fee durations (Owner can adjust for testing)
    uint256 public highFeeDuration;    // default 1800 (30 min)
    uint256 public middleFeeDuration;  // default 86400 (24h)
    uint256 public dayDuration;        // default 86400 (1 day), test: 3600 (1h)
    uint256 public lpWeightBase;       // native-asset value that equals 1 LP dividend weight

    uint256 public startTradeBlock;
    uint256 public startTradeTime;
    uint256 public limitAmount;

    // Daily auto-burn: 0.1% of circulating supply
    uint256 public lastBurnDay;
    uint256 public dailyBurnRate;

    // Swap control
    uint256 public minSwapOut;
    uint256 public swapOutLimit;

    address public WETH;

    address public mainPair;
    address public dividendContract;
    address public idoContract;
    address public nftContract;
    address public nodeRegistry;
    address public stakingContract;
    address public entryContract;

    Fee public buyFee;
    Fee public sellFee;
    Fee public transferFee;
    Fee public removeFee;

    IUniswapV2Router public uniswapV2Router;
    TokenDistributor public tokenDistributor;

    mapping(address => bool) public pairs;
    mapping(address => bool) public whiteList;
    mapping(address => bool) public blackList;
    mapping(address => LPInfo) public lpInfo;
    mapping(address => uint256) public lpPrincipalValue;
    uint256 public lastPairTotalSupply;

    // ---- v7.5 launch additions (append-only — storage layout safe for UUPS) ----
    /// 早期窗口白名单（与 `whiteList` 完全独立——不影响税收豁免）。仅在
    /// `[TRADING_START_TS, TRADING_START_TS + earlyTradingDuration)` 内门禁。
    mapping(address => bool) public tradingWhitelist;
    /// 早期窗口长度，0 视为默认 5 min（兜底，避免必须 init 调用）。
    uint256 public earlyTradingDuration;

    bool private inSwap;
    modifier lockTheSwap() {
        inSwap = true;
        _;
        inSwap = false;
    }

    modifier onlyEntry() {
        require(msg.sender == entryContract, "only entry");
        _;
    }

    event DailyBurn(uint256 day, uint256 amount);
    event TaxCollected(address from, uint256 amount, string taxType);
    event LPWeightBaseUpdated(uint256 amount);
    event NodeRegistryUpdated(address indexed registry);
    event StakingContractUpdated(address indexed staking);
    event EntryContractUpdated(address indexed entry);
    event LPValueObserved(address indexed account, uint256 lpValue, bool registrySyncOk);
    event FeeSwapProcessed(uint256 tokenAmount, uint256 nativeAmount);
    event ProtocolLpPositionUpdated(address indexed account, uint256 lpUnits, uint256 lpValue);
    event NativeZapForLP(
        address indexed account,
        address indexed parent,
        uint256 nativeIn,
        uint256 tokenBought,
        uint256 tokenUsed,
        uint256 nativeUsed,
        uint256 lpBalance,
        uint256 effectiveLpValue
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initOwner,
        address router,
        address weth
    ) external initializer {
        __ERC20_init("Joe Agent", "JOE");
        __Ownable_init(initOwner);

        dailyBurnRate = 10;
        minSwapOut = 0.01 ether;
        swapOutLimit = 1 ether;
        highFeeDuration = 30 minutes;
        middleFeeDuration = 24 hours;
        dayDuration = 1 days;
        lpWeightBase = 1 ether;

        WETH = weth;
        uniswapV2Router = IUniswapV2Router(router);

        // v7.0 pair-poisoning hardening: the LP pair is NOT created at
        // `initialize` time. A pair that exists in Phase 0/1 is a public
        // attack surface — anyone can `weth.transfer(pair, 1 wei)` +
        // `pair.sync()` to make reserves non-zero, which breaks
        // `ido.finalizeLaunch`'s strict `tokenUsed == tokenAmount`
        // assertion. Instead, pair is lazily created by `createMainPair`
        // (owner or IDO contract) in the same transaction that injects
        // its initial real liquidity. See `JoeAgentIDO.finalizeLaunch`.
        // `mainPair` stays at address(0) until that call runs.

        _mint(initOwner, TOTAL_SUPPLY);

        tokenDistributor = new TokenDistributor();

        whiteList[address(this)] = true;
        whiteList[address(0)] = true;
        whiteList[DEAD] = true;
        whiteList[initOwner] = true;
        whiteList[address(tokenDistributor)] = true;

        buyFee = Fee(1500, 200, 200);
        sellFee = Fee(1500, 1000, 200);
        transferFee = Fee(0, 0, 200);
        removeFee = Fee(0, 0, 200);

        limitAmount = type(uint256).max;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Implementation version. Increment on each upgrade for tracking.
    function version() external pure virtual returns (string memory) {
        return "7.6.0-burn-half-tax";
    }

    // ---- v7.5 launch helpers ----
    /// 5 min 早期窗口门禁（双向）。仅在 `[startTradeTime, startTradeTime + d)`
    /// 内对非 tradingWhitelist 用户 revert；窗口外完全无开销。
    function _enforceEarlyWindow(address party) internal view {
        uint256 d = earlyTradingDuration;
        if (d == 0) d = DEFAULT_EARLY_TRADING_DURATION;
        if (block.timestamp < startTradeTime + d) {
            require(tradingWhitelist[party], "early window: not whitelisted");
        }
    }

    function setTradingWhitelist(address[] calldata addrs, bool flag) external onlyOwner {
        for (uint256 i; i < addrs.length; ++i) tradingWhitelist[addrs[i]] = flag;
        emit TradingWhitelistUpdated(addrs.length, flag);
    }

    function setEarlyTradingDuration(uint256 d) external onlyOwner {
        emit EarlyTradingDurationUpdated(earlyTradingDuration, d);
        earlyTradingDuration = d;
    }

    event TradingWhitelistUpdated(uint256 count, bool flag);
    event EarlyTradingDurationUpdated(uint256 oldD, uint256 newD);

    function transfer(address to, uint256 value) public virtual override returns (bool) {
        address from = _msgSender();
        uint256 newValue = _beforeTokenTransfer(from, to, value);
        _transfer(from, to, newValue);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public virtual override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        uint256 newValue = _beforeTokenTransfer(from, to, value);
        _transfer(from, to, newValue);
        return true;
    }

    /// @dev Lazy-discover the canonical factory pair and register it.
    /// Called from `_beforeTokenTransfer` (transfer hook) AND from any
    /// internal path that depends on `mainPair` being populated before
    /// it executes (e.g. `addLiquidityViaContract` reads
    /// `IERC20(mainPair).balanceOf(...)` before the hook gets a chance
    /// to run). Idempotent — once `mainPair` is cached, this is a
    /// trivial SLOAD.
    function _ensureMainPair() internal {
        if (mainPair != address(0)) return;
        address factoryPair = IUniswapV2Factory(uniswapV2Router.factory())
            .getPair(address(this), WETH);
        if (factoryPair != address(0)) {
            mainPair = factoryPair;
            pairs[factoryPair] = true;
            emit MainPairCreated(factoryPair);
        }
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 value
    ) internal returns (uint256 newValue) {
        // v7.0 pair-poisoning hardening (round 3):
        //
        // An attacker can call the permissionless `factory.createPair`
        // ahead of the owner's `createMainPair`. Until `createMainPair`
        // runs, `mainPair == address(0)` and `pairs[]` is empty — so a
        // naive `pairs[from] / pairs[to]` check would treat the
        // attacker-created pair as a regular address and let them use
        // the canonical V2 router to add LP or swap pre-launch.
        //
        // We close that by lazy-discovering the canonical factory pair
        // on every transfer (while `mainPair == address(0)`) and
        // registering it in `pairs[]` the first time we see it. After
        // adoption, the buy/sell branches below fire with the real
        // `startTradeBlock > 0` gate and block all external use.
        //
        // Discovery MUST run before the whitelist early-return below,
        // otherwise the owner's own pre-seed via
        // `addLiquidityViaContract` (which is whitelist-bypassed) would
        // skip adoption, and any subsequent attacker swap through the
        // canonical router would remain unblocked.
        //
        // Gas: one SLOAD + one STATICCALL to factory while mainPair
        // is zero; zero overhead afterwards.
        _ensureMainPair();

        // v7.5: 自动开盘锚定。第一笔涉及 pair 且 block.timestamp >= TRADING_START_TS
        // 的非白名单 tx 触发 lazy 初始化，把 startTradeBlock / startTradeTime
        // 钉到 TRADING_START_TS 自身（不取 block.timestamp 防止首笔交易延迟
        // 导致后面 5min/4h 时序漂移）。无需 owner 手动 startTrade()。
        if (startTradeBlock == 0
            && block.timestamp >= TRADING_START_TS
            && (pairs[from] || pairs[to])) {
            startTradeBlock = block.number;
            startTradeTime = TRADING_START_TS;
        }

        if (whiteList[from] || whiteList[to] || inSwap) {
            return value;
        }
        require(!blackList[from], "blacklisted");

        newValue = value;
        uint256 feeAmount;

        if (pairs[from]) {
            // Buy
            require(startTradeBlock > 0, "trading not started");
            // v7.5: 5min 早期窗口 — 仅 tradingWhitelist 可交易（双向门禁，to 是买家）
            _enforceEarlyWindow(to);
            // v7.5.1: tradingWhitelist 地址**永久豁免税**（让做市/早期合作方无摩擦运营）
            feeAmount = tradingWhitelist[to] ? 0 : _calcFee(buyFee, value);
            if (feeAmount > 0) {
                _transfer(from, address(this), feeAmount);
                emit TaxCollected(from, feeAmount, "buy");
            }
        } else if (pairs[to]) {
            // Sell
            require(startTradeBlock > 0, "trading not started");
            // v7.5: 5min 早期窗口 — 仅 tradingWhitelist 可交易（双向门禁，from 是卖家）
            _enforceEarlyWindow(from);
            // v7.5.1: tradingWhitelist 地址**永久豁免税**
            feeAmount = tradingWhitelist[from] ? 0 : _calcFee(sellFee, value);
            if (feeAmount > 0) {
                _transfer(from, address(this), feeAmount);
                emit TaxCollected(from, feeAmount, "sell");
            }
            // v7.5.3: 累积达阈值时 flush 全部累积 → BNB 进 dividend 池。
            // 仅 SELL 触发：BUY 期间 pair 已锁（UniswapV2 lock 修饰符），
            // hook 内调 router.swap 会 revert "UniswapV2: LOCKED"，物理不可行。
            // SELL hook 在 router 调 pair.swap 之前触发，无锁，可安全 swap。
            // BUY 时累积的 JOE 等下一笔 SELL 触发时一起 flush。
            if (!inSwap && balanceOf(address(this)) >= minSwapOut) {
                _swapTokenForBNB();
            }
        } else {
            // Normal transfer: 2% burn to DEAD
            feeAmount = _calcFee(transferFee, value);
            if (feeAmount > 0) {
                _transfer(from, DEAD, feeAmount);
                emit TaxCollected(from, feeAmount, "transfer_burn");
            }
        }

        newValue = value - feeAmount;

        // Wallet limit check (not for pairs)
        if (!pairs[to] && limitAmount > 0) {
            require(balanceOf(to) + newValue <= limitAmount, "exceeds wallet limit");
        }

        // Try daily auto-burn only on plain wallet-to-wallet transfers.
        // Pair-involved flows (buy / sell / add-LP / remove-LP) are already executing
        // inside the AMM swap/mint/burn flow. Burning from the pair and forcing sync()
        // here would mutate reserves mid-swap and can break the invariant.
        if (!pairs[from] && !pairs[to]) {
            _autoBurnDaily();
        }

        return newValue;
    }

    /// @notice Sync LP weight to dividend contract automatically
    function _syncLPWeight(address account) internal {
        uint256 lpValue = quoteLPValue(account);
        uint256 lpWeight = quoteLPWeight(account);
        if (dividendContract != address(0)) {
            try IJoeAgentDividendHook(dividendContract).setLPWeight(account, lpWeight) {} catch {}
        }

        bool registrySyncOk = false;
        if (stakingContract != address(0)) {
            try IJoeAgentStakingHook(stakingContract).setWalletLpValue(account, lpValue) {
                registrySyncOk = true;
            } catch {}
        }

        emit LPValueObserved(account, lpValue, registrySyncOk);
    }

    /// @notice Return the principal native value attributed to an account's LP rights.
    /// This is tracked by actual net native capital deployed through protocol entrypoints,
    /// not by the live AMM reserve share of the current LP balance.
    function quoteLPValue(address account) public view returns (uint256) {
        return lpPrincipalValue[account];
    }

    /// @notice Return the normalized dividend weight for an LP holder.
    /// Weight is 1e18-scaled, where `lpWeightBase` of native-asset value = 1 LP weight.
    function quoteLPWeight(address account) public view returns (uint256) {
        return _quoteLPWeight(lpPrincipalValue[account]);
    }

    function _quoteLPWeight(uint256 lpValue) internal view returns (uint256) {
        if (lpValue == 0 || lpWeightBase == 0) return 0;
        return (lpValue * DIVIDEND_WEIGHT_SCALE) / lpWeightBase;
    }

    /// v7.5: 4 阶税衰减 — 0/1/2/3h 分段 15%/10%/5%/2%；4h+ 取 `fee.normal`
    /// （当前部署值 normal = 200 wei = 2%，与第 4 阶一致，自然平滑过渡）。
    /// transferFee / removeFee 仍走父类 normal 路径（这两个桶 fee.high/middle
    /// 在生产部署时是 0，所以 4 阶硬编码不会误命中——见下面 `useTier`）。
    function _calcFee(Fee memory fee, uint256 amount) internal view returns (uint256) {
        if (startTradeTime == 0) return 0;

        uint256 elapsed = block.timestamp - startTradeTime;
        uint256 feeRate;

        // 仅当本桶在 high/middle 阶配置了非零率（即 buyFee / sellFee 这两个桶），
        // 才走 4 阶硬编码；否则保持父类 normal 行为（transferFee burn 2% / removeFee）。
        bool useTier = (fee.high > 0 || fee.middle > 0);

        if (useTier) {
            if      (elapsed < LAUNCH_TIER_STEP)       feeRate = 1500; // 0~1h: 15%
            else if (elapsed < 2 * LAUNCH_TIER_STEP)   feeRate = 1000; // 1~2h: 10%
            else if (elapsed < 3 * LAUNCH_TIER_STEP)   feeRate = 500;  // 2~3h: 5%
            else if (elapsed < 4 * LAUNCH_TIER_STEP)   feeRate = 200;  // 3~4h: 2%
            else                                        feeRate = fee.normal; // 4h+: normal
        } else {
            feeRate = fee.normal;
        }

        if (feeRate == 0) return 0;
        return amount * feeRate / BASE_FEE;
    }

    /// v7.6.0: 累积税 1:1 拆分 —— 一半直接 burn 到 dEaD，一半 swap 成 BNB 进分红池。
    /// 业务语义：normal 阶段 2% 税 = 1% JOE 销毁 + 1% BNB 分红。
    /// 早期 4 阶（15/10/5/2%）同样按 1:1 拆分。
    /// 实现安全性：
    ///   * burn 走 `_transfer(this, DEAD, half)`，DEAD 与 address(this) 都在 whiteList，
    ///     且 lockTheSwap 期间 inSwap=true，三重短路 `_takeTransferTax`，无递归。
    function _swapTokenForBNB() private lockTheSwap {
        uint256 tokenBalance = balanceOf(address(this));
        if (tokenBalance == 0) return;

        // 1:1 拆 —— 整除留 1 wei 给 swap，避免 odd 余数累积
        uint256 burnAmount = tokenBalance / 2;
        if (burnAmount > 0) {
            _transfer(address(this), DEAD, burnAmount);
            emit TaxCollected(address(this), burnAmount, "fee_burn");
        }
        uint256 swapAmount = tokenBalance - burnAmount;
        if (swapAmount == 0) return;

        uint256 nativeBefore = dividendContract == address(0) ? 0 : dividendContract.balance;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WETH;

        IERC20(address(this)).approve(address(uniswapV2Router), swapAmount);

        try uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            swapAmount,
            0,
            path,
            address(tokenDistributor),
            block.timestamp + 1
        ) {} catch {}

        // Transfer BNB from distributor to dividend contract.
        // router 的 swapExactTokensForETHSupportingFeeOnTransferTokens 已自动 unwrap，
        // distributor 拿到的是原生 BNB；早期版本误用 WETH.balanceOf 做门槛，
        // 导致 wethBal 永远 0、claimETH 永不调用、BNB 卡在 distributor。
        if (dividendContract != address(0)) {
            uint256 nativeBal = address(tokenDistributor).balance;
            if (nativeBal > 0) {
                tokenDistributor.claimETH(dividendContract, nativeBal, WETH);
            }
        }

        uint256 nativeAfter = dividendContract == address(0) ? 0 : dividendContract.balance;
        emit FeeSwapProcessed(swapAmount, nativeAfter - nativeBefore);
    }

    /// @notice Daily auto-burn 0.1% of circulating supply
    function _autoBurnDaily() internal {
        uint256 today = block.timestamp / dayDuration;
        if (today <= lastBurnDay) return;
        if (startTradeTime == 0) return;

        uint256 pairBalance = balanceOf(mainPair);
        if (pairBalance == 0) return;

        uint256 burnAmount = pairBalance * dailyBurnRate / BASE_FEE;
        if (burnAmount == 0) return;

        lastBurnDay = today;
        _transfer(mainPair, DEAD, burnAmount);
        IUniswapV2Pair(mainPair).sync();

        emit DailyBurn(today, burnAmount);
    }

    /// @notice Trigger the pending daily auto-burn outside AMM swap/mint/burn flows.
    /// Anyone can call this when a new burn day has started.
    function triggerDailyBurn() external {
        _autoBurnDaily();
    }

    /// @notice Swap accumulated fee tokens into the dividend pool outside user swap flows.
    /// Anyone can call this, making fee processing keeper-friendly and AMM-safe.
    function processFeeSwap() external {
        _swapTokenForBNB();
    }

    // ============ Owner Functions ============

    event MainPairCreated(address indexed pair);

    /// @notice Resolve-or-create the AMM pair. MUST be called in the
    /// same transaction that injects the first real liquidity (i.e.
    /// `JoeAgentIDO.finalizeLaunch`), so no attacker has a window in
    /// which an empty-but-existing pair is visible.
    ///
    /// The Uniswap V2 factory is permissionless — an attacker could
    /// front-run this call and pre-create the pair themselves, then
    /// WETH-transfer + `pair.sync()` to poison the reserves. We handle
    /// that by ADOPTING the existing factory pair (if any) instead of
    /// reverting: the actual liquidity injection in `finalizeLaunch`
    /// uses direct `pair.mint(DEAD)` (not the router's ratio-strict
    /// `addLiquidityETH`), which is indifferent to whatever 1-wei
    /// attacker-supplied dust might already be in the pair.
    ///
    /// Permitted callers: owner (for dev / operational override) and
    /// the configured IDO contract.
    function createMainPair() external returns (address) {
        require(
            msg.sender == owner() || msg.sender == idoContract,
            "not authorized"
        );
        require(mainPair == address(0), "pair already created");
        IUniswapV2Factory factoryI = IUniswapV2Factory(uniswapV2Router.factory());
        address existing = factoryI.getPair(address(this), WETH);
        address pair = existing == address(0)
            ? factoryI.createPair(address(this), WETH)
            : existing;
        mainPair = pair;
        pairs[pair] = true;
        emit MainPairCreated(pair);
        return pair;
    }

    function startTrade() external onlyOwner {
        require(startTradeBlock == 0, "already started");
        startTradeBlock = block.number;
        startTradeTime = block.timestamp;
    }

    // Reset trade start state so startTrade() can be called again (for testing tax tiers)
    function resetStartTradeTime() external onlyOwner {
        startTradeBlock = 0;
        startTradeTime = 0;
    }

    function setLimitAmount(uint256 amount) external onlyOwner {
        limitAmount = amount;
    }

    function setDividendContract(address addr) external onlyOwner {
        dividendContract = addr;
        whiteList[addr] = true;
    }

    function setIdoContract(address addr) external onlyOwner {
        idoContract = addr;
        whiteList[addr] = true;
    }

    function setNftContract(address addr) external onlyOwner {
        nftContract = addr;
        whiteList[addr] = true;
    }

    function setNodeRegistry(address addr) external onlyOwner {
        nodeRegistry = addr;
        emit NodeRegistryUpdated(addr);
    }

    function setStakingContract(address addr) external onlyOwner {
        stakingContract = addr;
        emit StakingContractUpdated(addr);
    }

    function setEntryContract(address addr) external onlyOwner {
        entryContract = addr;
        emit EntryContractUpdated(addr);
    }

    function setWhiteList(address[] calldata addrs, bool b) external onlyOwner {
        for (uint256 i = 0; i < addrs.length; i++) {
            whiteList[addrs[i]] = b;
        }
    }

    function setBlackList(address[] calldata addrs, bool b) external onlyOwner {
        for (uint256 i = 0; i < addrs.length; i++) {
            blackList[addrs[i]] = b;
        }
    }

    function setPairs(address pair, bool b) external onlyOwner {
        pairs[pair] = b;
    }

    function setBuyFee(Fee calldata _fee) external onlyOwner {
        buyFee = _fee;
    }

    function setSellFee(Fee calldata _fee) external onlyOwner {
        sellFee = _fee;
    }

    function setTransferFee(Fee calldata _fee) external onlyOwner {
        transferFee = _fee;
    }

    function setRemoveFee(Fee calldata _fee) external onlyOwner {
        removeFee = _fee;
    }

    function setDailyBurnRate(uint256 rate) external onlyOwner {
        require(rate <= 1000, "max 10%");
        dailyBurnRate = rate;
    }

    function setMinSwapOut(uint256 amount) external onlyOwner {
        minSwapOut = amount;
    }

    // v7.5.3: 把 Token 合约累积的 JOE（手续费税款）一次性裸转到指定地址。
    // 用于"国库归集"——绕过 swap 路径，不影响价格曲线，纯账面转移。
    // 内部 _transfer 不过 hook，零滑点零税。
    event FeeWithdrawn(address indexed to, uint256 amount);
    function withdrawAccumulatedFees(address to, uint256 amount) external onlyOwner {
        require(to != address(0) && to != address(this), "bad recipient");
        require(amount > 0, "zero amount");
        require(balanceOf(address(this)) >= amount, "insufficient");
        _transfer(address(this), to, amount);
        emit FeeWithdrawn(to, amount);
    }

    function setSwapOutLimit(uint256 amount) external onlyOwner {
        swapOutLimit = amount;
    }

    function setDayDuration(uint256 _d) external onlyOwner {
        require(_d >= 60 && _d <= 86400, "60s~86400s");
        dayDuration = _d;
    }

    /// @notice Set the native-asset value that equals one LP dividend weight.
    /// Default is 1 native token, so later LP users按实际 BNB 价值一比一计权。
    function setLPWeightBase(uint256 amount) external onlyOwner {
        require(amount > 0, "zero weight base");
        lpWeightBase = amount;
        emit LPWeightBaseUpdated(amount);
    }

    function setFeeDurations(uint256 _high, uint256 _middle) external onlyOwner {
        highFeeDuration = _high;
        middleFeeDuration = _middle;
    }

    /// @notice Manually seed LP records (for pre-hook users / migrations)
    function setLpAmount(address account, uint256 amount) external onlyOwner {
        lpInfo[account].lpAmount = amount;
        lpPrincipalValue[account] = amount;
        _syncLPWeight(account);
    }

    function syncLPFromPair(address account) external pure {
        account;
        revert("deprecated protocol lp custody");
    }

    /// @notice Add liquidity through the token contract under protocol custody.
    /// LP tokens are minted to this contract and credited to the user as
    /// internal LP权益 units rather than being sent to the user's wallet.
    function addLiquidityViaContract(
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        uint256 deadline
    ) external payable lockTheSwap {
        // v7.0 DoS-hardening: only the owner is allowed to mint LP into
        // the protocol pair before public trade opens. If this path were
        // left open in Phase 1, any address that picked up JOE via
        // `IDO.purchase` could seed the pair with an arbitrary reserve
        // ratio — and `ido.finalizeLaunch` (which has a strict
        // `tokenUsed == tokenAmount` assertion after its router call)
        // would then permanently revert, bricking the launch. Owner
        // bypass stays open for local fixture seeding and genuine
        // market-making operations.
        require(
            startTradeBlock > 0 || msg.sender == owner(),
            "lp add closed until public trade"
        );
        require(amountTokenDesired > 0, "zero token amount");
        require(msg.value > 0, "zero eth amount");
        _ensureMainPair();
        require(mainPair != address(0), "main pair not ready");

        _spendAllowance(msg.sender, address(this), amountTokenDesired);
        _transfer(msg.sender, address(this), amountTokenDesired);
        _approve(address(this), address(uniswapV2Router), amountTokenDesired);
        uint256 lpBefore = IERC20(mainPair).balanceOf(address(this));

        (uint256 amountTokenUsed, uint256 amountETHUsed, uint256 liquidity) = uniswapV2Router.addLiquidityETH{value: msg.value}(
            address(this),
            amountTokenDesired,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        require(liquidity > 0, "zero liquidity minted");
        require(IERC20(mainPair).balanceOf(address(this)) >= lpBefore + liquidity, "lp custody mismatch");

        uint256 tokenRefund = amountTokenDesired - amountTokenUsed;
        if (tokenRefund > 0) {
            _transfer(address(this), msg.sender, tokenRefund);
        }

        uint256 ethRefund = msg.value - amountETHUsed;
        if (ethRefund > 0) {
            (bool ok, ) = msg.sender.call{value: ethRefund}("");
            require(ok, "eth refund failed");
        }

        lpInfo[msg.sender].lpAmount += liquidity;
        lpPrincipalValue[msg.sender] += amountETHUsed;
        lpInfo[msg.sender].lastAddLpTime = block.timestamp;
        _syncLPWeight(msg.sender);
        emit ProtocolLpPositionUpdated(msg.sender, lpInfo[msg.sender].lpAmount, quoteLPValue(msg.sender));
    }

    /// @notice One-click native-only LP entry for downstream users.
    /// If the caller has not yet bound a parent, this function will bind it first.
    function zapNativeForLP(
        address parent,
        uint256 amountOutMin,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        uint256 deadline
    ) external payable lockTheSwap {
        _zapNativeForLP(msg.sender, parent, amountOutMin, amountTokenMin, amountETHMin, deadline);
    }

    function zapNativeForLPFor(
        address user,
        address parent,
        uint256 amountOutMin,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        uint256 deadline
    ) external payable onlyEntry lockTheSwap {
        _zapNativeForLP(user, parent, amountOutMin, amountTokenMin, amountETHMin, deadline);
    }

    function _zapNativeForLP(
        address user,
        address parent,
        uint256 amountOutMin,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        uint256 deadline
    ) internal {
        // v7.0 phase gate: LP-only 一键质押 is a Phase-2+ feature. Phase 0 LP
        // is seeded by super nodes via `bootstrapLaunch` + `addLiquidityViaContract`
        // (owner-side paths that don't touch this function). Phase 1 is for
        // NFT minting only. This require closes the hole where users could
        // zap during the mint window, which the product spec never intended.
        require(startTradeBlock > 0, "lp stake closed until public trade");
        require(msg.value > 1, "zero eth amount");
        _bindParentIfNeeded(user, parent);

        uint256 swapValue = msg.value / 2;
        uint256 liquidityValue = msg.value - swapValue;
        require(swapValue > 0 && liquidityValue > 0, "insufficient zap value");

        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = address(this);

        // UniswapV2Pair.swap rejects `to == token0 || to == token1` with
        // `INVALID_TO`. We swap into tokenDistributor (an unrelated address)
        // and pull the bought JOE back in a second step. _swapTokenForBNB
        // already uses the same pattern for the fee buy-back flow.
        address distributor = address(tokenDistributor);
        uint256 distBefore = balanceOf(distributor);
        uniswapV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: swapValue}(
            amountOutMin,
            path,
            distributor,
            deadline
        );
        uint256 tokenBought = balanceOf(distributor) - distBefore;
        require(tokenBought > 0, "zap swap failed");
        tokenDistributor.claimToken(address(this), address(this), tokenBought);

        _approve(address(this), address(uniswapV2Router), tokenBought);
        uint256 lpBefore = IERC20(mainPair).balanceOf(address(this));
        (uint256 tokenUsed, uint256 nativeUsed, uint256 liquidity) = uniswapV2Router.addLiquidityETH{value: liquidityValue}(
            address(this),
            tokenBought,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        require(liquidity > 0, "zero liquidity minted");
        require(IERC20(mainPair).balanceOf(address(this)) >= lpBefore + liquidity, "lp custody mismatch");

        uint256 tokenRefund = tokenBought - tokenUsed;
        if (tokenRefund > 0) {
            _transfer(address(this), user, tokenRefund);
        }

        uint256 nativeRefund = liquidityValue - nativeUsed;
        if (nativeRefund > 0) {
            (bool ok, ) = user.call{value: nativeRefund}("");
            require(ok, "eth refund failed");
        }

        uint256 principalAdded = msg.value - nativeRefund;
        lpInfo[user].lpAmount += liquidity;
        lpPrincipalValue[user] += principalAdded;
        lpInfo[user].lastAddLpTime = block.timestamp;
        _syncLPWeight(user);
        emit ProtocolLpPositionUpdated(user, lpInfo[user].lpAmount, quoteLPValue(user));

        emit NativeZapForLP(
            user,
            parent,
            msg.value,
            tokenBought,
            tokenUsed,
            nativeUsed,
            liquidity,
            quoteLPValue(user)
        );
    }

    // ============================================================
    // v7.5.2 multi-mode LP staking (PancakeSwap-style 3 routes)
    //
    // 3 入口殊途同归：
    //   A. zapNativeForLP        — 用户出 BNB（合约 swap 一半成 JOE）
    //   B. zapTokenForLP         — 用户出 JOE（合约 swap 一半成 BNB）
    //   C. addBothForLP          — 用户出 JOE + BNB（合约不 swap，直接加池）
    //
    // 共同语义（与 A 完全等价）：
    //   - lpInfo[user].lpAmount += liquidity
    //   - lpPrincipalValue[user] += 2 × nativeUsed   （BNB 等价成本基；balanced LP add 时 = 总 BNB 等价输入）
    //   - lpInfo[user].lastAddLpTime = block.timestamp
    //   - emit ProtocolLpPositionUpdated(user, lpUnits, lpValue)   ← relayer 已索引此事件
    //   - _syncLPWeight(user) → Dividend / Staking 侧业绩更新
    //
    // 后端 / Staking 业绩账本对所有 3 个入口完全一致；用户感受相同。
    // ============================================================

    function zapTokenForLP(
        address parent,
        uint256 joeAmountIn,
        uint256 amountOutMinETH,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        uint256 deadline
    ) external lockTheSwap {
        _zapTokenForLP(msg.sender, parent, joeAmountIn, amountOutMinETH, amountTokenMin, amountETHMin, deadline);
    }

    function zapTokenForLPFor(
        address user,
        address parent,
        uint256 joeAmountIn,
        uint256 amountOutMinETH,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        uint256 deadline
    ) external onlyEntry lockTheSwap {
        _zapTokenForLP(user, parent, joeAmountIn, amountOutMinETH, amountTokenMin, amountETHMin, deadline);
    }

    function _zapTokenForLP(
        address user,
        address parent,
        uint256 joeAmountIn,
        uint256 amountOutMinETH,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        uint256 deadline
    ) internal {
        require(startTradeBlock > 0, "lp stake closed until public trade");
        require(joeAmountIn > 1, "zero token amount");
        _bindParentIfNeeded(user, parent);

        // 1) 把 JOE 拉到 Token 合约自身。直接调用方式时 user==msg.sender，无需 allowance；
        //    走 Entry 时 Entry 已 transferFrom 到 user→Token，并不在此分支。这里统一用
        //    _spendAllowance + _transfer，让 Entry forward 模式也工作。
        //    transfer 触发 _beforeTokenTransfer：from=user, to=this（whiteList[to]=true）
        //    或 inSwap=true（lockTheSwap）→ 全程绕过税。
        if (user != msg.sender) {
            _spendAllowance(user, msg.sender, joeAmountIn);
        }
        _transfer(user, address(this), joeAmountIn);

        // 2) 一半 JOE swap 到 BNB（送到 distributor 中转，避开 INVALID_TO）
        uint256 swapAmount = joeAmountIn / 2;
        uint256 lpTokenAmount = joeAmountIn - swapAmount;
        require(swapAmount > 0 && lpTokenAmount > 0, "insufficient zap value");

        address distributor = address(tokenDistributor);
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WETH;

        _approve(address(this), address(uniswapV2Router), swapAmount);
        uint256 distEthBefore = distributor.balance;
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            swapAmount,
            amountOutMinETH,
            path,
            distributor,
            deadline
        );
        uint256 ethBought = distributor.balance - distEthBefore;
        require(ethBought > 0, "zap swap failed");
        // distributor 已收到 ETH（router 自动 unwrap WETH），claimETH 把 ETH 送回 Token 合约
        tokenDistributor.claimETH(address(this), ethBought, WETH);

        // 3) addLiquidityETH（剩下的 JOE + 刚换到的 ETH）
        _approve(address(this), address(uniswapV2Router), lpTokenAmount);
        uint256 lpBefore = IERC20(mainPair).balanceOf(address(this));
        (uint256 tokenUsed, uint256 nativeUsed, uint256 liquidity) = uniswapV2Router.addLiquidityETH{value: ethBought}(
            address(this),
            lpTokenAmount,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        require(liquidity > 0, "zero liquidity minted");
        require(IERC20(mainPair).balanceOf(address(this)) >= lpBefore + liquidity, "lp custody mismatch");

        // 4) 退还多余 token / ETH 给用户
        uint256 tokenRefund = lpTokenAmount - tokenUsed;
        if (tokenRefund > 0) {
            _transfer(address(this), user, tokenRefund);
        }
        uint256 ethRefund = ethBought - nativeUsed;
        if (ethRefund > 0) {
            (bool ok, ) = user.call{value: ethRefund}("");
            require(ok, "eth refund failed");
        }

        // 5) 业绩账本（与 zapNativeForLP 等价：principalAdded ≈ 2 × nativeUsed）
        uint256 principalAdded = nativeUsed * 2;
        lpInfo[user].lpAmount += liquidity;
        lpPrincipalValue[user] += principalAdded;
        lpInfo[user].lastAddLpTime = block.timestamp;
        _syncLPWeight(user);
        emit ProtocolLpPositionUpdated(user, lpInfo[user].lpAmount, quoteLPValue(user));
    }

    function addBothForLP(
        address parent,
        uint256 joeAmount,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        uint256 deadline
    ) external payable lockTheSwap {
        _addBothForLP(msg.sender, parent, joeAmount, amountTokenMin, amountETHMin, deadline);
    }

    function addBothForLPFor(
        address user,
        address parent,
        uint256 joeAmount,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        uint256 deadline
    ) external payable onlyEntry lockTheSwap {
        _addBothForLP(user, parent, joeAmount, amountTokenMin, amountETHMin, deadline);
    }

    function _addBothForLP(
        address user,
        address parent,
        uint256 joeAmount,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        uint256 deadline
    ) internal {
        require(startTradeBlock > 0, "lp stake closed until public trade");
        require(joeAmount > 0, "zero token amount");
        require(msg.value > 0, "zero eth amount");
        _bindParentIfNeeded(user, parent);

        // Pull JOE
        if (user != msg.sender) {
            _spendAllowance(user, msg.sender, joeAmount);
        }
        _transfer(user, address(this), joeAmount);

        // addLiquidityETH 直接加（不 swap）
        _approve(address(this), address(uniswapV2Router), joeAmount);
        uint256 lpBefore = IERC20(mainPair).balanceOf(address(this));
        (uint256 tokenUsed, uint256 nativeUsed, uint256 liquidity) = uniswapV2Router.addLiquidityETH{value: msg.value}(
            address(this),
            joeAmount,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        require(liquidity > 0, "zero liquidity minted");
        require(IERC20(mainPair).balanceOf(address(this)) >= lpBefore + liquidity, "lp custody mismatch");

        uint256 tokenRefund = joeAmount - tokenUsed;
        if (tokenRefund > 0) _transfer(address(this), user, tokenRefund);
        uint256 ethRefund = msg.value - nativeUsed;
        if (ethRefund > 0) {
            (bool ok, ) = user.call{value: ethRefund}("");
            require(ok, "eth refund failed");
        }

        uint256 principalAdded = nativeUsed * 2;
        lpInfo[user].lpAmount += liquidity;
        lpPrincipalValue[user] += principalAdded;
        lpInfo[user].lastAddLpTime = block.timestamp;
        _syncLPWeight(user);
        emit ProtocolLpPositionUpdated(user, lpInfo[user].lpAmount, quoteLPValue(user));
    }

    /// @notice Remove protocol-custodied liquidity credited to the caller.
    /// The caller never needs to hold LP tokens directly.
    function removeLiquidityViaContract(
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        uint256 deadline
    ) external lockTheSwap {
        _removeLiquidityViaContract(msg.sender, liquidity, amountTokenMin, amountETHMin, deadline);
    }

    function removeLiquidityViaContractFor(
        address user,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        uint256 deadline
    ) external onlyEntry lockTheSwap {
        _removeLiquidityViaContract(user, liquidity, amountTokenMin, amountETHMin, deadline);
    }

    function _removeLiquidityViaContract(
        address user,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        uint256 deadline
    ) internal {
        require(liquidity > 0, "zero liquidity");
        require(lpInfo[user].lpAmount >= liquidity, "insufficient lp units");
        require(lpInfo[user].lastAddLpTime != block.timestamp, "cannot add/remove in same block");

        IERC20(mainPair).approve(address(uniswapV2Router), liquidity);

        uint256 joeBefore = balanceOf(address(this));
        uint256 ethBefore = address(this).balance;
        uint256 lpAmountBefore = lpInfo[user].lpAmount;
        uint256 principalBefore = lpPrincipalValue[user];

        uniswapV2Router.removeLiquidityETHSupportingFeeOnTransferTokens(
            address(this),
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );

        uint256 joeReceived = balanceOf(address(this)) - joeBefore;
        uint256 ethReceived = address(this).balance - ethBefore;

        uint256 feeAmount = _calcFee(removeFee, joeReceived);
        uint256 payout = joeReceived - feeAmount;
        emit TaxCollected(user, feeAmount, "remove_lp");

        if (payout > 0) {
            _transfer(address(this), user, payout);
        }
        if (ethReceived > 0) {
            (bool ok, ) = user.call{value: ethReceived}("");
            require(ok, "eth transfer failed");
        }

        uint256 principalReduction = lpAmountBefore == 0 ? 0 : (principalBefore * liquidity) / lpAmountBefore;
        lpInfo[user].lpAmount = lpAmountBefore - liquidity;
        lpPrincipalValue[user] = principalBefore > principalReduction ? principalBefore - principalReduction : 0;
        _syncLPWeight(user);
        emit ProtocolLpPositionUpdated(user, lpInfo[user].lpAmount, quoteLPValue(user));
    }

    function _bindParentIfNeeded(address user, address parent) internal {
        if (nodeRegistry == address(0)) {
            return;
        }

        IJoeAgentNodeRegistryHook registry = IJoeAgentNodeRegistryHook(nodeRegistry);
        if (!registry.registered(user)) {
            require(parent != address(0), "parent required");
            require(registry.isEligibleLpParent(parent), "parent not lp eligible");
            registry.bindParentForLp(user, parent);
        } else if (parent != address(0)) {
            require(registry.inviterOf(user) == parent, "parent mismatch");
        }
    }

    receive() external payable {}
}
