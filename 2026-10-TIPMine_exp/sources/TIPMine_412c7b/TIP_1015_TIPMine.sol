// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TIP Mine - 爆块合约 + 节点/单币质押奖励
 * @notice 从 StakeCore 迁移以下功能以降低 bytecode：
 *   1. 爆块销毁 + 分配（原有）
 *   2. 节点 TIP 奖励池（distributeNodeReward / claimNodeReward）
 *   3. 单币质押（distributeSellFee / stakeTIP / unstakeTIP / claimStakeReward）
 *
 * 分配比例：LP 60%、节点15%、D等级14%、基金会5%、合伙人6%
 * 销毁率：80%→30% 递减 0.5%/天
 * 节点 TIP 分配权重：A=1, B=3, C=10（共14份）
 */

interface ITIPTokenMine {
    function burnFromPool(uint256 amount) external;
    function distributeFromPool(address to, uint256 amount) external;
    function poolBalance() external view returns (uint256);
}

interface ITIPCardMine {
    function cardCount(uint256 _type) external view returns (uint256);
    function userCardType(address _user) external view returns (uint256);
}

interface ITIPStakeCoreRead {
    function isBlacklisted(address _user) external view returns (bool);
}

contract TIPMine is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public tipToken;
    address public stakeCore;
    address public tipCard;
    address public foundation;
    address public partner;
    address public adminContract;

    // ============ 爆块参数 ============
    uint256 public constant DAILY_RELEASE_RATE = 200; // 2%
    uint256 public constant MAX_BURN_RATE = 8000;     // 初始80%
    uint256 public constant MIN_BURN_RATE = 3000;     // 最低30%
    uint256 public constant BURN_DECAY_RATE = 50;     // 每天递减0.5%

    // ============ 分配比例 ============
    uint256 public lpRatio = 6000;       // LP 60%
    uint256 public nodeRatio = 1500;     // 节点 15%
    uint256 public dLevelRatio = 1400;   // D等级 14%
    uint256 public foundationRatio = 500;// 基金会 5%
    uint256 public partnerRatio = 600;   // 合伙人 6%

    // ============ 爆块状态 ============
    uint256 public lastMineTime;
    uint256 public totalMined;
    uint256 public totalBurned;
    uint256 public totalDistributed;
    uint256 public mineDays;
    uint256 public initialTotalSupply;

    // ============ 节点 TIP 奖励（从 StakeCore 迁入） ============
    uint256[3] public nA;  // 每卡累积器: 0=A, 1=B, 2=C
    mapping(address => uint256[3]) public userNftF;  // 用户 debt
    mapping(address => uint256) public totalNodeRewardClaimed;

    // ============ 单币质押（从 StakeCore 迁入） ============
    uint256[4] public sA;  // 奖励累积器
    uint256[4] public tS;  // 各池总质押量
    mapping(address => mapping(uint => uint256)) public sAmt;
    mapping(address => mapping(uint => uint256)) public sDebt;
    mapping(address => mapping(uint => uint256)) public sTime;
    uint256[4] public stakeDurations = [30 days, 90 days, 180 days, 360 days];
    uint256[4] public stakeWeights = [5, 10, 15, 20];

    // ============ 事件 ============
    event Mined(uint256 release, uint256 burn, uint256 distribute, uint256 burnRate, uint256 timestamp);
    event Distributed(address indexed to, uint256 amount, string category);
    event InitialSupplySet(uint256 supply);
    event NodeRewardClaimed(address indexed user, uint8 cardType, uint256 amount);
    event TIPStaked(address indexed user, uint8 pool, uint256 amount);
    event TIPUnstaked(address indexed user, uint8 pool, uint256 amount);
    event StakeRewardClaimed(address indexed user, uint8 pool, uint256 amount);
    event SellFeeDistributed(uint256 amount);

    modifier onlyOwnerOrAdmin() {
        require(msg.sender == owner() || msg.sender == adminContract, "!auth");
        _;
    }

    constructor() Ownable(msg.sender) {}

    // ============ 设置函数 ============
    function setAdminContract(address _admin) external onlyOwner { adminContract = _admin; }
    function setPartner(address _addr) external onlyOwnerOrAdmin { partner = _addr; }
    function setTipToken(address _tip) external onlyOwner { tipToken = IERC20(_tip); }
    function setTipCard(address _card) external onlyOwner { tipCard = _card; }
    function setFoundation(address _addr) external onlyOwnerOrAdmin { foundation = _addr; }

    function setInitialTotalSupply(uint256 _supply) external onlyOwnerOrAdmin {
        require(initialTotalSupply == 0, "set");
        initialTotalSupply = _supply;
        emit InitialSupplySet(_supply);
    }

    function setLastMineTime(uint256 _time) external onlyOwnerOrAdmin { lastMineTime = _time; }

    function setAddresses(address _stakeCore, address _foundation, address _partner) external onlyOwnerOrAdmin {
        stakeCore = _stakeCore;
        foundation = _foundation;
        partner = _partner;
    }

    function setRatios(uint256 _lp, uint256 _node, uint256 _dLevel, uint256 _foundation, uint256 _partner) external onlyOwnerOrAdmin {
        require(_lp + _node + _dLevel + _foundation + _partner == 10000, "!ratios");
        lpRatio = _lp; nodeRatio = _node; dLevelRatio = _dLevel; foundationRatio = _foundation; partnerRatio = _partner;
    }

    // ============ 爆块 ============
    function mine() external nonReentrant {
        require(initialTotalSupply > 0, "!supply");
        require(block.timestamp >= lastMineTime + 1 days, "too early");

        uint256 remaining = initialTotalSupply - totalMined;
        if (remaining == 0) { lastMineTime = block.timestamp; return; }

        uint256 releaseAmount = remaining * DAILY_RELEASE_RATE / 10000;
        if (releaseAmount == 0) { lastMineTime = block.timestamp; return; }
        if (releaseAmount > remaining) releaseAmount = remaining;

        uint256 burnRate = _getCurrentBurnRate();
        uint256 burnAmount = releaseAmount * burnRate / 10000;
        uint256 distributeAmount = releaseAmount - burnAmount;

        lastMineTime = block.timestamp;
        totalMined += releaseAmount;
        totalBurned += burnAmount;
        totalDistributed += distributeAmount;
        mineDays++;

        // 销毁
        if (burnAmount > 0) {
            (bool s, ) = address(tipToken).call(abi.encodeWithSignature("burnFromPool(uint256)", burnAmount));
            require(s, "burn failed");
        }

        // 分配
        uint256 lpAmt = distributeAmount * lpRatio / 10000;
        uint256 nodeAmt = distributeAmount * nodeRatio / 10000;
        uint256 dLevelAmt = distributeAmount * dLevelRatio / 10000;
        uint256 foundAmt = distributeAmount * foundationRatio / 10000;
        uint256 partnerAmt = distributeAmount - lpAmt - nodeAmt - dLevelAmt - foundAmt;

        // LP 奖励 → StakeCore（LP 管理仍在 StakeCore）
        if (lpAmt > 0) {
            (bool s1, ) = address(tipToken).call(abi.encodeWithSignature("distributeFromPool(address,uint256)", stakeCore, lpAmt));
            if (s1) _safeCall(stakeCore, abi.encodeWithSignature("distributeLPReward(uint256)", lpAmt));
            emit Distributed(stakeCore, lpAmt, "LP");
        }

        // 节点奖励 → Mine 自身（TIP 留在 Mine，用户从 Mine 领取）
        if (nodeAmt > 0) {
            (bool s1, ) = address(tipToken).call(abi.encodeWithSignature("distributeFromPool(address,uint256)", address(this), nodeAmt));
            if (s1) _distributeNodeReward(nodeAmt);
            emit Distributed(address(this), nodeAmt, "Node");
        }

        // D等级奖励 → StakeCore（D等级与用户关系紧密耦合，保留在 StakeCore）
        if (dLevelAmt > 0) {
            (bool s1, ) = address(tipToken).call(abi.encodeWithSignature("distributeFromPool(address,uint256)", stakeCore, dLevelAmt));
            if (s1) _safeCall(stakeCore, abi.encodeWithSignature("distributeDRankReward(uint256)", dLevelAmt));
            emit Distributed(stakeCore, dLevelAmt, "DLevel");
        }

        // 基金会
        if (foundAmt > 0 && foundation != address(0)) {
            _safeCall(address(tipToken), abi.encodeWithSignature("distributeFromPool(address,uint256)", foundation, foundAmt));
            emit Distributed(foundation, foundAmt, "Foundation");
        }

        // 合伙人
        if (partnerAmt > 0 && partner != address(0)) {
            _safeCall(address(tipToken), abi.encodeWithSignature("distributeFromPool(address,uint256)", partner, partnerAmt));
            emit Distributed(partner, partnerAmt, "Partner");
        }

        emit Mined(releaseAmount, burnAmount, distributeAmount, burnRate, block.timestamp);
    }

    function _safeCall(address target, bytes memory data) internal returns (bool) {
        (bool success, ) = target.call(data);
        return success;
    }

    function _getCurrentBurnRate() internal view returns (uint256) {
        uint256 rate = MAX_BURN_RATE - (mineDays * BURN_DECAY_RATE);
        return rate < MIN_BURN_RATE ? MIN_BURN_RATE : rate;
    }

    function getNextMineInfo() external view returns (
        uint256 nextMineTime, uint256 burnRate, uint256 estRelease, uint256 estBurn, uint256 estDistribute
    ) {
        nextMineTime = lastMineTime + 1 days;
        burnRate = _getCurrentBurnRate();
        uint256 remaining = initialTotalSupply - totalMined;
        estRelease = remaining * DAILY_RELEASE_RATE / 10000;
        estBurn = estRelease * burnRate / 10000;
        estDistribute = estRelease - estBurn;
    }

    // ============ 节点 TIP 奖励（从 StakeCore 迁入） ============

    function _distributeNodeReward(uint256 _amount) internal {
        require(tipCard != address(0), "!card");
        uint256 cntA = ITIPCardMine(tipCard).cardCount(0);
        uint256 cntB = ITIPCardMine(tipCard).cardCount(1);
        uint256 cntC = ITIPCardMine(tipCard).cardCount(2);
        // 爆块节点15%按权重1:3:10分配（A=1份, B=3份, C=10份, 共14份）
        uint256 shareA = _amount * 1 / 14;
        uint256 shareB = _amount * 3 / 14;
        uint256 shareC = _amount - shareA - shareB;
        if (cntA > 0) nA[0] += shareA / cntA;
        if (cntB > 0) nA[1] += shareB / cntB;
        if (cntC > 0) nA[2] += shareC / cntC;
    }

    function claimNodeReward(uint8 _type) external nonReentrant {
        require(stakeCore != address(0), "!sc");
        require(tipCard != address(0), "!card");
        require(!ITIPStakeCoreRead(stakeCore).isBlacklisted(msg.sender), "blk");
        require(_type < 3, "!t");
        uint256 ct = ITIPCardMine(tipCard).userCardType(msg.sender);
        require(ct == _type + 1, "!card");
        uint256 reward = nA[_type] - userNftF[msg.sender][_type];
        if (reward > 0) {
            userNftF[msg.sender][_type] = nA[_type];
            totalNodeRewardClaimed[msg.sender] += reward;
            tipToken.safeTransfer(msg.sender, reward);
            emit NodeRewardClaimed(msg.sender, _type, reward);
        }
    }

    // ============ 单币质押（从 StakeCore 迁入） ============

    /// @notice 由 StakeCore 转发调用（Core/Token 卖出税 → StakeCore → Mine）
    function distributeSellFee(uint256 _a) external {
        require(msg.sender == stakeCore || msg.sender == owner() || msg.sender == adminContract, "!a");
        for (uint8 i = 0; i < 4; i++) {
            if (tS[i] > 0) sA[i] += _a * stakeWeights[i] / 50 / tS[i];
        }
        emit SellFeeDistributed(_a);
    }

    function stakeTIP(uint8 _t, uint256 _a) external nonReentrant {
        require(_t < 4 && _a > 0, "!t");
        require(stakeCore == address(0) || !ITIPStakeCoreRead(stakeCore).isBlacklisted(msg.sender), "blk");
        tipToken.safeTransferFrom(msg.sender, address(this), _a);
        _csR(msg.sender, _t);
        sAmt[msg.sender][_t] += _a;
        tS[_t] += _a;
        sDebt[msg.sender][_t] = sAmt[msg.sender][_t] * sA[_t];
        sTime[msg.sender][_t] = block.timestamp;
        emit TIPStaked(msg.sender, _t, _a);
    }

    function unstakeTIP(uint8 _t) external nonReentrant {
        require(_t < 4 && sAmt[msg.sender][_t] > 0, "!s");
        require(block.timestamp >= sTime[msg.sender][_t] + stakeDurations[_t], "!time");
        // 黑名单用户可取回本金，但不领取奖励（奖励留在 Mine 合约）
        if (stakeCore == address(0) || !ITIPStakeCoreRead(stakeCore).isBlacklisted(msg.sender)) {
            _csR(msg.sender, _t);
        }
        uint256 a = sAmt[msg.sender][_t];
        tS[_t] -= a;
        sAmt[msg.sender][_t] = 0;
        sDebt[msg.sender][_t] = 0;
        tipToken.safeTransfer(msg.sender, a);
        emit TIPUnstaked(msg.sender, _t, a);
    }

    function claimStakeReward(uint8 _t) external nonReentrant {
        require(stakeCore == address(0) || !ITIPStakeCoreRead(stakeCore).isBlacklisted(msg.sender), "blk");
        _csR(msg.sender, _t);
    }

    function pendingStakeReward(address _u, uint8 _t) external view returns (uint256) {
        if (sAmt[_u][_t] == 0) return 0;
        return sAmt[_u][_t] * sA[_t] - sDebt[_u][_t];
    }

    function _csR(address _u, uint8 _t) internal {
        if (sAmt[_u][_t] > 0 && sA[_t] > 0) {
            uint256 r = sAmt[_u][_t] * sA[_t] - sDebt[_u][_t];
            if (r > 0) {
                sDebt[_u][_t] = sAmt[_u][_t] * sA[_t];
                tipToken.safeTransfer(_u, r);
                emit StakeRewardClaimed(_u, _t, r);
            }
        }
    }

    // ============ 紧急提取 ============
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwnerOrAdmin {
        if (token == address(0)) { payable(to).transfer(amount); }
        else { IERC20(token).transfer(to, amount); }
    }

    receive() external payable {}
}
