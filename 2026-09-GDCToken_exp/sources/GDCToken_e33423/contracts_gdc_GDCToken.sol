// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
/// @title GDCToken
/// @notice GDC protocol token. Based on GWToken with:
///         1) fixed deposit compensation power,
///         2) node level differential rewards,
///         3) staged deflation burn/award ratios.

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../shared/interfaces/IUniswapV2.sol";
import "../shared/libraries/EnumerableSet.sol";
import "../shared/libraries/UniswapOperations.sol";
import "../shared/libraries/SwapOperations.sol";
import "../shared/Distributor.sol";

contract GDCToken is ERC20, Ownable {
    error MintNotAllowed();
    error AddPoolNotAllowed();
    error NoLiquidityAdded();
    error BuyingProhibited();
    error InsufficientTokenA();
    error InsufficientTokenB();
    error InvalidDistributor();
    error ReferrerCannotBeZero();
    error AlreadyHasReferrer();
    error CannotBindReferrer();
    error InvalidRouter();
    error InvalidWBNB();
    error InvalidBaseToken();
    error UnauthorizedRelayer();
    error InvalidBeneficiary();
    error InvalidDepositAmount();
    error DepositRefAlreadyProcessed();
    error InviterMigrationBatchTooLarge();
    error InviterMigrationLengthMismatch();

    using EnumerableSet for EnumerableSet.AddressSet;
    using UniswapOperations for *;
    using SwapOperations for *;

    address public constant companyAccount = 0xAF3c502b67eB54C8b03F06ddfb3017A91D568728;
    address public constant rewardAccount = 0x61c749d4A32136DE9C1AC46ede6C2E493fDC93A8;
    address public constant relayer = 0x2b36B6CdAac80B8d95540824d63853D43283860A;

    /// @dev 入金/卖出产生的 LP 凭证（除用户 dust 外）永久锁死；initialize 加池 to 须一致
    address public constant lpLockRecipient = 0x000000000000000000000000000000000000dEaD;

    Distributor internal immutable _DISTRIBUTOR;

    uint256 public minAmount;
    uint256 public maxAmount;
    uint256 private constant REFERRAL_RATIO = 26;
    uint256 private constant COMPANY_RATIO = 4;
    uint256 private constant NODE_RATIO = 15;
    uint256 private constant LP_RATIO = 55;
    uint256 private constant BIND_AMOUNT = 0.13 ether;
    /// @dev 推荐奖励向上追溯层数
    uint256 private constant REFERRAL_DEPTH = 15;
    /// @dev 节点极差奖励向上追溯层数（比推荐奖励更深）
    uint256 private constant NODE_REWARD_DEPTH = 30;
    /// @dev 卖出量中用户经 pair 换得 BNB 的部分（30%）
    uint256 private constant SELL_USER_PERCENT = 3000;
    /// @dev 卖出量 15% 节点统筹预留：先换 BNB 进 companyAccount，后续由节点领取
    uint256 private constant SELL_COMPANY_PERCENT = 1500;
    /// @dev 卖出总 BNB 价值的 55% 计为入金算力（与 55%「入金式」区块一致）
    uint256 private constant SELL_POWER_BASE_PERCENT = 5500;
    uint256 private constant BASE_PERCENT = 10000;

    uint256 private constant TRIGGER_INTERVAL = 24 hours;
    uint256 private constant COMPENSATION_START_ROUND = 7;
    uint256 private constant COMPENSATION_CAP_ROUNDS = 200;
    /// @dev 池内 GDC 硬底线：通缩/卖出销毁均不得穿破
    uint256 private constant LP_MIN_BALANCE = 21_000_000 * 10 ** 18;
    /// @dev 阶段一虚拟基数初值（固定公式，与池内余额无关）
    uint256 private constant STAGE1_BASE_INITIAL = 1_000_000_000 * 10 ** 18;
    /// @dev 阶段一结束阈值：deflationBase 降至该值后进入阶段二
    uint256 private constant STAGE1_END_BASE = 21_000_000 * 10 ** 18;
    /// @dev 阶段二通缩总额度
    uint256 private constant STAGE2_TOTAL = 1_000_000_000 * 10 ** 18;
    /// @dev 阶段二剩余不足该值时永久停止
    uint256 private constant STAGE2_STOP_REMAIN = 50_000 * 10 ** 18;
    /// @dev 阶段二：每日固定通缩量
    uint256 private constant STAGE2_DAILY = 55_000 * 10 ** 18;

    address public uniswapPair;
    address private constant BLACK_ADDRESS = address(0xdEaD);
    address public bnbTokenAddress;
    address public baseTokenAddress;
    address public uniswapV2RouterContractAddress;
    IUniswapV2Router02 public uniswapV2Router;

    address[] private _taxExcluded;
    bool private _mintingOnDeploy;
    mapping(bytes32 => bool) public processedDepositRefs;
    mapping(address => address) public inviter;
    mapping(address => uint256) public accuntSales;
    mapping(address => uint256) public directTeamSales;
    mapping(address => EnumerableSet.AddressSet) private inviterChildList;

    bool internal swapping;
    mapping(address => uint256) public addLiquidityUnlockTime;

    address public initiallyAddThePoolAddr;
    address[] public lpHolders;
    mapping(address => bool) public isLpHolder;
    mapping(address => uint256) public lpHolderAmount;
    uint256 public rewardPerBatch;

    mapping(address => uint256) public userPower;
    uint256 public totalPower;
    mapping(address => uint256) public userDepositPower;
    uint256 public totalDepositPower;
    /// @dev 阶段一虚拟基数（初始 10 亿，每日按 1% 复利递减）
    uint256 public deflationBase;
    /// @dev 阶段二剩余通缩额度（初始 10 亿）
    uint256 public stage2Remaining;
    /// @dev 阶段一是否已结束（deflationBase ≤ 2100万）
    bool public stage1Ended;
    /// @dev 阶段三：通缩永久停止
    bool public deflationStopped;
    uint256 public deflationCount;

    uint256 public lastTriggerTime;
    uint256 public originalDeflationReward;
    uint256 public totalPowerSnapshot;
    uint256 public lpHoldersLengthSnapshot;
    uint256 public lpHolderIndex;

    struct UserInfo {
        bool hasDeposited;
    }
    mapping(address => UserInfo) public users;
    mapping(address => uint256) public effectiveReferralCount;

    enum NodeLevel {
        None,
        Small,     // 5%
        Big,       // 10%
        Agent,     // 13%
        Super,     // 15%
        Operation  // 15%（与 Super 同档）
    }
    mapping(address => NodeLevel) public nodeLevel;
    mapping(address => uint256) public firstDepositDeflationCount;
    mapping(address => uint256) public lastQualifiedSellDeflationCount;
    /// @dev 当前周期累计收到的通缩奖励（卖出达标分母）
    mapping(address => uint256) public deflationSellBase;
    /// @dev 当前周期累计真实卖出量
    mapping(address => uint256) public cumulativeSellAmount;
    /// @dev 当前周期首次奖励对应的通缩轮次
    mapping(address => uint256) public deflationSellCycleStartCount;

    uint256 private constant DEFLATION_ELIGIBILITY_ROUNDS = 30;
    uint256 private constant QUALIFIED_SELL_RATIO = 15;
    /// @dev 入金新增 LP 中给用户的万分比（1 = 0.01%）
    uint256 private constant USER_LP_BPS = 1;
    uint256 private constant MAX_INVITER_MIGRATION_BATCH = 200;

    event TriggerDailyDeflation(uint256 indexed ledgerBurnAmount, uint256 indexed burnAmount, uint256 indexed holdLPAwardAmount, uint256 rounds, uint256 deflationCount_);
    event Stage1Ended(uint256 finalBase, uint256 deflationCount_);
    event DeflationStopped(uint256 stage2Remaining_, uint256 deflationCount_);
    event DistributeLpRewards(uint256 indexed totalPower_, uint256 indexed proportion, uint256 indexed amount);

    event AddThePool(address indexed from, address indexed to, uint256 indexed amount);
    event RemoveThePool(address indexed from, address indexed to, uint256 indexed amount, uint256 _lpAmount, uint256 lpAmount, uint256 time);
    event UpdateLog(address indexed from, address indexed to, uint256 indexed amount, bool isAdd, bool isRemove);
    event SellProcessed(address indexed user, uint256 totalAmount, uint256 userReceive, uint256 taxAmount, uint256 powerAdded);
    event ReferralRewardAccumulated(address indexed recipient, uint8 indexed level, uint256 amount);
    event NodeRewardDistributed(address indexed user, address indexed node, uint8 level, uint256 diffRate, uint256 amount);
    event NodeRewardRemainder(address indexed user, uint256 amount);
    event LpLeftoverReturned(address indexed user, uint256 amount);
    event LpLeftoverToCompany(address indexed user, uint256 wbnbAmount);
    event DeflationSellBaseIncreased(address indexed user, uint256 amount, uint256 newBase, uint256 cycleStart);
    event CumulativeSellProgress(address indexed user, uint256 amount, uint256 cumulative, uint256 sellBase);
    event QualifiedSellCleared(address indexed user, uint256 sellBase, uint256 cumulative, uint256 deflationCount_);
    event LpSplitAndBurned(address indexed user, uint256 mintedLP, uint256 userLP, uint256 burnedLP);
    event SellBurn(address indexed user, uint256 sellAmount, uint256 burnAmount, uint256 reserveAfter);
    event DepositFor(address indexed relayer, address indexed beneficiary, uint256 amount, uint256 powerAdded);
    event DepositForClaim(
        address indexed relayer,
        address indexed beneficiary,
        uint256 amount,
        bytes32 indexed refId,
        uint256 powerAdded
    );
    event InviterMigrated(address indexed user, address indexed referrer, uint256 batchIndex);

    constructor(
        address _router,
        address _wbnb,
        address _baseToken,
        address _distributor,
        address[] memory _extraTaxExempt
    ) ERC20("GDC", "GDC") Ownable(msg.sender) {
        if (_distributor == address(0)) revert InvalidDistributor();
        if (_router == address(0)) revert InvalidRouter();
        if (_wbnb == address(0)) revert InvalidWBNB();
        if (_baseToken == address(0)) revert InvalidBaseToken();

        minAmount = 0.001 ether;
        maxAmount = 3 ether;
        rewardPerBatch = 50;

        uniswapV2RouterContractAddress = _router;
        uniswapV2Router = IUniswapV2Router02(_router);
        bnbTokenAddress = _wbnb;
        baseTokenAddress = _baseToken;

        uniswapPair = IUniswapV2Factory(IUniswapV2Router02(uniswapV2Router).factory()).createPair(address(this), bnbTokenAddress);

        _approve(address(this), address(uniswapV2Router), ~uint256(0));
        IERC20(bnbTokenAddress).approve(address(uniswapV2Router), ~uint256(0));

        _DISTRIBUTOR = Distributor(_distributor);
        initiallyAddThePoolAddr = 0xD0577AC2FA5ac11e17FEeD65A9c860475F146dBE;

        _addTaxExcluded(address(this));
        _addTaxExcluded(msg.sender);
        _addTaxExcluded(address(_DISTRIBUTOR));
        _addTaxExcluded(_router);

        for (uint256 i = 0; i < _extraTaxExempt.length; i++) {
            _addTaxExcluded(_extraTaxExempt[i]);
        }

        deflationBase = STAGE1_BASE_INITIAL;
        stage2Remaining = STAGE2_TOTAL;
        users[companyAccount].hasDeposited = true;
        users[rewardAccount].hasDeposited = true;

        lastTriggerTime = block.timestamp;
        _mintingOnDeploy = true;
        _mint(msg.sender, 2_400_000_000 * 10 ** decimals());
        _mintingOnDeploy = false;
    }

    function taxExcluded(address account) external view returns (bool) {
        return _isTaxExcluded(account);
    }

    function relayerAllowed(address account) external view returns (bool) {
        return _isRelayer(account);
    }

    function _isTaxExcluded(address account) internal view returns (bool) {
        for (uint256 i = 0; i < _taxExcluded.length; i++) {
            if (_taxExcluded[i] == account) {
                return true;
            }
        }
        return false;
    }

    function _addTaxExcluded(address account) internal {
        if (account == address(0) || _isTaxExcluded(account)) {
            return;
        }
        _taxExcluded.push(account);
    }

    function _isRelayer(address account) internal pure returns (bool) {
        return account == relayer;
    }

    function lpHoldersLength() external view returns (uint256) {
        return lpHolders.length;
    }

    function _deflationTransfer(address from, address to, uint256 amount) internal {
        if (from == address(0)) revert MintNotAllowed();
        super._update(from, to, amount);
    }

    function _hasActiveDistribution() internal view returns (bool) {
        return originalDeflationReward > 0 && totalPower > 0;
    }

    function _getReserves() internal view returns (uint256 rOther, uint256 rThis) {
        IUniswapV2Pair mainPair = IUniswapV2Pair(uniswapPair);
        (uint256 r0, uint256 r1, ) = mainPair.getReserves();
        address tokenOther = baseTokenAddress;
        address tokenThis = address(this);
        if (tokenOther < tokenThis) {
            rOther = r0;
            rThis = r1;
        } else {
            rOther = r1;
            rThis = r0;
        }
    }

    /// @dev 账本应扣量 + 阶段推进（与池内余额无关）
    function _nextDeflationAmount() internal returns (uint256) {
        if (!stage1Ended) {
            uint256 amount = deflationBase / 100;
            deflationBase -= amount;
            if (deflationBase <= STAGE1_END_BASE) {
                stage1Ended = true;
                emit Stage1Ended(deflationBase, deflationCount);
            }
            return amount;
        }
        if (deflationStopped || stage2Remaining <= STAGE2_STOP_REMAIN) {
            return 0;
        }
        uint256 amt = STAGE2_DAILY;
        if (amt > stage2Remaining - STAGE2_STOP_REMAIN) {
            amt = stage2Remaining - STAGE2_STOP_REMAIN;
        }
        if (amt == 0) {
            return 0;
        }
        stage2Remaining -= amt;
        if (stage2Remaining <= STAGE2_STOP_REMAIN) {
            deflationStopped = true;
            emit DeflationStopped(stage2Remaining, deflationCount);
        }
        return amt;
    }

    function _executeDeflation(uint256 rounds) internal returns (uint256 totalBlackAmount, uint256 totalRewardAmount) {
        uint256 dcStart = deflationCount;
        address pair = uniswapPair;
        uint256 ledgerTotal = 0;
        uint256 completed = 0;

        for (uint256 i = 0; i < rounds; i++) {
            if (deflationStopped) {
                break;
            }
            bool wasStage1 = !stage1Ended;
            uint256 deflationAmount = _nextDeflationAmount();
            if (deflationAmount == 0) {
                break;
            }
            ledgerTotal += deflationAmount;
            completed++;

            (, uint256 reserveGdc) = _getReserves();
            uint256 avail = reserveGdc > LP_MIN_BALANCE ? reserveGdc - LP_MIN_BALANCE : 0;
            uint256 actual = deflationAmount < avail ? deflationAmount : avail;

            if (actual > 0) {
                (uint256 burnBps, uint256 awardBps) = _getDeflationSplit(dcStart + completed);
                uint256 blackAmount = (actual * burnBps) / BASE_PERCENT;
                uint256 holdLPAwardAmount = (actual * awardBps) / BASE_PERCENT;
                // 分档取整尾巴并入销毁侧，确保 black + award == actual
                if (blackAmount + holdLPAwardAmount < actual) {
                    blackAmount = actual - holdLPAwardAmount;
                }

                if (blackAmount > 0) {
                    _deflationTransfer(pair, BLACK_ADDRESS, blackAmount);
                    totalBlackAmount += blackAmount;
                }
                if (holdLPAwardAmount > 0) {
                    _deflationTransfer(pair, address(this), holdLPAwardAmount);
                    totalRewardAmount += holdLPAwardAmount;
                }

                IUniswapV2Pair(pair).sync();
            }

            // 本批内刚结束阶段一：不再同一交易里跑阶段二
            if (wasStage1 && stage1Ended) {
                break;
            }
        }

        if (totalRewardAmount > 0) {
            if (originalDeflationReward == 0) {
                originalDeflationReward = totalRewardAmount;
                lpHolderIndex = 0;
            } else {
                originalDeflationReward += totalRewardAmount;
            }
        }
        deflationCount = dcStart + completed;

        emit TriggerDailyDeflation(ledgerTotal, totalBlackAmount, totalRewardAmount, completed, deflationCount);
    }

    function _executeDistribute() internal returns (uint256 usersProcessed) {
        uint256 currentTotalPower = totalPower;
        if (originalDeflationReward == 0 || currentTotalPower == 0) {
            return 0;
        }

        if (lpHolderIndex == 0) {
            totalPowerSnapshot = currentTotalPower;
            lpHoldersLengthSnapshot = lpHolders.length;
        }

        uint256 snapshotTotalPower = totalPowerSnapshot;
        uint256 snapshotLength = lpHoldersLengthSnapshot;

        if (snapshotTotalPower == 0 || snapshotLength == 0) {
            if (snapshotTotalPower == 0) {
                totalPowerSnapshot = 0;
            }
            return 0;
        }

        uint256 batch = rewardPerBatch;
        uint256 end = lpHolderIndex + batch;
        if (end > snapshotLength) {
            end = snapshotLength;
        }

        uint256 precision = 1e15;

        for (uint256 i = lpHolderIndex; i < end; i++) {
            address user = lpHolders[i];
            uint256 userPowerAmount = userPower[user];
            if (userPowerAmount == 0) continue;

            uint256 rewardAmount = (originalDeflationReward * userPowerAmount) / snapshotTotalPower;
            rewardAmount = (rewardAmount / precision) * precision;

            if (rewardAmount > 0) {
                address recipient = _isDeflationRewardEligible(user) ? user : BLACK_ADDRESS;
                _deflationTransfer(address(this), recipient, rewardAmount);
                if (recipient == user) {
                    _increaseDeflationSellBase(user, rewardAmount);
                }
            }

            uint256 proportion = (userPowerAmount * (100 * BASE_PERCENT)) / snapshotTotalPower;
            emit DistributeLpRewards(snapshotTotalPower, proportion, rewardAmount);
            usersProcessed++;
        }

        lpHolderIndex = end;

        if (lpHolderIndex >= snapshotLength) {
            lpHolderIndex = 0;
            originalDeflationReward = 0;
            totalPowerSnapshot = 0;
            lpHoldersLengthSnapshot = 0;
        }
    }

    function _productionDailyTrigger() internal {
        if (deflationStopped) {
            return;
        }
        uint256 nowTime = block.timestamp;
        if (nowTime <= lastTriggerTime + TRIGGER_INTERVAL) {
            return;
        }
        if (lpHolderIndex > 0 && originalDeflationReward > 0) {
            return;
        }

        uint256 rounds = (nowTime - lastTriggerTime) / TRIGGER_INTERVAL;
        // 阶段二：每日只对应一轮通缩
        if (stage1Ended && rounds > 1) {
            rounds = 1;
        }
        lastTriggerTime += rounds * TRIGGER_INTERVAL;
        _executeDeflation(rounds);
    }

    function _isDeflationRewardEligible(address user) internal view returns (bool) {
        if (!users[user].hasDeposited) {
            return false;
        }
        // 无待履行卖出义务：允许领取下一笔奖励并开启新周期
        if (deflationSellBase[user] == 0) {
            return true;
        }
        return deflationCount <= deflationSellCycleStartCount[user] + DEFLATION_ELIGIBILITY_ROUNDS;
    }

    function _increaseDeflationSellBase(address user, uint256 amount) internal {
        if (amount == 0) return;
        uint256 oldBase = deflationSellBase[user];
        if (oldBase == 0) {
            deflationSellCycleStartCount[user] = deflationCount;
        }
        uint256 newBase = oldBase + amount;
        deflationSellBase[user] = newBase;
        emit DeflationSellBaseIncreased(user, amount, newBase, deflationSellCycleStartCount[user]);
    }

    function _splitAndBurnLp(address user, uint256 mintedLP, bool giveDustToUser) internal {
        if (mintedLP == 0) return;
        uint256 userLP = 0;
        if (giveDustToUser) {
            userLP = (mintedLP * USER_LP_BPS) / BASE_PERCENT;
            if (userLP == 0 && mintedLP >= BASE_PERCENT / USER_LP_BPS) {
                userLP = 1;
            }
            if (userLP > mintedLP) {
                userLP = mintedLP;
            }
            if (userLP > 0) {
                IERC20(uniswapPair).transfer(user, userLP);
                lpHolderAmount[user] = lpHolderAmount[user] + userLP;
            }
        }
        uint256 burnedLP = mintedLP - userLP;
        if (burnedLP > 0) {
            IERC20(uniswapPair).transfer(lpLockRecipient, burnedLP);
        }
        emit LpSplitAndBurned(user, mintedLP, userLP, burnedLP);
    }

    function _returnGdcLeftoverToPair(address user, uint256 gdcBalanceBefore) internal {
        uint256 current = balanceOf(address(this));
        if (current <= gdcBalanceBefore) return;
        uint256 leftover = current - gdcBalanceBefore;
        if (leftover > 0) {
            address pair = uniswapPair;
            super._update(address(this), pair, leftover);
            IUniswapV2Pair(pair).sync();
            emit LpLeftoverReturned(user, leftover);
        }
    }

    function _burnSellAgainstPair(address user, uint256 amount) internal {
        // 仅阶段一卖出 1:1 销毁；阶段二/三不再销毁
        if (deflationStopped || stage1Ended || amount == 0) {
            return;
        }
        (, uint256 reserveGdc) = _getReserves();
        if (reserveGdc <= LP_MIN_BALANCE) {
            return;
        }
        uint256 maxBurn = reserveGdc - LP_MIN_BALANCE;
        uint256 burn = amount < maxBurn ? amount : maxBurn;
        if (burn == 0) {
            return;
        }
        address pair = uniswapPair;
        _deflationTransfer(pair, BLACK_ADDRESS, burn);
        IUniswapV2Pair(pair).sync();
        (, uint256 reserveAfter) = _getReserves();
        emit SellBurn(user, amount, burn, reserveAfter);
    }

    function _trackQualifiedSell(address user, uint256 amount) internal {
        uint256 sellBase = deflationSellBase[user];
        if (sellBase == 0 || amount == 0) {
            return;
        }
        uint256 cumulative = cumulativeSellAmount[user] + amount;
        if (cumulative * 100 >= sellBase * QUALIFIED_SELL_RATIO) {
            lastQualifiedSellDeflationCount[user] = deflationCount;
            emit QualifiedSellCleared(user, sellBase, cumulative, deflationCount);
            deflationSellBase[user] = 0;
            cumulativeSellAmount[user] = 0;
            deflationSellCycleStartCount[user] = 0;
        } else {
            cumulativeSellAmount[user] = cumulative;
            emit CumulativeSellProgress(user, amount, cumulative, sellBase);
        }
    }

    receive() external payable {
        uint256 value = msg.value;

        if (value == 0) {
            return;
        }

        if (swapping) {
            return;
        }

        if (value < minAmount || value > maxAmount || isContract(msg.sender)) {
            payable(msg.sender).transfer(value);
            return;
        }

        _processDeposit(msg.sender, value);
    }

    /// @notice 白名单 Relayer 代用户入金，算力与限额均记 beneficiary
    function depositFor(address beneficiary) external payable {
        uint256 value = msg.value;
        if (value == 0) {
            return;
        }
        if (swapping) {
            return;
        }
        uint256 powerAdded = _executeDepositFor(beneficiary, value);
        emit DepositFor(msg.sender, beneficiary, value, powerAdded);
    }

    /// @notice 幂等代投入金：同一 refId 仅可成功一次（商城订单/领取防重试重复打款）
    function depositForClaim(address beneficiary, bytes32 refId) external payable {
        if (processedDepositRefs[refId]) revert DepositRefAlreadyProcessed();
        uint256 value = msg.value;
        if (value == 0) {
            return;
        }
        if (swapping) {
            return;
        }
        uint256 powerAdded = _executeDepositFor(beneficiary, value);
        processedDepositRefs[refId] = true;
        emit DepositForClaim(msg.sender, beneficiary, value, refId, powerAdded);
    }

    function _executeDepositFor(address beneficiary, uint256 value) internal returns (uint256 powerAdded) {
        if (!_isRelayer(msg.sender)) revert UnauthorizedRelayer();
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        if (isContract(msg.sender)) revert UnauthorizedRelayer();

        if (value < minAmount || value > maxAmount) revert InvalidDepositAmount();

        return _processDeposit(beneficiary, value);
    }

    function _processDeposit(address beneficiary, uint256 value) internal returns (uint256 powerAdded) {
        if (inviter[beneficiary] == address(0)) {
            if (isCanBindInviter(beneficiary, companyAccount)) {
                inviter[beneficiary] = companyAccount;
                inviterChildList[companyAccount].add(beneficiary);
            }
        }

        bool isFirstDeposit = !users[beneficiary].hasDeposited;
        if (isFirstDeposit) {
            users[beneficiary].hasDeposited = true;
            firstDepositDeflationCount[beneficiary] = deflationCount;
            address referrer = inviter[beneficiary];
            if (referrer != address(0)) {
                effectiveReferralCount[referrer] = effectiveReferralCount[referrer] + 1;
            }
        }

        accuntSales[beneficiary] = accuntSales[beneficiary] + value;
        directTeamSales[inviter[beneficiary]] = directTeamSales[inviter[beneficiary]] + value;
        userDepositPower[beneficiary] = userDepositPower[beneficiary] + value;
        totalDepositPower = totalDepositPower + value;
        uint256 compensationPower = 0;
        if (deflationCount > COMPENSATION_START_ROUND) {
            uint256 rounds = deflationCount - COMPENSATION_START_ROUND;
            if (rounds > COMPENSATION_CAP_ROUNDS) {
                rounds = COMPENSATION_CAP_ROUNDS;
            }
            compensationPower = (value * rounds * 100) / BASE_PERCENT;
        }
        uint256 totalUserPower = value + compensationPower;
        userPower[beneficiary] = userPower[beneficiary] + totalUserPower;
        totalPower = totalPower + totalUserPower;
        powerAdded = totalUserPower;

        addLiquidityUnlockTime[beneficiary] = block.timestamp;

        uint256 referralAmount = (value * REFERRAL_RATIO) / 100;
        uint256 nodeAmount = (value * NODE_RATIO) / 100;
        uint256 companyAmt = (value * COMPANY_RATIO) / 100;

        _accumulateReferralRewards(beneficiary, referralAmount);
        _distributeNodeRewards(beneficiary, nodeAmount);
        _sendBNB(rewardAccount, companyAmt);

        uint256 lpAmountVal = (value * LP_RATIO) / 100;
        uint256 halfLp = lpAmountVal / 2;

        uint256 balanceBeforeSwap = balanceOf(address(this));
        uint256 tokenAmt = ethToTokenSwap(address(this), halfLp, address(this));

        UniswapOperations.wrapEth(bnbTokenAddress, halfLp);

        uint256 lpTokenAmount = addLiquidityEth(halfLp, tokenAmt);
        _splitAndBurnLp(beneficiary, lpTokenAmount, true);
        _returnGdcLeftoverToPair(beneficiary, balanceBeforeSwap);

        _addLpHolder(beneficiary);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from == address(0) && !_mintingOnDeploy) revert MintNotAllowed();

        if (amount == BIND_AMOUNT && isCanBindInviter(from, to)) {
            inviter[from] = to;
            inviterChildList[to].add(from);
        }

        address actualUser = (from == address(uniswapV2Router)) ? tx.origin : from;

        bool fromExempt = (from == address(uniswapV2Router)) ? _isTaxExcluded(actualUser) : _isTaxExcluded(from);

        if (fromExempt || _isTaxExcluded(to)) {
            super._update(from, to, amount);
            return;
        }

        bool isAdd;
        bool isRemove;

        if (!fromExempt && !_isTaxExcluded(to)) {
            if (to == uniswapPair) {
                uint256 addLPLiquidity = _isAddLiquidity(amount);
                if (addLPLiquidity > 0 && !isContract(from)) {
                    isAdd = true;
                }
            }
        }

        if (from == uniswapPair || from == address(uniswapV2Router)) {
            address actualUserTo = (from == address(uniswapV2Router))
                ? to
                : ((to == address(uniswapV2Router)) ? tx.origin : to);

            bool hasDepositRecord = (addLiquidityUnlockTime[to] > 0) ||
                (addLiquidityUnlockTime[tx.origin] > 0) ||
                (addLiquidityUnlockTime[actualUserTo] > 0);

            if (from == address(uniswapV2Router)) {
                if (hasDepositRecord && !isAdd && to != uniswapPair) {
                    isRemove = true;
                }
            } else if (from == uniswapPair) {
                if (hasDepositRecord) {
                    uint256 removeLPLiquidity = _isRemoveLiquidity(amount);
                    if (removeLPLiquidity > 0 || hasDepositRecord) {
                        isRemove = true;
                    }
                }
            }
        }

        bool fromExemptForDeflation = (from == address(uniswapV2Router)) ? _isTaxExcluded(actualUser) : _isTaxExcluded(from);
        if (!swapping && !fromExemptForDeflation && from != address(this) && from != uniswapPair && !isAdd) {
            swapping = true;
            _productionDailyTrigger();
            swapping = false;
        }

        if (!swapping && _hasActiveDistribution()) {
            swapping = true;
            _executeDistribute();
            swapping = false;
        }

        emit UpdateLog(from, to, amount, isAdd, isRemove);

        if (!fromExempt && !_isTaxExcluded(to)) {
            if (isAdd) {
                if (!_isTaxExcluded(actualUser)) revert AddPoolNotAllowed();
                emit AddThePool(actualUser, to, amount);
            } else if (isRemove) {
                // 放行撤池：标准 AMM 两侧资产转给用户，不清零算力、不销毁 GDC
                IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
                uint256 _lpAmount = pair.balanceOf(to);
                if (_lpAmount == 0) {
                    _lpAmount = pair.balanceOf(tx.origin);
                }
                uint256 lpAmount = lpHolderAmount[to];
                if (lpAmount == 0) {
                    lpAmount = lpHolderAmount[tx.origin];
                }
                uint256 _addLiquidityUnlockTime = addLiquidityUnlockTime[to];
                if (_addLiquidityUnlockTime == 0) {
                    _addLiquidityUnlockTime = addLiquidityUnlockTime[tx.origin];
                }
                emit RemoveThePool(actualUser, to, amount, _lpAmount, lpAmount, _addLiquidityUnlockTime);
            } else if (from == uniswapPair) {
                revert BuyingProhibited();
            } else if (to == uniswapPair) {
                if (!swapping) {
                    swapping = true;
                    amount = swapSellAward(from, actualUser, amount);
                    swapping = false;
                }
            }
        }

        super._update(from, to, amount);
    }

    function _isAddLiquidity(uint256 amount) internal view returns (uint256 liquidity) {
        liquidity = UniswapOperations.isAddLiquidity(uniswapPair, baseTokenAddress, address(this), uniswapV2Router.factory(), amount);
    }

    function _isRemoveLiquidity(uint256 amount) internal view returns (uint256 liquidity) {
        liquidity = UniswapOperations.isRemoveLiquidity(uniswapPair, baseTokenAddress, address(this), amount, balanceOf(uniswapPair));
    }

    function isContract(address _address) private view returns (bool) {
        uint32 size;
        assembly {
            size := extcodesize(_address)
        }
        return (size > 0);
    }

    function ethToTokenSwap(address toToken, uint256 amount, address recipient) internal returns (uint256) {
        uint256 balanceAfter = SwapOperations.ethToTokenSwap(
            uniswapV2Router,
            address(_DISTRIBUTOR),
            bnbTokenAddress,
            toToken,
            address(this),
            amount,
            recipient
        );
        if (toToken == address(this)) {
            super._update(address(_DISTRIBUTOR), recipient, balanceAfter);
        }
        return balanceAfter;
    }

    function addLiquidityEth(uint256 tokenAmtA, uint256 tokenAmtB) internal returns (uint256 mintedLP) {
        if (tokenAmtA == 0) revert InsufficientTokenA();
        if (tokenAmtB == 0) revert InsufficientTokenB();
        uint256 lpBefore = IUniswapV2Pair(uniswapPair).balanceOf(address(this));
        UniswapOperations.addLiquidity(uniswapV2Router, bnbTokenAddress, address(this), tokenAmtA, tokenAmtB, address(this));
        mintedLP = IUniswapV2Pair(uniswapPair).balanceOf(address(this)) - lpBefore;
    }

    function swapSellAward(address transferFrom, address user, uint256 amount) internal returns (uint256) {
        address[] memory pathPower = new address[](2);
        pathPower[0] = address(this);
        pathPower[1] = bnbTokenAddress;
        uint256[] memory amountsPower = uniswapV2Router.getAmountsOut(amount, pathPower);
        uint256 powerToAdd = (amountsPower[1] * SELL_POWER_BASE_PERCENT) / BASE_PERCENT;

        uint256 userGW = (amount * SELL_USER_PERCENT) / BASE_PERCENT;
        uint256 taxGW = amount - userGW;

        super._update(transferFrom, address(this), taxGW);

        uint256 companyGW = (amount * SELL_COMPANY_PERCENT) / BASE_PERCENT;
        uint256 depositGW = taxGW - companyGW;

        uint256 lpGW = (depositGW * LP_RATIO) / 100;
        uint256 refGW = (depositGW * REFERRAL_RATIO) / 100;
        uint256 nodeGW = (depositGW * NODE_RATIO) / 100;
        uint256 awardGW = depositGW - lpGW - refGW - nodeGW;

        uint256 lpKeepGW = lpGW / 2;
        uint256 lpSwapGW = lpGW - lpKeepGW;

        uint256 swapGwTotal = companyGW + refGW + nodeGW + awardGW + lpSwapGW;
        if (swapGwTotal > 0) {
            uint256 bnbBefore = address(this).balance;
            SwapOperations.tokenToEthSwap(uniswapV2Router, bnbTokenAddress, address(this), swapGwTotal, address(this));
            uint256 bnbGot = address(this).balance - bnbBefore;

            uint256 companyBNB = (bnbGot * companyGW) / swapGwTotal;
            uint256 refBNB = (bnbGot * refGW) / swapGwTotal;
            uint256 nodeBNB = (bnbGot * nodeGW) / swapGwTotal;
            uint256 awardBNB = (bnbGot * awardGW) / swapGwTotal;
            uint256 lpBNB = bnbGot - companyBNB - refBNB - nodeBNB - awardBNB;

            _sendBNB(companyAccount, companyBNB);
            _accumulateReferralRewards(user, refBNB);
            _distributeNodeRewards(user, nodeBNB);
            _sendBNB(rewardAccount, awardBNB);

            if (lpBNB > 0 && lpKeepGW > 0) {
                uint256 wbnbBefore = IERC20(bnbTokenAddress).balanceOf(address(this));
                UniswapOperations.wrapEth(bnbTokenAddress, lpBNB);
                uint256 mintedLP = addLiquidityEth(lpBNB, lpKeepGW);
                _splitAndBurnLp(user, mintedLP, false);
                _returnGdcLeftoverToPair(user, 0);
                uint256 wbnbLeftover = IERC20(bnbTokenAddress).balanceOf(address(this)) - wbnbBefore;
                if (wbnbLeftover > 0) {
                    IWETH(bnbTokenAddress).withdraw(wbnbLeftover);
                    _sendBNB(companyAccount, wbnbLeftover);
                    emit LpLeftoverToCompany(user, wbnbLeftover);
                }
            }
        }

        _trackQualifiedSell(user, amount);
        _burnSellAgainstPair(user, amount);

        userPower[user] = userPower[user] + powerToAdd;
        totalPower = totalPower + powerToAdd;
        emit SellProcessed(user, amount, userGW, taxGW, powerToAdd);
        return userGW;
    }

    function _accumulateReferralRewards(address user, uint256 totalReward) internal {
        address currentUser = user;
        uint256 distributedAmount = 0;
        uint256[15] memory levelRates = [uint256(2), 3, 3, 3, 5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1];
        address referrer = inviter[currentUser];
        if (referrer == address(0)) {
            if (totalReward > 0) {
                _sendBNB(companyAccount, totalReward);
                emit ReferralRewardAccumulated(companyAccount, 0, totalReward);
            }
            return;
        }
        for (uint256 levelIndex = 0; levelIndex < REFERRAL_DEPTH; levelIndex++) {
            referrer = inviter[currentUser];
            if (referrer == address(0)) {
                uint256 remaining = totalReward - distributedAmount;
                if (remaining > 0) {
                    _sendBNB(companyAccount, remaining);
                    emit ReferralRewardAccumulated(companyAccount, 0, remaining);
                }
                break;
            }
            uint256 levelRate = levelRates[levelIndex];
            uint256 levelAmount = (totalReward * levelRate) / 26;
            bool giveToReferrer = false;
            if (users[referrer].hasDeposited || referrer == companyAccount) {
                uint256 effectiveCount = effectiveReferralCount[referrer];
                if (effectiveCount >= 8) {
                    giveToReferrer = true;
                } else if (effectiveCount >= 5) {
                    if (levelIndex < 5) giveToReferrer = true;
                } else if (effectiveCount >= 3) {
                    if (levelIndex < 4) giveToReferrer = true;
                } else if (effectiveCount >= 1) {
                    if (levelIndex == 0) giveToReferrer = true;
                }
            }
            if (giveToReferrer) {
                _sendBNB(referrer, levelAmount);
                emit ReferralRewardAccumulated(referrer, uint8(levelIndex + 1), levelAmount);
            } else {
                _sendBNB(companyAccount, levelAmount);
                emit ReferralRewardAccumulated(companyAccount, 0, levelAmount);
            }
            distributedAmount = distributedAmount + levelAmount;
            currentUser = referrer;
        }
    }

    function _addLpHolder(address account) internal {
        if (!isLpHolder[account] && account != initiallyAddThePoolAddr) {
            isLpHolder[account] = true;
            lpHolders.push(account);
        }
    }

    function isCanBindInviter(address from, address to) public view returns (bool) {
        if (inviter[from] != address(0) || from == to) {
            return false;
        }
        address current = to;
        uint8 depth = 0;
        while (current != address(0) && depth < 15) {
            if (current == from) {
                return false;
            }
            current = inviter[current];
            depth++;
        }

        return true;
    }

    function bindReferrer(address referrer) external {
        if (referrer == address(0)) revert ReferrerCannotBeZero();
        if (inviter[msg.sender] != address(0)) revert AlreadyHasReferrer();
        if (!isCanBindInviter(msg.sender, referrer)) revert CannotBindReferrer();

        inviter[msg.sender] = referrer;
        inviterChildList[referrer].add(msg.sender);
    }

    /// @notice Owner 可持续分批导入历史推荐关系（仅写空 inviter；单批 ≤200）
    function migrateInviterBatch(
        address[] calldata userAccounts,
        address[] calldata referrers,
        uint256 batchIndex
    ) external onlyOwner {
        uint256 n = userAccounts.length;
        if (n != referrers.length) revert InviterMigrationLengthMismatch();
        if (n > MAX_INVITER_MIGRATION_BATCH) revert InviterMigrationBatchTooLarge();

        for (uint256 i = 0; i < n; i++) {
            address user = userAccounts[i];
            address referrer = referrers[i];
            if (inviter[user] != address(0)) revert AlreadyHasReferrer();
            if (referrer == address(0)) revert ReferrerCannotBeZero();
            if (!isCanBindInviter(user, referrer)) revert CannotBindReferrer();

            inviter[user] = referrer;
            inviterChildList[referrer].add(user);
            emit InviterMigrated(user, referrer, batchIndex);
        }
    }

    function _getDeflationSplit(uint256 count) internal pure returns (uint256 burnBps, uint256 awardBps) {
        if (count <= 60) {
            return (9000, 1000);
        }
        if (count <= 120) {
            return (8000, 2000);
        }
        if (count <= 180) {
            return (7000, 3000);
        }
        if (count <= 240) {
            return (6000, 4000);
        }
        return (5000, 5000);
    }

    function _levelRate(NodeLevel level) internal pure returns (uint256) {
        if (level == NodeLevel.Small) return 5;
        if (level == NodeLevel.Big) return 10;
        if (level == NodeLevel.Agent) return 13;
        if (level == NodeLevel.Super || level == NodeLevel.Operation) return 15;
        return 0;
    }

    /// @dev 节点按推荐层数限代：小10 / 大15 / 代理20 / 超级&运营30（depth 0 = 第 1 层）
    function _nodeMaxDepth(NodeLevel level) internal pure returns (uint256) {
        if (level == NodeLevel.Small) return 10;
        if (level == NodeLevel.Big) return 15;
        if (level == NodeLevel.Agent) return 20;
        if (level == NodeLevel.Super || level == NodeLevel.Operation) return 30;
        return 0;
    }

    function _distributeNodeRewards(address user, uint256 nodePoolAmount) internal {
        if (nodePoolAmount == 0) {
            return;
        }

        uint256 highestRate = 0;
        uint256 distributed = 0;
        address current = inviter[user];

        for (uint256 depth = 0; depth < NODE_REWARD_DEPTH && current != address(0); depth++) {
            NodeLevel level = nodeLevel[current];
            if (level != NodeLevel.None && depth < _nodeMaxDepth(level)) {
                uint256 rate = _levelRate(level);
                if (rate > highestRate) {
                    uint256 diff = rate - highestRate;
                    uint256 payout = (nodePoolAmount * diff) / NODE_RATIO;
                    if (payout > 0) {
                        _sendBNB(current, payout);
                        distributed += payout;
                        emit NodeRewardDistributed(user, current, uint8(level), diff, payout);
                    }
                    highestRate = rate;
                    if (highestRate >= NODE_RATIO) {
                        break;
                    }
                }
            }
            current = inviter[current];
        }

        uint256 remainder = nodePoolAmount - distributed;
        if (remainder > 0) {
            _sendBNB(companyAccount, remainder);
            emit NodeRewardRemainder(user, remainder);
        }
    }

    function isNode(address account) public view returns (bool) {
        return nodeLevel[account] != NodeLevel.None;
    }

    function setNodeLevels(address[] calldata accounts, NodeLevel[] calldata levels) external onlyOwner {
        require(accounts.length == levels.length, "length mismatch");
        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];
            if (account != address(0)) {
                nodeLevel[account] = levels[i];
            }
        }
    }

    function isDeflationRewardEligible(address user) external view returns (bool) {
        return _isDeflationRewardEligible(user);
    }

    function getInviterChildList(address account) public view returns (address[] memory) {
        return inviterChildList[account].values();
    }

    function setRewardPerBatch(uint256 batch) external onlyOwner {
        rewardPerBatch = batch;
    }

    struct ChildInfo {
        address child;
        uint256 sale;
    }

    function getInviterChildInfo(address account) public view returns (ChildInfo[] memory) {
        uint256 len = inviterChildList[account].length();
        ChildInfo[] memory result = new ChildInfo[](len);
        for (uint256 i = 0; i < len; i++) {
            address child = inviterChildList[account].at(i);
            uint256 sale = directTeamSales[child];
            result[i] = ChildInfo({child: child, sale: sale});
        }
        return result;
    }

    function setMinAmount(uint256 amount) external onlyOwner {
        minAmount = amount;
    }

    function setMaxAmount(uint256 amount) external onlyOwner {
        maxAmount = amount;
    }

    function _sendBNB(address recipient, uint256 amount) internal {
        if (amount == 0 || recipient == address(0)) {
            return;
        }
        (bool ok, ) = payable(recipient).call{value: amount}("");
        require(ok, "BNB transfer failed");
    }
}
