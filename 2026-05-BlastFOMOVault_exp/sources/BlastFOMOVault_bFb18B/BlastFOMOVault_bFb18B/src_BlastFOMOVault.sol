// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {VaultBaseV2} from "./flap/VaultBaseV2.sol";
import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {IVaultFactory} from "./flap/IVaultFactory.sol";
import {IFlapTaxTokenV3} from "./flap/IFlapTaxTokenV3.sol";
import {
    VaultUISchema,
    VaultMethodSchema,
    VaultDataSchema,
    FieldDescriptor,
    ApproveAction
} from "./flap/IVaultSchemasV1.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/security/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/utils/Strings.sol";

/// @title BlastFOMOVault
/// @author The Flap Team Community
/// @notice Permissionless Flap tax vault that turns buy-side tax inflow into a
///         decaying hype meter and unlocks claimable BNB bonus rounds.
/// @dev
/// - Inherits `VaultBaseV2` to satisfy Flap Vault V2 requirements.
/// - `receive()` is intentionally lightweight: no loops and no value-transferring
///   external calls. Only the token's TaxProcessor may feed revenue into the vault.
/// - Hype decays linearly by `decayPerBlock` every block.
/// - When decayed hype is at or above `threshold`, the vault enters Blast Mode.
/// - In each blast round, every address may claim once.
/// - Bonus payout is a live percentage of the current `bonusPool` balance:
///   5% at threshold, scaling linearly up to 20%.
/// - A referrer may receive 2% of the total reward, carved out of the same
///   payout rather than draining the pool further.
/// - An optional immutable commission receiver can later withdraw the
///   recommended commission accrued from incoming tax revenue.
contract BlastFOMOVault is VaultBaseV2, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MIN_BONUS_BPS = 500;
    uint256 public constant MAX_BONUS_BPS = 2_000;
    uint256 public constant REFERRAL_BPS = 200;
    uint256 public constant MARKETING_BPS = 3_500;
    uint256 public constant HYPE_PER_BNB_WEI = 100;
    uint256 public constant DEFAULT_THRESHOLD = 1_000 ether;
    uint256 public constant DEFAULT_DECAY_PER_BLOCK = 10;
    uint256 public constant MAX_BONUS_SCORE_MULTIPLIER = 4;

    /// @notice Tax token associated with this vault.
    address public immutable taxToken;

    /// @notice Immutable recipient of accrued commission. Zero disables commission withdrawal.
    address public immutable commissionReceiver;

    /// @notice Immutable recipient of the fixed 35% marketing reserve. Zero disables marketing reserve.
    address public immutable marketingReceiver;

    /// @notice Cached effective tax rate in basis points. Recommended value is max(buyTaxRate, sellTaxRate).
    uint16 public immutable taxRateBpsHint;

    /// @notice Hype score required to enter Blast Mode.
    uint256 public immutable threshold;

    /// @notice Hype score decayed per block.
    uint256 public immutable decayPerBlock;

    /// @notice Last persisted hype score before applying pending decay.
    uint256 public hypeScoreStored;

    /// @notice Block number at which `hypeScoreStored` was last synchronised.
    uint256 public lastHypeUpdateBlock;

    /// @notice Current bonus pool available for claimers, excluding reserved commission.
    uint256 public bonusPool;

    /// @notice Commission that has been reserved but not yet withdrawn.
    uint256 public pendingCommission;

    /// @notice Marketing reserve that has been accrued but not yet withdrawn.
    uint256 public pendingMarketing;

    /// @notice Informational total of recommended commission ever computed.
    uint256 public totalRecommendedCommission;

    /// @notice Current blast round id. Increments each time hype crosses threshold from below.
    uint256 public blastRound;

    /// @notice Tracks the last blast round claimed by each user.
    mapping(address => uint256) public lastClaimedRound;

    event HypeUpdated(
        uint256 previousHypeScore,
        uint256 newHypeScore,
        uint256 receivedAmount,
        uint256 marketingReserved,
        uint256 commissionReserved,
        uint256 bonusPool,
        uint256 updateBlock
    );
    event BlastModeTriggered(uint256 indexed blastRound, uint256 hypeScore, uint256 threshold);
    event BonusClaimed(
        address indexed claimer,
        address indexed referrer,
        uint256 indexed blastRound,
        uint256 claimerReward,
        uint256 referrerReward,
        uint256 bonusBps
    );
    event CommissionWithdrawn(address indexed receiver, uint256 amount);
    event MarketingWithdrawn(address indexed receiver, uint256 amount);
    event EmergencyWithdrawNative(address indexed to, uint256 amount);
    event EmergencyWithdrawToken(address indexed token, address indexed to, uint256 amount);

    modifier onlyGuardian() {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian 调用");
        _;
    }

    /// @param _taxToken Predicted Flap V3 tax token address passed by VaultPortal.
    /// @param _threshold Blast threshold. Use 1000 ether-equivalent by default.
    /// @param _decayPerBlock Linear hype decay applied every block.
    /// @param _taxRateBpsHint Effective token tax rate in bps, normally max(buyTaxRate, sellTaxRate).
    /// @param _marketingReceiver Recipient of the fixed 35% marketing reserve; zero disables reserve.
    /// @param _commissionReceiver Recipient of reserved commission; zero disables withdrawal.
    constructor(
        address _taxToken,
        uint256 _threshold,
        uint256 _decayPerBlock,
        uint16 _taxRateBpsHint,
        address _marketingReceiver,
        address _commissionReceiver
    ) {
        require(_taxToken != address(0), unicode"Invalid tax token / 无效税币地址");
        require(_threshold > 0, unicode"Invalid threshold / 无效阈值");
        require(_decayPerBlock > 0, unicode"Invalid decay / 无效衰减参数");

        taxToken = _taxToken;
        threshold = _threshold;
        decayPerBlock = _decayPerBlock;
        taxRateBpsHint = _taxRateBpsHint;
        marketingReceiver = _marketingReceiver;
        commissionReceiver = _commissionReceiver;
        lastHypeUpdateBlock = block.number;
    }

    /// @inheritdoc VaultBaseV2
    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "BlastFOMOVault";
        schema.description = unicode"A decaying hype-based Flap vault. Incoming BNB tax boosts hype, "
            unicode"Blast Mode unlocks bonus claims, and referrers can share the reward. / "
            unicode"一个基于热度衰减的 Flap 金库：收到 BNB 税收会提升热度，进入 Blast Mode 后可领取奖励，推荐人也可分成。";

        schema.methods = new VaultMethodSchema[](9);

        schema.methods[0].name = "getHypeScore";
        schema.methods[0].description =
            unicode"Returns the current decayed hype score. / 返回当前按区块衰减后的热度分数。";
        schema.methods[0].inputs = new FieldDescriptor[](0);
        schema.methods[0].outputs = new FieldDescriptor[](1);
        schema.methods[0].outputs[0] =
            FieldDescriptor("hypeScore", "uint256", unicode"Current decayed hype score / 当前衰减后热度分数", 18);
        schema.methods[0].approvals = new ApproveAction[](0);

        schema.methods[1].name = "isBlastMode";
        schema.methods[1].description = unicode"Returns whether Blast Mode is active. / 返回是否处于 Blast Mode。";
        schema.methods[1].inputs = new FieldDescriptor[](0);
        schema.methods[1].outputs = new FieldDescriptor[](1);
        schema.methods[1].outputs[0] =
            FieldDescriptor("active", "bool", unicode"True if blast mode is active / 当前是否处于 Blast Mode", 0);
        schema.methods[1].approvals = new ApproveAction[](0);

        schema.methods[2].name = "getCurrentBonusBps";
        schema.methods[2].description =
            unicode"Returns the live claimer bonus in basis points. / 返回当前领取者奖金比例（基点）。";
        schema.methods[2].inputs = new FieldDescriptor[](0);
        schema.methods[2].outputs = new FieldDescriptor[](1);
        schema.methods[2].outputs[0] = FieldDescriptor(
            "bonusBps", "uint256", unicode"Current bonus in basis points / 当前奖金基点比例", 0
        );
        schema.methods[2].approvals = new ApproveAction[](0);

        schema.methods[3].name = "getClaimableBonus";
        schema.methods[3].description = unicode"Returns the current claimable BNB bonus for a user. / 返回指定地址当前可领取的 BNB 奖金。";
        schema.methods[3].inputs = new FieldDescriptor[](1);
        schema.methods[3].inputs[0] =
            FieldDescriptor("user", "address", unicode"User address to query / 待查询用户地址", 0);
        schema.methods[3].outputs = new FieldDescriptor[](1);
        schema.methods[3].outputs[0] =
            FieldDescriptor("amount", "uint256", unicode"Claimable BNB bonus / 可领取 BNB 奖金", 18);
        schema.methods[3].approvals = new ApproveAction[](0);

        schema.methods[4].name = "claimBonus";
        schema.methods[4].description = unicode"Claim Blast Mode BNB bonus. If a valid referrer is provided, 2% of the same payout is shared with the referrer. / "
            unicode"领取 Blast Mode BNB 奖金；若提供有效推荐人，则从同一笔奖励中切出 2% 分给推荐人。";
        schema.methods[4].inputs = new FieldDescriptor[](1);
        schema.methods[4].inputs[0] =
            FieldDescriptor("referrer", "address", unicode"Optional referral address / 可选推荐人地址", 0);
        schema.methods[4].outputs = new FieldDescriptor[](0);
        schema.methods[4].approvals = new ApproveAction[](0);
        schema.methods[4].isWriteMethod = true;

        schema.methods[5].name = "withdrawCommission";
        schema.methods[5].description =
            unicode"Withdraw accrued recommended commission to the immutable commission receiver. / 提取累积的推荐 commission 到不可变接收地址。";
        schema.methods[5].inputs = new FieldDescriptor[](0);
        schema.methods[5].outputs = new FieldDescriptor[](0);
        schema.methods[5].approvals = new ApproveAction[](0);
        schema.methods[5].isWriteMethod = true;

        schema.methods[6].name = "getPendingCommission";
        schema.methods[6].description =
            unicode"Returns the unwithdrawn recommended commission reserve. / 返回尚未提取的推荐 commission 预留。";
        schema.methods[6].inputs = new FieldDescriptor[](0);
        schema.methods[6].outputs = new FieldDescriptor[](1);
        schema.methods[6].outputs[0] = FieldDescriptor(
            "pendingCommission", "uint256", unicode"Unwithdrawn commission reserve / 未提取 commission 预留金额", 18
        );
        schema.methods[6].approvals = new ApproveAction[](0);

        schema.methods[7].name = "getPendingMarketing";
        schema.methods[7].description =
            unicode"Returns the unwithdrawn 35% marketing reserve. / 返回尚未提取的 35% 营销预留。";
        schema.methods[7].inputs = new FieldDescriptor[](0);
        schema.methods[7].outputs = new FieldDescriptor[](1);
        schema.methods[7].outputs[0] = FieldDescriptor(
            "pendingMarketing", "uint256", unicode"Unwithdrawn marketing reserve / 未提取营销预留金额", 18
        );
        schema.methods[7].approvals = new ApproveAction[](0);

        schema.methods[8].name = "withdrawMarketing";
        schema.methods[8].description =
            unicode"Withdraw accrued marketing reserve to the immutable marketing receiver. / 提取累积营销预留到不可变营销地址。";
        schema.methods[8].inputs = new FieldDescriptor[](0);
        schema.methods[8].outputs = new FieldDescriptor[](0);
        schema.methods[8].approvals = new ApproveAction[](0);
        schema.methods[8].isWriteMethod = true;
    }

    /// @notice Returns a dynamic bilingual summary for Flap UI display.
    function description() public view override returns (string memory) {
        uint256 liveHype = _previewHypeScore();
        bool blastActive = liveHype >= threshold;
        uint256 bonusBps = _previewCurrentBonusBps(liveHype);
        string memory en = string(
            abi.encodePacked(
                unicode"BlastFOMOVault | Hype: ",
                _formatFixed3(liveHype),
                unicode" | Mode: ",
                blastActive ? unicode"BLAST" : unicode"IDLE",
                unicode" | Bonus: ",
                (bonusBps / 100).toString(),
                unicode"% | Pool: ",
                _formatFixed3(bonusPool),
                unicode" BNB | Mkt: 35%"
            )
        );
        string memory zh = string(
            abi.encodePacked(
                unicode" / 热度: ",
                _formatFixed3(liveHype),
                unicode" | 模式: ",
                blastActive ? unicode"爆发中" : unicode"待机中",
                unicode" | 奖金: ",
                (bonusBps / 100).toString(),
                unicode"% | 奖金池: ",
                _formatFixed3(bonusPool),
                unicode" BNB | 营销: 35%"
            )
        );

        return string(abi.encodePacked(en, zh));
    }

    /// @notice Accept BNB tax revenue from Flap and update hype + accounting.
    /// @dev Keeps the call tree simple to stay safely under the Flap receive-gas limit.
    receive() external payable {
        if (msg.value == 0) {
            return;
        }

        require(_isAuthorizedRevenueSender(), unicode"Only TaxProcessor / 仅限 TaxProcessor 入金");

        (, uint256 liveScore) = _syncHypeScore();

        uint256 reservedMarketing = 0;
        if (marketingReceiver != address(0)) {
            reservedMarketing = (msg.value * MARKETING_BPS) / BPS_DENOMINATOR;
            pendingMarketing += reservedMarketing;
        }

        uint256 postMarketingRevenue = msg.value - reservedMarketing;
        uint256 recommendedCommission = _quoteRecommendedCommission(postMarketingRevenue);
        totalRecommendedCommission += recommendedCommission;

        uint256 reservedCommission = 0;
        if (commissionReceiver != address(0) && recommendedCommission > 0) {
            reservedCommission = recommendedCommission;
            pendingCommission += reservedCommission;
        }

        uint256 netRevenue = postMarketingRevenue - reservedCommission;
        bonusPool += netRevenue;

        hypeScoreStored = liveScore + (msg.value * HYPE_PER_BNB_WEI);

        emit HypeUpdated(
            liveScore, hypeScoreStored, msg.value, reservedMarketing, reservedCommission, bonusPool, block.number
        );

        if (liveScore < threshold && hypeScoreStored >= threshold) {
            blastRound += 1;
            emit BlastModeTriggered(blastRound, hypeScoreStored, threshold);
        }
    }

    /// @notice Claim the current Blast Mode bonus for the caller.
    /// @param referrer Optional referral address. Zero address and self-referral are ignored.
    function claimBonus(address referrer) external nonReentrant {
        _syncHypeScore();

        require(hypeScoreStored >= threshold, unicode"Blast mode inactive / Blast Mode 未开启");
        require(blastRound > 0, unicode"No blast round / 尚未进入爆发轮次");
        require(lastClaimedRound[msg.sender] < blastRound, unicode"Already claimed / 当前轮次已领取");

        uint256 bonusBps = _previewCurrentBonusBps(hypeScoreStored);
        require(bonusBps >= MIN_BONUS_BPS, unicode"Bonus unavailable / 当前无可领奖金");

        uint256 totalReward = _previewClaimableBonus(msg.sender, hypeScoreStored, bonusPool, blastRound);
        require(totalReward > 0, unicode"No claimable bonus / 当前无可领奖金");

        uint256 referrerReward = 0;
        uint256 claimerReward = totalReward;
        if (referrer != address(0) && referrer != msg.sender) {
            referrerReward = (totalReward * REFERRAL_BPS) / BPS_DENOMINATOR;
            claimerReward = totalReward - referrerReward;
        }

        uint256 totalPayout = totalReward;
        require(totalPayout <= bonusPool, unicode"Insufficient bonus pool / 奖金池余额不足");

        lastClaimedRound[msg.sender] = blastRound;
        bonusPool -= totalPayout;

        (bool claimerOk,) = payable(msg.sender).call{value: claimerReward}("");
        require(claimerOk, unicode"Bonus transfer failed / 奖金转账失败");

        if (referrerReward > 0) {
            (bool referrerOk,) = payable(referrer).call{value: referrerReward}("");
            require(referrerOk, unicode"Referral transfer failed / 推荐奖励转账失败");
        }

        emit BonusClaimed(msg.sender, referrer, blastRound, claimerReward, referrerReward, bonusBps);
    }

    /// @notice Withdraw reserved commission to the immutable commission receiver.
    /// @dev This function is permissionless to call but can only pay the configured receiver.
    function withdrawCommission() external nonReentrant {
        require(commissionReceiver != address(0), unicode"Commission disabled / 未启用 commission");
        require(msg.sender == commissionReceiver, unicode"Only receiver / 仅限接收地址调用");

        uint256 amount = pendingCommission;
        require(amount > 0, unicode"No commission / 无可提取 commission");

        pendingCommission = 0;

        (bool ok,) = payable(commissionReceiver).call{value: amount}("");
        require(ok, unicode"Commission transfer failed / commission 转账失败");

        emit CommissionWithdrawn(commissionReceiver, amount);
    }

    /// @notice Withdraw reserved marketing funds to the immutable marketing receiver.
    function withdrawMarketing() external nonReentrant {
        require(marketingReceiver != address(0), unicode"Marketing disabled / 未启用营销预留");
        require(msg.sender == marketingReceiver, unicode"Only marketing receiver / 仅限营销接收地址调用");

        uint256 amount = pendingMarketing;
        require(amount > 0, unicode"No marketing reserve / 无可提取营销预留");

        pendingMarketing = 0;

        (bool ok,) = payable(marketingReceiver).call{value: amount}("");
        require(ok, unicode"Marketing transfer failed / 营销转账失败");

        emit MarketingWithdrawn(marketingReceiver, amount);
    }

    function emergencyWithdrawNative(address to) external onlyGuardian nonReentrant {
        require(to != address(0), unicode"Zero address / 零地址");
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok,) = to.call{value: bal}("");
            require(ok, unicode"Native transfer failed / 原生币转账失败");
            emit EmergencyWithdrawNative(to, bal);
        }
    }

    function emergencyWithdrawToken(address token, address to) external onlyGuardian nonReentrant {
        require(token != address(0) && to != address(0), unicode"Zero address / 零地址");
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(to, bal);
            emit EmergencyWithdrawToken(token, to, bal);
        }
    }

    /// @notice Returns the current live hype score after block-based decay.
    function getHypeScore() public view returns (uint256) {
        return _previewHypeScore();
    }

    /// @notice Returns whether the vault is currently in Blast Mode.
    function isBlastMode() public view returns (bool) {
        return _previewHypeScore() >= threshold;
    }

    /// @notice Returns the current claimer reward rate in basis points.
    function getCurrentBonusBps() public view returns (uint256) {
        return _previewCurrentBonusBps(_previewHypeScore());
    }

    /// @notice Returns the next bonus percentage as a whole-number percent for front ends.
    function nextBonusPercent() external view returns (uint256) {
        return getCurrentBonusBps() / 100;
    }

    /// @notice Returns the current claimable bonus for a specific user.
    function getClaimableBonus(address user) public view returns (uint256) {
        uint256 liveHype = _previewHypeScore();
        return _previewClaimableBonus(user, liveHype, bonusPool, blastRound);
    }

    /// @notice Alias for front ends that prefer a descriptive name.
    function claimableAmount(address user) external view returns (uint256) {
        return getClaimableBonus(user);
    }

    /// @notice Returns the current reserved commission balance.
    function getPendingCommission() external view returns (uint256) {
        return pendingCommission;
    }

    /// @notice Returns the current reserved marketing balance.
    function getPendingMarketing() external view returns (uint256) {
        return pendingMarketing;
    }

    /// @dev Returns whether the current sender matches the tax token's live TaxProcessor.
    function _isAuthorizedRevenueSender() internal view returns (bool) {
        if (taxToken.code.length == 0) {
            return false;
        }

        try IFlapTaxTokenV3(taxToken).taxProcessor() returns (address processor) {
            return msg.sender == processor && processor != address(0);
        } catch {
            return false;
        }
    }

    /// @notice Returns whether the associated tax token is already deployed and looks like a Flap V3 token.
    function isTaxTokenInitialized() external view returns (bool) {
        if (taxToken.code.length == 0) {
            return false;
        }

        try IFlapTaxTokenV3(taxToken).taxProcessor() returns (address processor) {
            return processor != address(0);
        } catch {
            return false;
        }
    }

    /// @dev Applies pending decay to the stored hype score and persists the result.
    function _syncHypeScore() internal returns (uint256 previousScore, uint256 liveScore) {
        previousScore = hypeScoreStored;
        liveScore = _previewHypeScore();
        if (liveScore != previousScore) {
            hypeScoreStored = liveScore;
        }
        lastHypeUpdateBlock = block.number;
    }

    /// @dev Computes the live hype score without mutating storage.
    function _previewHypeScore() internal view returns (uint256) {
        uint256 score = hypeScoreStored;
        uint256 blocksElapsed = block.number - lastHypeUpdateBlock;
        if (score == 0 || blocksElapsed == 0) {
            return score;
        }

        uint256 totalDecay = blocksElapsed * decayPerBlock;
        if (totalDecay >= score) {
            return 0;
        }

        return score - totalDecay;
    }

    /// @dev Computes the current bonus bps from a supplied hype score.
    function _previewCurrentBonusBps(uint256 liveHype) internal view returns (uint256) {
        if (liveHype < threshold) {
            return 0;
        }

        uint256 maxScore = threshold * MAX_BONUS_SCORE_MULTIPLIER;
        if (liveHype >= maxScore) {
            return MAX_BONUS_BPS;
        }

        uint256 extra = liveHype - threshold;
        uint256 span = maxScore - threshold;
        return MIN_BONUS_BPS + ((MAX_BONUS_BPS - MIN_BONUS_BPS) * extra) / span;
    }

    /// @dev Computes the claimable reward for a user from the provided state snapshot.
    function _previewClaimableBonus(address user, uint256 liveHype, uint256 liveBonusPool, uint256 liveBlastRound)
        internal
        view
        returns (uint256)
    {
        if (user == address(0)) {
            return 0;
        }
        if (liveHype < threshold || liveBlastRound == 0) {
            return 0;
        }
        if (lastClaimedRound[user] >= liveBlastRound) {
            return 0;
        }

        uint256 bonusBps = _previewCurrentBonusBps(liveHype);
        if (bonusBps == 0 || liveBonusPool == 0) {
            return 0;
        }

        return (liveBonusPool * bonusBps) / BPS_DENOMINATOR;
    }

    /// @dev Computes the Flap-recommended commission for a revenue amount.
    function _quoteRecommendedCommission(uint256 amount) internal view returns (uint256) {
        if (amount == 0 || taxRateBpsHint == 0) {
            return 0;
        }

        if (taxRateBpsHint <= 100) {
            return (amount * 600) / BPS_DENOMINATOR;
        }

        return (amount * 6) / taxRateBpsHint;
    }

    /// @dev Formats an 18-decimal fixed-point value using 3 decimals for readable descriptions.
    function _formatFixed3(uint256 value) internal pure returns (string memory) {
        uint256 integerPart = value / 1 ether;
        uint256 fractionalPart = (value % 1 ether) / 1e15;

        if (fractionalPart == 0) {
            return integerPart.toString();
        }

        if (fractionalPart < 10) {
            return string(abi.encodePacked(integerPart.toString(), ".00", fractionalPart.toString()));
        }
        if (fractionalPart < 100) {
            return string(abi.encodePacked(integerPart.toString(), ".0", fractionalPart.toString()));
        }

        return string(abi.encodePacked(integerPart.toString(), ".", fractionalPart.toString()));
    }
}

