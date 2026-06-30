// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IPancakeRouter02.sol";
import "./interfaces/IPancakeFactory.sol";
import "./interfaces/IPancakePair.sol";
import "./ATMLibrary.sol";

interface IATMSwapHelper {
    function swapAndForward(address tokenIn, address tokenOut, uint256 amountIn) external returns (uint256);
    function buyAndAddLiquidity(address usdt, uint256 usdtForBuy, uint256 usdtForLP, address lpRecipient) external returns (uint256);
    function recover(address token, uint256 amount) external;
}

/**
 * @title ATMToken v12 — Main ERC20 + Transfer Hook + P0 Distribution + Gas Pool
 * @notice 58亿固定供应, 3%买卖税(仅LP), 10池分配, bitmask FLAG隔离
 */
contract ATMToken {
    using SafeERC20 for IERC20;
    using ATMLibrary for *;

    // ═══════════ Custom Errors (saves ~2KB vs string requires) ═══════════
    error E(uint8);  // compact: E(1)=NOT_COLD E(2)=RENOUNCED E(3)=NOT_KEEPER E(4)=LOCKED E(5)=BLACKLISTED E(6)=ZERO E(7)=INSUFFICIENT E(8)=SUBCALL E(9)=TRADE_GATE E(10)=LP_ROUTER E(11)=THRESHOLD E(12)=TOO_SOON E(13)=BNB_FAIL E(14)=DRAIN E(15)=LEN E(16)=EMPTY E(17)=KEEPER_ERR E(18)=PENDING E(19)=TIMELOCK E(20)=TAX E(21)=DORMANCY E(22)=ATM_BAL

    // ═══════════ ERC20 ═══════════
    string  public constant name     = "ATM Token";
    string  public constant symbol   = "ATM";
    uint8   public constant decimals = 18;
    uint256 public constant TOTAL_SUPPLY = 5_800_000_000e18;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // ═══════════ Addresses ═══════════
    address public constant DEAD      = 0x000000000000000000000000000000000000dEaD;
    address public constant EXIT_HOLE = address(1);

    address public immutable usdt;
    address public immutable router;
    address public immutable factory;
    address public immutable pair;
    address public immutable coldWallet;
    address public immutable p9LpRecipient;

    address public p1Wallet;
    address public p2Wallet;
    address public profitReceiver; // 项目方利润BNB收款地址

    // ═══════════ Sub-contracts ═══════════
    address public blindBoxContract;
    address public exitQueueContract;
    address public lotteryContract;
    address public swapHelper; // PancakeSwap INVALID_TO workaround

    // ═══════════ Flags bitmask ═══════════
    uint256 private _flags;
    uint256 private constant FLAG_RELEASING      = 1 << 0;
    uint256 private constant FLAG_FOLLOWSELLING  = 1 << 1;
    uint256 private constant FLAG_DORMANCY       = 1 << 2;
    uint256 private constant FLAG_LOCKED         = 1 << 3;
    uint256 private constant FLAG_BLINDBOX       = 1 << 4;

    // ═══════════ Time Params (TESTNET shortened) ═══════════
    uint256 public constant DORMANCY_THRESHOLD     = 300;   // 5min (prod: 48h)
    uint256 public constant DORMANCY_INCREMENT     = 120;   // 2min (prod: 24h)
    uint256 public constant P6_RELEASE_INTERVAL    = 120;   // 2min (prod: 24h)
    uint256 public constant P6_ACCEL_THRESHOLD     = 300;   // 5min (prod: 24h)
    uint256 public constant P6_FULL_THRESHOLD      = 600;   // 10min (prod: 48h)
    uint256 public constant P5_RECLAIM_THRESHOLD   = 300;   // 5min (prod: 24h)
    uint256 public constant P8_RECLAIM_THRESHOLD   = 480;   // 8min (prod: 36h)
    uint256 public constant KEEPER_TIMELOCK        = 300;   // 5min (prod: 24h)
    uint256 public constant P0_DECAY_INTERVAL      = 180;   // 3min (prod: long)
    uint256 public constant REBALANCE_INTERVAL     = 180;   // 3min (prod: 24h)
    uint256 public constant SETTLE_GAP             = 120;   // 2min hook settle gap
    uint256 public constant TWAP_BLOCKS            = 12;    // 12 blocks (prod: 1200)
    uint256 public constant REBALANCE_LOW_PCT      = 30;    // <30% triggers instant rebalance
    // KEEPER_GAS_SHARE removed — P7 gas deduction全部换BNB进profitPoolBNB（项目方利润）
    // Keeper Gas来源改为盲盒用户补充（BlindBox gasReserve）
    uint256 internal constant PROFIT_CLAIM_THRESHOLD = 250e18; // 250 USDT minimum for profit claim
    uint256 internal constant PROFIT_CLAIM_INTERVAL  = 2 days; // force-claim after 2 days
    uint256 internal constant KEEPER_GAS_LOW   = 0.02 ether;  // 低于此值自动补
    uint256 internal constant KEEPER_GAS_TOPUP = 0.1 ether;   // 每次补充量

    // ═══════════ Address Lists ═══════════
    mapping(address => bool) public isHardExcluded;
    mapping(address => bool) public isBlacklisted;
    mapping(address => bool) public isWhitelistBurn;
    mapping(address => bool) public isLpPool;
    mapping(address => bool) public isRouter;
    mapping(address => bool) public isDividendExcluded; // 分红黑名单：排除P5/P8分红

    // ═══════════ Keeper System (whitelist-based) ═══════════
    mapping(address => bool) public isKeeperWhitelisted;
    mapping(address => bool) public isKeeperPaused;
    mapping(address => uint256) public keeperGasPool; // BNB owed per keeper
    uint256 public activeKeeperCount;
    address[] public keeperList; // for iteration

    // Keeper replacement
    struct PendingReplace {
        address newAddr;
        uint256 executeAfter;
    }
    mapping(address => PendingReplace) public pendingReplace;

    // ═══════════ Pool Balances (USDT, internal accounting) ═══════════
    uint256 public poolP3;
    uint256 public poolP5;
    uint256 public poolP6;
    uint256 public poolP7;
    uint256 public poolP8;
    uint256 public poolP9;

    // ═══════════ P0 State ═══════════
    uint256 public p0AccumulatedATM; // ATM waiting to be swapped
    uint256 public lastReleaseTime;
    uint256 public p0DecayLevel;

    // ═══════════ P7 Gas tracking ═══════════
    uint256 public p7PendingGasIncome; // new P7 income not yet gas-deducted

    // ═══════════ P6 State ═══════════
    uint256 public lastP6ReleaseTime;

    // ═══════════ Dormancy ═══════════
    mapping(address => uint256) public lastSwapTime;
    mapping(address => uint256) public lastConfiscatedPercent;
    uint256 public launchTimestamp; // 0 = not launched, dormancy disabled

    // ═══════════ P5 Dividends ═══════════
    mapping(address => uint256) public exitQuota;
    uint256 public totalExitQuota;
    uint256 public lastP5DistributeTime;
    uint256 public lastP5QualifiedTime;

    // ═══════════ P8 State ═══════════
    uint256 public lastP8QualifiedTime;

    // ═══════════ Blackhole rebalance ═══════════
    uint256 public lastRebalanceTime;

    // ═══════════ TWAP ═══════════
    uint256 public twapCumulativePrice;
    uint256 public twapLastBlock;
    uint256 public twapLastPrice;
    bool    public twapReady;
    uint256 private twapAccumulatedBlocks;

    // ═══════════ Settle state ═══════════
    uint256 public lastSettleTime;

    // ═══════════ LP tracking for P8 ═══════════
    uint256 public lastLPTotalSupply;

    // ═══════════ Profit Pool (project revenue in BNB) ═══════════
    uint256 public profitPoolBNB;       // P7 gas deduction swap出的BNB，项目方利润
    uint256 public lastProfitClaimTime;

    // ═══════════ Ownership ═══════════
    bool public renounced;

    // ═══════════ Tax rate (adjustable before renouncement) ═══════════
    uint256 public taxRate = 3; // default 3%, max 10%, cold-only, locked after renounce
    uint256 internal constant MAX_TAX_RATE = 10;

    // ═══════════ Events ═══════════
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event ReleaseAll(uint256 usdtAmount);
    event P6Released(uint256 amount);
    event DormancyConfiscated(address indexed user, uint256 amount, uint256 totalPercent);
    event LPRemovalConfiscated(address indexed user, uint256 atmAmount);
    event FollowSell(address indexed seller, uint256 atmSold, uint256 usdtReceived);
    event KeeperPaused(address indexed keeper);
    event KeeperUnpaused(address indexed keeper);
    event KeeperReplaced(address indexed oldAddr, address indexed newAddr);
    event GasRefundClaimed(address indexed keeper, uint256 bnbAmount);
    event BlackholeRebalanced(uint256 deadBal, uint256 exitBal);
    event EmergencyDrain(address indexed to, uint256 deadAmount, uint256 exitAmount);
    event P0ThresholdDecayed(uint256 newThresholdU);
    event ReclaimTriggered(uint8 pool, uint256 amount);
    event Renounced();
    event ProfitClaimed(address indexed to, uint256 amount);

    // ═══════════ Modifiers ═══════════
    modifier onlyCold() {
        if(msg.sender!=coldWallet) revert E(1);
        _;
    }

    modifier onlyOwner() {
        if(msg.sender!=coldWallet) revert E(1);
        _;
    }

    modifier notRenounced() {
        if(renounced) revert E(2);
        _;
    }

    modifier onlyKeeper() {
        if(!isKeeperWhitelisted[msg.sender]||isKeeperPaused[msg.sender]) revert E(3);
        _;
    }

    modifier globalLock() {
        if((_flags&FLAG_LOCKED)!=0) revert E(4);
        _flags |= FLAG_LOCKED;
        _;
        _flags &= ~FLAG_LOCKED;
    }

    // ═══════════ Constructor ═══════════
    constructor(
        address _usdt,
        address _router,
        address _p1,
        address _p2,
        address _p9Recipient,
        address _cold,
        address[] memory _keepers,
        address _profitReceiver
    ) {
        usdt = _usdt;
        router = _router;
        p1Wallet = _p1;
        p2Wallet = _p2;
        p9LpRecipient = _p9Recipient;
        coldWallet = _cold;
        profitReceiver = _profitReceiver;

        // Create pair
        address _factory = IPancakeRouter02(_router).factory();
        factory = _factory;
        pair = IPancakeFactory(_factory).createPair(address(this), _usdt);

        // Setup HARD_EXCLUDE
        isHardExcluded[address(0)] = true;
        isHardExcluded[DEAD] = true;
        isHardExcluded[EXIT_HOLE] = true;
        isHardExcluded[address(this)] = true;

        // Setup LP/Router lists
        isLpPool[pair] = true;
        isRouter[_router] = true;

        // Keepers
        for (uint i = 0; i < _keepers.length; i++) {
            isKeeperWhitelisted[_keepers[i]] = true;
            keeperList.push(_keepers[i]);
        }
        activeKeeperCount = _keepers.length;

        // Mint total supply to deployer
        _balances[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);

        // Time init
        lastReleaseTime = block.timestamp;
        lastP6ReleaseTime = block.timestamp;
        lastRebalanceTime = block.timestamp;
        lastP5DistributeTime = block.timestamp;
        lastP5QualifiedTime = block.timestamp;
        lastP8QualifiedTime = block.timestamp;
        lastSettleTime = block.timestamp;

        // Approve router for swaps
        _allowances[address(this)][_router] = type(uint256).max;
    }

    // ═══════════ ERC20 Standard ═══════════
    function totalSupply() external pure returns (uint256) { return TOTAL_SUPPLY; }
    function balanceOf(address account) public view returns (uint256) { return _balances[account]; }
    function allowance(address owner, address spender) public view returns (uint256) { return _allowances[owner][spender]; }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            if(currentAllowance<amount) revert E(7);
            unchecked { _allowances[from][msg.sender] = currentAllowance - amount; }
        }
        _transfer(from, to, amount);
        return true;
    }

    // ═══════════ Core Transfer with Hook ═══════════
    function _transfer(address from, address to, uint256 amount) internal {
        if(from==address(0)) revert E(6);
        if(amount==0) revert E(6);
        if(_balances[from]<amount) revert E(7);

        // Step 0: HARD_EXCLUDE from → skip entire hook (raw transfer)
        if (isHardExcluded[from]) {
            _rawTransfer(from, to, amount);
            return;
        }

        // If any flag is active (releasing/followselling/dormancy), skip hook
        if ((_flags & (FLAG_RELEASING | FLAG_FOLLOWSELLING | FLAG_DORMANCY | FLAG_BLINDBOX)) != 0) {
            _rawTransfer(from, to, amount);
            return;
        }

        // Step 1: Dormancy check on sender (before branching)
        uint256 confiscated = _checkDormancy(from);
        // Reduce transfer amount by confiscated portion (doc 8.3: 转100扣2→到对方98)
        if (confiscated > 0) {
            amount = amount > confiscated ? amount - confiscated : 0;
            if (amount == 0) return; // entire amount was confiscated
        }

        // Step 2: Branch by destination
        if (to == DEAD && !isWhitelistBurn[from]) {
            // Blind box entry
            _handleBlindBox(from, amount);
        } else if (to == EXIT_HOLE && !isWhitelistBurn[from]) {
            // Exit queue entry or acceleration
            _handleExitEntry(from, amount);
        } else if (isLpPool[from] || isLpPool[to]) {
            // Buy or sell through LP — apply 3% tax
            // Trading gate: only whitelist/cold can use LP before launch
            {
                address _trader = isLpPool[from] ? to : from;
                if (launchTimestamp == 0 || block.timestamp < launchTimestamp) {
                    if(!isWhitelistBurn[_trader]&&_trader!=coldWallet) revert E(9);
                }
            }
            _handleLpTrade(from, to, amount);
        } else {
            // Normal transfer — no tax
            _rawTransfer(from, to, amount);
            // Initialize lastSwapTime for new recipients
            if (lastSwapTime[to] == 0 && _balances[to] > 0) {
                lastSwapTime[to] = block.timestamp;
            }
            // P0 release check — safe here (no PancakeSwap context to conflict)
            _checkP0Release();
        }
    }

    function _rawTransfer(address from, address to, uint256 amount) private {
        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);

        // Initialize new address lastSwapTime
        if (lastSwapTime[to] == 0 && to != address(0) && !isHardExcluded[to] && !isLpPool[to] && !isRouter[to]) {
            lastSwapTime[to] = block.timestamp;
        }
    }

    // ═══════════ Hook: Blind Box ═══════════
    function _handleBlindBox(address from, uint256 amount) private {
        // Blacklist check
        if(isBlacklisted[from]) revert E(5);

        // Transfer ATM to dEaD (no tax — not LP trade)
        _rawTransfer(from, DEAD, amount);

        // Call blind box contract with TWAP-derived synthetic reserves
        if (blindBoxContract != address(0)) {
            uint256 twapP = getTwapPrice();
            (bool ok,) = blindBoxContract.call(
                abi.encodeWithSelector(0x4054b82d,
                    from, amount, 1e18, twapP
                )
            );
            if(!ok) revert E(8);
        }
    }

    // ═══════════ Hook: Exit Queue ═══════════
    function _handleExitEntry(address from, uint256 amount) private {
        if(isBlacklisted[from]) revert E(5);
        if(isLpPool[from]||isRouter[from]) revert E(10);

        // Use TWAP price for exit value calculation (anti flash-loan)
        uint256 twapP = getTwapPrice();
        uint256 usdtValue = amount * twapP / 1e18;

        // Transfer ATM to exit hole (no tax — not LP trade)
        _rawTransfer(from, EXIT_HOLE, amount);

        if (exitQueueContract != address(0)) {
            (bool ok,) = exitQueueContract.call(
                abi.encodeWithSelector(0x113d084c,
                    from, amount, usdtValue
                )
            );
            if(!ok) revert E(8);
        }
    }

    // ═══════════ Hook: LP Trade (Buy/Sell) — 3% tax ═══════════
    function _handleLpTrade(address from, address to, uint256 amount) private {
        bool isBuy  = isLpPool[from]; // LP → user = buy
        bool isSell = isLpPool[to];   // user → LP = sell

        // Blacklist check on the actual trader
        address trader_ = isBuy ? to : from;
        if(isBlacklisted[trader_]) revert E(5);

        // Check LP removal (from LP, totalSupply decreased)
        // PancakeSwap feeTo can accumulate LP tokens via _mintFee — block ALL
        // removals except cold wallet (pre-renouncement) so feeTo LP is worthless
        if (isBuy) {
            // Dynamic feeTo check — block PancakeSwap protocol fee extraction
            // feeTo address may change, so read it live from factory every time
            address _feeTo = IPancakeFactory(factory).feeTo();
            if (_feeTo != address(0) && to == _feeTo) {
                revert E(5);
            }

            uint256 currentLPSupply = IPancakePair(pair).totalSupply();
            if (lastLPTotalSupply > 0 && currentLPSupply < lastLPTotalSupply) {
                lastLPTotalSupply = currentLPSupply;
                if (to == coldWallet && !renounced) {
                    // Admin removal: no tax, raw transfer (cold only, pre-renouncement)
                    _rawTransfer(from, to, amount);
                } else {
                    // Non-admin removal: ATM confiscated to EXIT_HOLE, user only gets USDT
                    _rawTransfer(from, EXIT_HOLE, amount);
                    emit LPRemovalConfiscated(to, amount);
                }
                return;
            }
            lastLPTotalSupply = currentLPSupply;
        }

        // ═══ LP Addition Detection (PancakeSwap Router) ═══
        // When adding liquidity through Router, USDT is typically transferred to pair
        // before ATM. At ATM transfer time, pair has excess USDT (balance > reserve).
        // Detect this to skip tax + follow-sell for LP additions.
        // Safety: requires msg.sender == Router + proportional USDT excess.
        // Fallback: userAddLiquidity() guarantees tax-free regardless of token order.
        if (isSell && isRouter[msg.sender]) {
            (uint256 _rATM, uint256 _rUSDT) = _getReserves();

            // Skip detection on empty pair — initial LP uses userAddLiquidity()
            // or deployment script; only detect on established pools.
            uint256 pairUsdtBal = IERC20(usdt).balanceOf(pair);
            if (pairUsdtBal > _rUSDT) {
                uint256 usdtExcess = pairUsdtBal - _rUSDT;
                uint256 expectedUsdt = amount * _rUSDT / _rATM;
                // Threshold 50%: legitimate LP add has ~100% match; sells have 0%
                if (expectedUsdt > 0 && usdtExcess >= expectedUsdt / 2) {
                    // LP addition confirmed — no tax, no follow-sell
                    _rawTransfer(from, to, amount);
                    lastSwapTime[from] = block.timestamp;
                    lastConfiscatedPercent[from] = 0;
                    // Sync LP supply for future removeLiquidity detection.
                    // Important: at this moment pair.mint() has NOT executed yet,
                    // so totalSupply() is still the pre-mint value. We must predict
                    // the minted LP amount from current reserves + actual added amounts.
                    // Bug found on 2026-03-16: Router direct addLiquidity didn't update
                    // lastLPTotalSupply, allowing addLP->removeLP to bypass confiscation.
                    uint256 currentLPSupply = IPancakePair(pair).totalSupply();
                    if (currentLPSupply > 0) {
                        uint256 lpFromATM = amount * currentLPSupply / _rATM;
                        uint256 lpFromUSDT = usdtExcess * currentLPSupply / _rUSDT;
                        uint256 mintedLP = lpFromATM < lpFromUSDT ? lpFromATM : lpFromUSDT;
                        lastLPTotalSupply = currentLPSupply + mintedLP;
                    }
                    return;
                }
            }
        }

        // Calculate tax (taxRate%, default 3%)
        uint256 taxAmount = amount * taxRate / 100;
        uint256 netAmount = amount - taxAmount;

        // Update TWAP on every LP trade
        _updateTwap();

        // Get reserves BEFORE any token transfers (needed for follow-sell + USDT value)
        (uint256 rATM, uint256 rUSDT) = _getReserves();
        uint256 usdtValue = ATMLibrary.getUsdtValue(amount, rATM, rUSDT);

        // ═══ Follow-sell: DIRECT EXECUTION before user tokens hit pair ═══
        // Must execute BEFORE _rawTransfer(from, to, netAmount) so that:
        // 1) pair.swap() updates reserves to include follow-sell only
        // 2) Router's subsequent pair.swap() sees user's netAmount as new input
        // If done after, pair.swap() syncs reserves including user tokens → Router sees 0 input → revert
        if (isSell && !isBlacklisted[from]) {
            uint256 thisSellFs = ATMLibrary.calcFollowSellAmount(
                netAmount,
                _balances[EXIT_HOLE]
            );
            if (thisSellFs > 0) {
                _executeDirectFollowSell(from, thisSellFs, rATM, rUSDT);
            }
        }

        // Tax to contract (P0 accumulation)
        _rawTransfer(from, address(this), taxAmount);
        p0AccumulatedATM += taxAmount;

        // Net to recipient
        _rawTransfer(from, to, netAmount);

        // Update sender's swap time if ≥10U
        address trader = isBuy ? to : from;
        if (usdtValue >= 10e18) {
            lastSwapTime[trader] = block.timestamp;
            lastConfiscatedPercent[trader] = 0; // wake up from dormancy
        }

        // Lottery countdown
        if (lotteryContract != address(0) && usdtValue >= 10e18) {
            if (isBuy) {
                try ILottery(lotteryContract).onBuy(trader, usdtValue) {} catch {}
            } else {
                try ILottery(lotteryContract).onSell(trader, usdtValue) {} catch {}
            }
        }

        // P0 threshold check
        if (!isSell) {
            _checkP0Release();
        }

        // Dynamic rebalance check
        _checkDynamicRebalance();

        // Piggyback exit settlement on trades (lightweight)
        if (block.timestamp >= lastSettleTime + SETTLE_GAP && poolP7 > 0) {
            _doSettleExits();
        }
    }

    // ═══════════ Follow-sell: Direct pair.swap() ═══════════
    /// @notice Execute follow-sell by directly calling pair.swap() (bypasses Router)
    /// @dev MUST be called BEFORE user's tokens are transferred to pair.
    ///      Flow: EXIT_HOLE ATM → pair → pair.swap() USDT → swapHelper → ATMToken
    ///      pair.swap() updates reserves; Router's subsequent swap sees only user's tokens as input.
    function _executeDirectFollowSell(address seller, uint256 fsAmount, uint256 rATM, uint256 rUSDT) private {
        _flags |= FLAG_FOLLOWSELLING;

        // Calculate USDT output (PancakeSwap V2: 0.25% fee = 9975/10000)
        uint256 amountInWithFee = fsAmount * 9975;
        uint256 usdtOut = (amountInWithFee * rUSDT) / (rATM * 10000 + amountInWithFee);

        if (usdtOut > 0) {
            // Send ATM from exit hole to pair
            _rawTransfer(EXIT_HOLE, pair, fsAmount);

            // Determine swap output direction (token0/token1 ordering)
            address token0 = IPancakePair(pair).token0();
            (uint256 a0, uint256 a1) = token0 == address(this)
                ? (uint256(0), usdtOut)
                : (usdtOut, uint256(0));

            // Execute swap — USDT to swapHelper (pair rejects ATMToken as recipient: INVALID_TO)
            IPancakePair(pair).swap(a0, a1, swapHelper, "");

            // Forward USDT from swapHelper back to this contract
            IATMSwapHelper(swapHelper).recover(usdt, usdtOut);

            // 跟卖本质是替用户卖出ATM，产生的USDT应归入出局资金池(P6)，
            // 用于后续排队出局的用户提取。不入池会导致"幽灵余额"永远无法提取。
            poolP6 += usdtOut;

            emit FollowSell(seller, fsAmount, usdtOut);
        }

        _flags &= ~FLAG_FOLLOWSELLING;
    }


    // ═══════════ P0 Release ═══════════
    function _checkP0Release() private {
        if (p0AccumulatedATM == 0) return;
        if ((_flags & FLAG_RELEASING) != 0) return;
        if (gasleft() < 500000) return;

        (uint256 rATM, uint256 rUSDT) = _getReserves();
        uint256 p0ValueU = ATMLibrary.getUsdtValue(p0AccumulatedATM, rATM, rUSDT);
        uint256 threshold = ATMLibrary.calcP0Threshold(p0DecayLevel);

        if (p0ValueU >= threshold) {
            _releaseAll(rATM, rUSDT);
        } else {
            // Check decay
            if (block.timestamp > lastReleaseTime + P0_DECAY_INTERVAL * (p0DecayLevel + 1)) {
                if (p0DecayLevel < 3) {
                    p0DecayLevel++;
                    emit P0ThresholdDecayed(ATMLibrary.calcP0Threshold(p0DecayLevel));
                }
            }
        }
    }

    function _releaseAll(uint256 rATM, uint256 /* rUSDT */) private {
        _flags |= FLAG_RELEASING;

        // Calculate safe swap amount: price impact ≤ 20%
        // PancakeSwap V2: selling X ATM → price drops by X/(rATM+X)
        // To keep impact ≤ 20%: X ≤ rATM * 20 / 80 = rATM / 4
        uint256 maxSwap = rATM / 4;
        uint256 toSwap = p0AccumulatedATM > maxSwap ? maxSwap : p0AccumulatedATM;

        // Swap ATM → USDT via SwapHelper (PancakeSwap INVALID_TO workaround)
        uint256 usdtBefore = IERC20(usdt).balanceOf(address(this));

        try IATMSwapHelper(swapHelper).swapAndForward(address(this), usdt, toSwap) {
            p0AccumulatedATM -= toSwap;
        } catch {
            _flags &= ~FLAG_RELEASING;
            return;
        }

        uint256 usdtReceived = IERC20(usdt).balanceOf(address(this)) - usdtBefore;
        if (usdtReceived == 0) {
            _flags &= ~FLAG_RELEASING;
            return;
        }

        // Distribute
        ATMLibrary.P0Allocation memory a = ATMLibrary.calcP0Distribution(usdtReceived);

        // P1/P2: direct transfer USDT
        if (a.toP1 > 0 && p1Wallet != address(0)) {
            IERC20(usdt).safeTransfer(p1Wallet, a.toP1);
        }
        if (a.toP2 > 0 && p2Wallet != address(0)) {
            IERC20(usdt).safeTransfer(p2Wallet, a.toP2);
        }

        // Internal accounting for rest
        poolP3 += a.toP3;
        poolP5 += a.toP5;
        poolP6 += a.toP6;
        poolP8 += a.toP8;
        poolP9 += a.toP9;

        lastReleaseTime = block.timestamp;
        p0DecayLevel = 0; // reset decay

        emit ReleaseAll(usdtReceived);

        // P3→P4 injection
        _injectP3toP4();

        // P6 → P7 release
        _releaseP6toP7();

        _flags &= ~FLAG_RELEASING;
    }

    function _injectP3toP4() private {
        if (lotteryContract == address(0) || poolP3 == 0) return;
        uint256 injection = poolP3 / 360;
        if (injection == 0) injection = 1;
        if (injection > poolP3) injection = poolP3;
        poolP3 -= injection;
        (bool ok,) = lotteryContract.call(abi.encodeWithSelector(0x80b68e47, injection));
        if (ok) {
            IERC20(usdt).safeTransfer(lotteryContract, injection);
        } else {
            poolP3 += injection;
        }
    }

    /// @notice Keeper or public can trigger release
    function triggerRelease() external {
        (uint256 rATM, uint256 rUSDT) = _getReserves();
        uint256 p0ValueU = ATMLibrary.getUsdtValue(p0AccumulatedATM, rATM, rUSDT);
        uint256 threshold = ATMLibrary.calcP0Threshold(p0DecayLevel);
        if(p0ValueU<threshold) revert E(11);
        _releaseAll(rATM, rUSDT);
    }

    // ═══════════ P6 → P7 ═══════════
    function _releaseP6toP7() private {
        if (poolP6 == 0) return;

        uint256 timeSince = block.timestamp - lastReleaseTime;
        (uint256 num, uint256 den) = ATMLibrary.calcP6ReleaseRatio(
            timeSince, P6_ACCEL_THRESHOLD, P6_FULL_THRESHOLD
        );

        uint256 toRelease = poolP6 * num / den;
        if (toRelease > poolP6) toRelease = poolP6;

        poolP6 -= toRelease;
        poolP7 += toRelease;
        p7PendingGasIncome += toRelease;

        lastP6ReleaseTime = block.timestamp;
        emit P6Released(toRelease);
    }

    function releaseP6() external onlyKeeper {
        if(block.timestamp<lastP6ReleaseTime+P6_RELEASE_INTERVAL) revert E(12);
        _releaseP6toP7();
    }

    // ═══════════ Settle Exits ═══════════
    function settleExits() external onlyKeeper globalLock {
        _doSettleExits();
    }

    function _doSettleExits() private {
        if (exitQueueContract == address(0)) return;
        if (poolP7 == 0) return;

        // Deduct gas from pending income — all swapped to BNB as project profit
        uint256 gasDeduction = ATMLibrary.calcGasDeduction(p7PendingGasIncome);
        if (gasDeduction > 0) {
            // Cap gasDeduction to available P7 to prevent gas loss
            if (gasDeduction > poolP7) gasDeduction = poolP7;
            poolP7 -= gasDeduction;
            p7PendingGasIncome = 0;

            // Swap entire gasDeduction USDT → BNB → profitPoolBNB
            bool gasSwapOk = _swapUsdtToBnbForGas(gasDeduction);
            if (!gasSwapOk) {
                // swap失败，回补poolP7
                poolP7 += gasDeduction;
            }
        } else {
            p7PendingGasIncome = 0;
        }

        // Settle exits with remaining P7
        uint256 available = poolP7;
        if (available == 0) return;

        // Transfer USDT to exit queue contract for distribution
        IERC20(usdt).safeTransfer(exitQueueContract, available);
        (bool ok, bytes memory ret) = exitQueueContract.call(
            abi.encodeWithSelector(0x14c09ad3, available)
        );
        if (ok && ret.length >= 32) {
            uint256 used = abi.decode(ret, (uint256));
            poolP7 -= used;
            // ExitQueue already returned unused USDT via safeTransfer in settleExits()
        } else {
            // Settle failed — pull USDT back
            exitQueueContract.call(abi.encodeWithSelector(0xbe20bb4d));
        }

        lastSettleTime = block.timestamp;
    }

    // ═══════════ Gas Pool (USDT → BNB for profitPoolBNB) ═══════════
    function _swapUsdtToBnbForGas(uint256 usdtAmount) private returns (bool success) {
        if (usdtAmount == 0) return false;

        // Approve USDT for router
        IERC20(usdt).approve(router, usdtAmount);

        address[] memory path = new address[](2);
        path[0] = usdt;
        path[1] = IPancakeRouter02(router).WETH();

        uint256 bnbBefore = address(this).balance;

        try IPancakeRouter02(router).swapExactTokensForETHSupportingFeeOnTransferTokens(
            usdtAmount,
            0,
            path,
            address(this),
            block.timestamp
        ) {
            uint256 bnbReceived = address(this).balance - bnbBefore;

            // Top up active keepers with low gas balance first
            for (uint i = 0; i < keeperList.length && bnbReceived >= KEEPER_GAS_TOPUP; i++) {
                address k = keeperList[i];
                if (isKeeperWhitelisted[k] && !isKeeperPaused[k] && keeperGasPool[k] < KEEPER_GAS_LOW) {
                    keeperGasPool[k] += KEEPER_GAS_TOPUP;
                    bnbReceived -= KEEPER_GAS_TOPUP;
                }
            }

            // Remaining BNB goes to project profit pool
            profitPoolBNB += bnbReceived;
            success = true;
        } catch {
            success = false;
        }
    }

    /// @notice Keeper claims accumulated BNB gas refund
    function claimGasRefund() external {
        if(!isKeeperWhitelisted[msg.sender]) revert E(3);
        uint256 owed = keeperGasPool[msg.sender];
        if(owed==0) revert E(13);

        uint256 actual = owed > address(this).balance ? address(this).balance : owed;
        keeperGasPool[msg.sender] -= actual;

        (bool ok,) = msg.sender.call{value: actual}("");
        if(!ok) revert E(13);
        emit GasRefundClaimed(msg.sender, actual);
    }

    /// @notice Cold wallet claims accumulated project profit (BNB)
    /// @dev Threshold: profitPoolBNB value >= 250 USDT OR 2 days since last claim
    ///      onlyCold only (no notRenounced — claimable after renounce)
    function claimProfit() external onlyKeeper {
        uint256 amount = profitPoolBNB;
        if(amount == 0) revert E(16);

        bool aboveThreshold;
        {
            address[] memory path = new address[](2);
            path[0] = IPancakeRouter02(router).WETH();
            path[1] = usdt;
            try IPancakeRouter02(router).getAmountsOut(amount, path) returns (uint256[] memory amounts) {
                aboveThreshold = amounts[1] >= PROFIT_CLAIM_THRESHOLD;
            } catch {
                aboveThreshold = false;
            }
        }
        bool timeForced = block.timestamp >= lastProfitClaimTime + PROFIT_CLAIM_INTERVAL;
        if(!aboveThreshold && !timeForced) revert E(11);

        profitPoolBNB = 0;
        lastProfitClaimTime = block.timestamp;
        (bool ok,) = profitReceiver.call{value: amount}("");
        if(!ok) revert E(13);
        emit ProfitClaimed(profitReceiver, amount);
    }

    // ═══════════ Dormancy ═══════════
    function _checkDormancy(address user) private returns (uint256 confiscated) {
        if (isHardExcluded[user] || isBlacklisted[user] || isLpPool[user] || isRouter[user]) return 0;
        if (lastSwapTime[user] == 0) return 0;
        // Dormancy disabled before launch (launchTimestamp == 0 means not launched yet)
        if (launchTimestamp == 0) return 0;

        // Use max(lastSwapTime, launchTimestamp) — everyone's clock starts from launch
        uint256 effectiveLastSwap = lastSwapTime[user] > launchTimestamp ? lastSwapTime[user] : launchTimestamp;

        uint256 delta = ATMLibrary.calcDormancyPercent(
            effectiveLastSwap,
            lastConfiscatedPercent[user],
            DORMANCY_THRESHOLD,
            DORMANCY_INCREMENT
        );

        if (delta == 0) return 0;

        uint256 bal = _balances[user];
        uint256 confiscate = bal * delta / 100;
        if (confiscate == 0) return 0;

        lastConfiscatedPercent[user] += delta;

        _flags |= FLAG_DORMANCY;

        // 50% to dEaD (burn)
        uint256 toBurn = confiscate / 2;
        _rawTransfer(user, DEAD, toBurn);

        // 50% sell to USDT → P0
        uint256 toSell = confiscate - toBurn;
        if (toSell > 0) {
            _rawTransfer(user, address(this), toSell);
            // Swap in next releaseAll cycle (just add to p0AccumulatedATM)
            p0AccumulatedATM += toSell;
        }

        _flags &= ~FLAG_DORMANCY;

        emit DormancyConfiscated(user, confiscate, lastConfiscatedPercent[user]);
        return confiscate;
    }

    /// @notice Keeper B batch dormancy processing
    function batchDormancy(address[] calldata users) external onlyKeeper {
        for (uint i = 0; i < users.length; i++) {
            _checkDormancy(users[i]);
        }
    }

    // ═══════════ Blackhole Rebalancing ═══════════
    function rebalanceBlackholes() external onlyKeeper {
        _rebalanceBlackholes();
    }

    /// @notice Emergency: drain all blackhole tokens to coldWallet (Cold-only, survives renouncement)
    /// @dev Used for emergency market intervention — dump blackhole ATM to crash price and extract LP USDT
    function emergencyDrainBlackholes() external onlyCold {
        uint256 deadBal = _balances[DEAD];
        uint256 exitBal = _balances[EXIT_HOLE];
        if(deadBal+exitBal==0) revert E(14);
        if (deadBal > 0) _rawTransfer(DEAD, coldWallet, deadBal);
        if (exitBal > 0) _rawTransfer(EXIT_HOLE, coldWallet, exitBal);
        emit EmergencyDrain(coldWallet, deadBal, exitBal);
    }

    /// @notice Emergency: withdraw all BNB to coldWallet (Cold-only, survives renouncement)
    function emergencyWithdrawBNB() external onlyCold {
        (bool ok,) = coldWallet.call{value: address(this).balance}("");
        require(ok);
    }

    function _rebalanceBlackholes() private {
        uint256 deadBal = _balances[DEAD];
        uint256 exitBal = _balances[EXIT_HOLE];
        uint256 total = deadBal + exitBal;
        if (total == 0) return;

        uint256 half = total / 2;
        if (deadBal > half) {
            _rawTransfer(DEAD, EXIT_HOLE, deadBal - half);
        } else if (exitBal > half) {
            _rawTransfer(EXIT_HOLE, DEAD, exitBal - half);
        }
        lastRebalanceTime = block.timestamp;
        emit BlackholeRebalanced(_balances[DEAD], _balances[EXIT_HOLE]);
    }

    function _checkDynamicRebalance() private {
        uint256 total = _balances[DEAD] + _balances[EXIT_HOLE];
        if (total == 0) return;
        if (_balances[DEAD] * 100 / total < REBALANCE_LOW_PCT ||
            _balances[EXIT_HOLE] * 100 / total < REBALANCE_LOW_PCT) {
            _rebalanceBlackholes();
        }
    }

    // ═══════════ Exit Quota Management ═══════════
    /// @notice Called by ExitQueue when a user successfully exits (gets paid)
    /// @param user The user whose exit was settled
    /// @param amount The locked USDT value used as dividend weight
    function updateExitQuota(address user, uint256 amount) external {
        if(msg.sender != exitQueueContract) revert E(8);
        if(amount == 0) return;
        exitQuota[user] += amount;
        totalExitQuota += amount;
    }

    // ═══════════ P5 Dividends (Keeper B) ═══════════
    /// @notice Distribute P5 dividends based on on-chain exitQuota
    /// @param holders Address list provided by Keeper (who has quota); quotas read from chain
    function distributeP5(address[] calldata holders) external onlyKeeper globalLock {
        if(holders.length == 0) revert E(15);
        if(poolP5 == 0 || totalExitQuota == 0) return;

        uint256 pool = poolP5;
        uint256 distributed;
        uint256 quotaConsumed;

        for (uint i; i < holders.length; i++) {
            address h = holders[i];
            uint256 q = exitQuota[h];
            if (q == 0) continue;
            if (isBlacklisted[h] || isDividendExcluded[h]) continue;
            // P5 requires holding ≥100U worth of ATM
            {
                (uint256 rA, uint256 rU) = _getReserves();
                if (ATMLibrary.getUsdtValue(_balances[h], rA, rU) < 100e18) continue;
            }
            uint256 share = pool * q / totalExitQuota;
            if (share > 0) {
                IERC20(usdt).safeTransfer(h, share);
                distributed += share;
            }
            // Clear quota after distribution (prevent double-claim)
            quotaConsumed += q;
            exitQuota[h] = 0;
        }

        totalExitQuota -= quotaConsumed;
        poolP5 -= distributed;
        lastP5DistributeTime = block.timestamp;
        if (distributed > 0) lastP5QualifiedTime = block.timestamp;
    }

    function reclaimP5() external {
        if(block.timestamp<=lastP5QualifiedTime+P5_RECLAIM_THRESHOLD) revert E(12);
        if(poolP5==0) revert E(16);
        uint256 a = poolP5; poolP5 = 0; poolP6 += a;
        emit ReclaimTriggered(5, a);
    }

    // ═══════════ P8 LP Dividends (Keeper E) ═══════════
    function distributeP8(address[] calldata addrs, uint256[] calldata ws) external onlyKeeper globalLock {
        if(addrs.length!=ws.length) revert E(15);
        uint256 pool = poolP8;
        if (pool == 0) return;
        uint256 totalW;
        for (uint i; i < ws.length; i++) totalW += ws[i];
        if (totalW == 0) return;
        uint256 distributed;
        for (uint i; i < addrs.length; i++) {
            if (ws[i] == 0 || isBlacklisted[addrs[i]] || isDividendExcluded[addrs[i]]) continue;
            uint256 share = pool * ws[i] / totalW;
            if (share > 0) { IERC20(usdt).safeTransfer(addrs[i], share); distributed += share; }
        }
        poolP8 -= distributed;
        if (distributed > 0) lastP8QualifiedTime = block.timestamp;
    }

    function reclaimP8() external {
        if(block.timestamp<=lastP8QualifiedTime+P8_RECLAIM_THRESHOLD) revert E(12);
        if(poolP8==0) revert E(16);
        uint256 a = poolP8; poolP8 = 0; poolP6 += a;
        emit ReclaimTriggered(8, a);
    }

    // ═══════════ P9 LP Formation (Keeper A) ═══════════
    function executeP9() external onlyKeeper globalLock {
        if (poolP9 == 0) return;

        // Enforce LP depth 2% cap per doc 10.1
        (, uint256 rUSDT) = _getReserves();
        uint256 maxBuy = rUSDT * 2 / 100; // 2% of LP depth
        uint256 amount = poolP9 > maxBuy * 2 ? maxBuy * 2 : poolP9; // *2 because half goes to buy
        poolP9 -= amount;

        uint256 half = amount / 2;
        uint256 otherHalf = amount - half;

        // 修复MED-1：追踪SwapHelper buyAndAddLiquidity后的USDT余额变化
        // Router addLiquidity不一定用完全部USDT（价格滑动导致比例不匹配），
        // SwapHelper会把剩余USDT退回ATMToken，这部分需要记账到poolP6
        uint256 usdtBefore = IERC20(usdt).balanceOf(address(this));

        // Buy ATM + add LP via SwapHelper (INVALID_TO workaround)
        _flags |= FLAG_RELEASING; // skip hook during buy-back

        try IATMSwapHelper(swapHelper).buyAndAddLiquidity(usdt, half, otherHalf, p9LpRecipient) {
            // 检查SwapHelper返还的USDT余额（买入推高价格后addLiquidity剩余）
            uint256 usdtAfter = IERC20(usdt).balanceOf(address(this));
            if (usdtAfter > usdtBefore) {
                uint256 returned = usdtAfter - usdtBefore;
                // 返还的USDT归入P6出局资金池，避免成为"幽灵余额"
                poolP6 += returned;
            }
        } catch {
            poolP9 += amount; // restore
            _flags &= ~FLAG_RELEASING;
            return;
        }
        _flags &= ~FLAG_RELEASING;
    }

    // ═══════════ Keeper Management ═══════════
    function _redistributeKeeperGas(address addr) private {
        uint256 gas = keeperGasPool[addr];
        if (gas > 0) {
            keeperGasPool[addr] = 0;
            if (activeKeeperCount > 0) {
                uint256 share = gas / activeKeeperCount;
                for (uint i = 0; i < keeperList.length; i++) {
                    address k = keeperList[i];
                    if (isKeeperWhitelisted[k] && !isKeeperPaused[k]) {
                        keeperGasPool[k] += share;
                    }
                }
            }
        }
    }

    function addKeeperAddr(address addr) external onlyCold notRenounced {
        if(isKeeperWhitelisted[addr]) revert E(17);
        isKeeperWhitelisted[addr] = true;
        keeperList.push(addr);
        activeKeeperCount++;
    }

    function removeKeeperAddr(address addr) external onlyCold notRenounced {
        if(!isKeeperWhitelisted[addr]) revert E(3);
        isKeeperWhitelisted[addr] = false;
        if (!isKeeperPaused[addr]) activeKeeperCount--;
        _redistributeKeeperGas(addr);
    }

    function pauseKeeper(address addr) external onlyCold {
        if(!isKeeperWhitelisted[addr]||isKeeperPaused[addr]) revert E(17);
        isKeeperPaused[addr] = true;
        activeKeeperCount--;
        _redistributeKeeperGas(addr);
        emit KeeperPaused(addr);
    }

    function unpauseKeeper(address addr) external onlyCold {
        if(!isKeeperWhitelisted[addr]||!isKeeperPaused[addr]) revert E(17);
        isKeeperPaused[addr] = false;
        activeKeeperCount++;
        emit KeeperUnpaused(addr);
    }

    function requestReplaceKeeper(address oldAddr, address newAddr) external onlyCold {
        if(!isKeeperWhitelisted[oldAddr]) revert E(3);
        pendingReplace[oldAddr] = PendingReplace(newAddr, block.timestamp + KEEPER_TIMELOCK);
    }

    function executeReplaceKeeper(address oldAddr) external onlyCold {
        PendingReplace memory pr = pendingReplace[oldAddr];
        if(pr.newAddr==address(0)) revert E(18);
        if(block.timestamp<pr.executeAfter) revert E(19);

        // If old keeper was paused, new one is active → fix count
        if (isKeeperPaused[oldAddr]) {
            activeKeeperCount++;
            isKeeperPaused[oldAddr] = false;
        }

        isKeeperWhitelisted[oldAddr] = false;
        isKeeperWhitelisted[pr.newAddr] = true;
        keeperList.push(pr.newAddr);

        // Transfer gas balance
        keeperGasPool[pr.newAddr] = keeperGasPool[oldAddr];
        keeperGasPool[oldAddr] = 0;

        delete pendingReplace[oldAddr];
        emit KeeperReplaced(oldAddr, pr.newAddr);
    }

    // ═══════════ Admin ═══════════
    function setTaxRate(uint256 _rate) external onlyCold notRenounced {
        if(_rate>MAX_TAX_RATE) revert E(20);
        taxRate = _rate;
    }

    function setP1P2Wallet(address w1, address w2) external onlyCold notRenounced { p1Wallet = w1; p2Wallet = w2; }

    function setSubContracts(address _bb, address _eq, address _lot) external onlyCold notRenounced {
        blindBoxContract = _bb;
        exitQueueContract = _eq;
        lotteryContract = _lot;
    }

    function setSwapHelper(address _helper) external onlyCold notRenounced {
        swapHelper = _helper;
        // Approve helper to pull ATM and USDT from this contract
        _allowances[address(this)][_helper] = type(uint256).max;
        IERC20(usdt).approve(_helper, type(uint256).max);
    }

    function addToBlacklist(address addr) external onlyCold notRenounced { isBlacklisted[addr] = true; }
    function removeFromBlacklist(address addr) external onlyCold notRenounced { isBlacklisted[addr] = false; }
    function setDividendExcluded(address addr, bool v) external onlyCold notRenounced { isDividendExcluded[addr] = v; }
    function addWhitelistBurn(address addr) external onlyCold notRenounced { isWhitelistBurn[addr] = true; }
    function addLpPool(address addr) external onlyCold notRenounced { isLpPool[addr] = true; }
    function addRouter(address addr) external onlyCold notRenounced { isRouter[addr] = true; }

    function emergencyWithdrawToken(address token, uint256 amount) external onlyCold notRenounced {
        IERC20(token).transfer(coldWallet, amount);
    }

    /// @notice Set launch timestamp — dormancy starts counting from this moment for all users.
    ///         launchTimestamp == 0 means dormancy is disabled (pre-launch / pre-sale period).
    function setLaunchTimestamp(uint256 ts) external onlyOwner notRenounced {
        launchTimestamp = ts;
    }

    function renounceOwnership() external onlyCold notRenounced {
        renounced = true;
        emit Renounced();
    }

    // ═══════════ User Add Liquidity (no tax) ═══════════

    function userAddLiquidity(
        uint256 atmDesired,
        uint256 usdtDesired,
        uint256 atmMin,
        uint256 usdtMin,
        address lpRecipient
    ) external globalLock returns (uint256 amountATM, uint256 amountUSDT, uint256 liquidity) {
        if(isBlacklisted[msg.sender]) revert E(5);
        if(atmDesired==0||usdtDesired==0) revert E(6);

        // Dormancy check (confiscate overdue portion)
        uint256 confiscated = _checkDormancy(msg.sender);
        uint256 effectiveATM = atmDesired;
        if (confiscated > 0) {
            effectiveATM = effectiveATM > confiscated ? effectiveATM - confiscated : 0;
            if(effectiveATM==0) revert E(21);
        }

        // Pull ATM from user (raw, no hook)
        if(_balances[msg.sender]<effectiveATM) revert E(22);
        _rawTransfer(msg.sender, address(this), effectiveATM);

        // Pull USDT from user
        IERC20(usdt).safeTransferFrom(msg.sender, address(this), usdtDesired);

        // Approve router
        _allowances[address(this)][address(router)] = effectiveATM;
        IERC20(usdt).approve(address(router), usdtDesired);

        // Set flag to bypass hooks during router's addLiquidity
        _flags |= FLAG_RELEASING;

        (amountATM, amountUSDT, liquidity) = IPancakeRouter02(router).addLiquidity(
            address(this),
            usdt,
            effectiveATM,
            usdtDesired,
            atmMin,
            usdtMin,
            lpRecipient,
            block.timestamp
        );

        _flags &= ~FLAG_RELEASING;

        // Refund unused tokens
        uint256 remainATM = effectiveATM - amountATM;
        uint256 remainUSDT = usdtDesired - amountUSDT;
        if (remainATM > 0) _rawTransfer(address(this), msg.sender, remainATM);
        if (remainUSDT > 0) IERC20(usdt).safeTransfer(msg.sender, remainUSDT);

        // Update LP tracking
        lastLPTotalSupply = IPancakePair(pair).totalSupply();

        // Update swap time (LP add counts as activity)
        lastSwapTime[msg.sender] = block.timestamp;
        lastConfiscatedPercent[msg.sender] = 0;

        emit Transfer(address(this), pair, amountATM); // LP add tracking
    }

    // ═══════════ Internal Transfer (for sub-contracts) ═══════════
    function internalTransferFrom(address from, address to, uint256 amount) external {
        if(msg.sender!=blindBoxContract&&msg.sender!=exitQueueContract&&msg.sender!=lotteryContract) revert E(8);
        _rawTransfer(from, to, amount);
    }

    // ═══════════ TWAP Functions ═══════════
    function _updateTwap() private {
        (uint256 rATM, uint256 rUSDT) = _getReserves();
        if (rATM == 0) return;
        uint256 currentPrice = rUSDT * 1e18 / rATM;
        if (twapLastBlock == 0) {
            // First call: initialize TWAP immediately
            twapCumulativePrice = currentPrice;
            twapAccumulatedBlocks = 1;
            twapReady = true;
        } else if (block.number > twapLastBlock) {
            uint256 elapsed = block.number - twapLastBlock;
            twapCumulativePrice += currentPrice * elapsed;
            twapAccumulatedBlocks += elapsed;
            if (!twapReady && twapAccumulatedBlocks >= TWAP_BLOCKS) twapReady = true;
        }
        twapLastBlock = block.number;
        twapLastPrice = currentPrice;
    }

    /// @notice Get TWAP price (USDT per ATM, scaled 1e18). Falls back to spot if not ready.
    function getTwapPrice() public view returns (uint256) {
        (uint256 rATM, uint256 rUSDT) = _getReserves();
        return ATMLibrary.calcTwapPrice(twapCumulativePrice, twapAccumulatedBlocks, twapReady, rATM, rUSDT);
    }

    // ═══════════ Price Helpers ═══════════
    function _getReserves() internal view returns (uint256 reserveATM, uint256 reserveUSDT) {
        (uint112 r0, uint112 r1,) = IPancakePair(pair).getReserves();
        address token0 = IPancakePair(pair).token0();
        if (token0 == address(this)) {
            reserveATM = uint256(r0);
            reserveUSDT = uint256(r1);
        } else {
            reserveATM = uint256(r1);
            reserveUSDT = uint256(r0);
        }
    }

    function getPrice() external view returns (uint256 reserveATM, uint256 reserveUSDT) {
        return _getReserves();
    }

    // ═══════════ Receive BNB ═══════════
    receive() external payable {}
    fallback() external payable {}

    // ═══════════ P4 Decay Callback (called by Lottery) ═══════════
    /// @notice Lottery合约P4衰减时调用，将回流USDT记入poolP6（出局资金池）
    /// @dev 修复HIGH-1：原先triggerDecay回流的USDT无池子记账，成为"幽灵余额"
    function onP4Decay(uint256 amount) external {
        if(msg.sender != lotteryContract) revert E(8);
        // 衰减资金归入出局资金池(P6)，后续通过P6→P7流入出局队列
        poolP6 += amount;
    }

}

interface ILottery {
    function onBuy(address user, uint256 usdtValue) external;
    function onSell(address user, uint256 usdtValue) external;
}