/// @title BlastFOMOVaultFactory
/// @author The Flap Team Community
/// @notice Factory that deploys `BlastFOMOVault` instances for Flap VaultPortal.
/// @dev `vaultData` is ABI-encoded as:
///      `(uint256 threshold, uint256 decayPerBlock, uint16 taxRateBpsHint, address marketingReceiver, address commissionReceiver)`
contract BlastFOMOVaultFactory is VaultFactoryBaseV2 {
    /// @inheritdoc IVaultFactory
    function newVault(address taxToken, address, address, bytes calldata vaultData)
        external
        override
        returns (address vault)
    {
        require(msg.sender == _getVaultPortal(), unicode"Only VaultPortal / 仅限 VaultPortal 调用");

        (
            uint256 threshold_,
            uint256 decayPerBlock_,
            uint16 taxRateBpsHint_,
            address marketingReceiver_,
            address commissionReceiver_
        ) = abi.decode(vaultData, (uint256, uint256, uint16, address, address));

        BlastFOMOVault deployed =
            new BlastFOMOVault(
                taxToken, threshold_, decayPerBlock_, taxRateBpsHint_, marketingReceiver_, commissionReceiver_
            );

        vault = address(deployed);
    }

    /// @inheritdoc IVaultFactory
    function isQuoteTokenSupported(address) external pure override returns (bool supported) {
        return true;
    }

    /// @inheritdoc VaultFactoryBaseV2
    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description = unicode"Creates a BlastFOMOVault. Incoming BNB tax boosts a decaying hype score; "
            unicode"35% is reserved for marketing, optional commission is reserved next, and the remainder funds a 5%-20% bonus pool. / "
            unicode"创建 BlastFOMOVault：收到 BNB 税收后，35% 固定预留给营销，可选 commission 随后预留，剩余部分进入 5%-20% 奖金池。";

        schema.fields = new FieldDescriptor[](5);
        schema.fields[0] = FieldDescriptor(
            "threshold", "uint256", unicode"Blast threshold in 18-decimal BNB units / 18位精度 BNB 爆发阈值", 18
        );
        schema.fields[1] = FieldDescriptor(
            "decayPerBlock", "uint256", unicode"Hype decay applied every block / 每个区块扣减的热度值", 0
        );
        schema.fields[2] = FieldDescriptor(
            "taxRateBpsHint",
            "uint16",
            unicode"Effective tax rate in bps, normally max(buyTaxRate, sellTaxRate) / 有效税率基点，通常取买卖税率较大值",
            0
        );
        schema.fields[3] = FieldDescriptor(
            "marketingReceiver",
            "address",
            unicode"Marketing receiver for the fixed 35% reserve; zero address disables reserve / 固定 35% 营销预留接收地址，零地址表示关闭",
            0
        );
        schema.fields[4] = FieldDescriptor(
            "commissionReceiver",
            "address",
            unicode"Optional commission receiver; set zero address to disable commission reservation / 可选 commission 接收地址，零地址表示关闭预留",
            0
        );
        schema.isArray = false;
    }
}
