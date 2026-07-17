// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {INodeNFT} from "./interfaces/INodeNFT.sol";
import {ITokenWhiteList} from "./interfaces/ITokenWhiteList.sol";
import {IUserRelation} from "./interfaces/IUserRelation.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Factory} from "v2-core/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "v2-core/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Router02} from "v2-periphery/interfaces/IUniswapV2Router02.sol";
import {IWETH} from "v2-periphery/interfaces/IWETH.sol";

/**
 * @title StakingUpgradeable
 * @notice 可升级的质押合约框架
 */
/// @custom:oz-upgrades-from src/StakingUpgradeableV8.sol:StakingUpgradeableV8
contract StakingUpgradeableV10 is Initializable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    // ============ 结构体 ============

    struct StakeInfo {
        address user;
        uint256 amount; // 质押的BNB数量
        uint256 lpAmount; // LP数量，兑换成LP
        uint256 startTime;
        bool isStaking; // 是否质押中
        bool isImported; // 是否为导入的质押记录
    }
    // 质押信息列表，每人只能质押一笔
    StakeInfo[] public stakeInfoList;
    // 用户质押index,对应stakeInfoList
    mapping(address => uint256) public userStakeIndex;
    // 总质押数量
    uint256 public totalStakeAmount;

    // 总质押的LP数量
    uint256 public totalStakeLpAmount;

    uint256 public PERCENT_BASE;

    // ============ 状态变量 ============

    // 质押代币地址
    IERC20 public stakingToken;
    // Uniswap Router
    IUniswapV2Router02 public router;
    // Uniswap Pair
    IUniswapV2Pair public pair;
    // LP Token
    IERC20 public lpToken;
    // NFT合约地址
    address public nftAddr;
    // 最小质押金额 0.1 BNB
    uint256 public MIN_STAKE_AMOUNT;
    // 最大质押金额 2 BNB
    uint256 public MAX_STAKE_AMOUNT;
    // 兑换比例
    uint256 public LP_RATE; // 70%
    uint256 public DIRECT_REWARD_RATE; // 5% 直推奖励
    uint256 public TEAM_REWARD_RATE; // 20% 团队奖励
    uint256 public NFT_DIVIDEND_RATE; // 5%

    // 提现地址 也就是发放奖励的地址
    address public WITHDRAW_ADDR;
    // 关系合约地址
    address public RELATION_ADDR;

    address public BNB_TOKEN_ADDRESS;
    // open
    bool public isOpen;

    // ============ 事件 ============

    event Stake(address indexed user, uint256 bnbAmount, uint256 lpAmount, bool isImported);
    event Unstake(address indexed user, uint256 bnbAmount, uint256 lpAmount);
    // 5% 直推奖励
    event DirectReward(address indexed from, address indexed to, uint256 bnbAmount);
    // 20% 团队奖励（转给WITHDRAW_ADDR）
    event TeamReward(address indexed from, address indexed to, uint256 bnbAmount);
    // 5%NFT分红池
    event NftDividend(address indexed from, address indexed to, uint256 bnbAmount);

    // ============ 初始化 ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice 初始化函数
     * @param _owner 合约所有者
     * @param _stakingToken 质押代币地址
     * @param _router Uniswap Router地址
     * @param _nftAddr NFT合约地址
     * @param _relationAddr 关系合约地址
     * @param _withdrawAddr 提现地址
     */
    function initialize(
        address _owner,
        address _stakingToken,
        address _router,
        address _nftAddr,
        address _relationAddr,
        address _withdrawAddr
    ) public initializer {
        __Ownable_init(_owner);
        __Pausable_init();

        stakingToken = IERC20(_stakingToken);
        router = IUniswapV2Router02(_router);
        nftAddr = _nftAddr;
        RELATION_ADDR = _relationAddr;
        WITHDRAW_ADDR = _withdrawAddr;

        PERCENT_BASE = 10000;

        MIN_STAKE_AMOUNT = 0.1 ether;

        // 最大质押金额 2 BNB
        MAX_STAKE_AMOUNT = 2 ether;

        // 兑换比例
        LP_RATE = 7000; // 70%
        DIRECT_REWARD_RATE = 500; // 5% 直推奖励
        TEAM_REWARD_RATE = 2000; // 20% 团队奖励
        NFT_DIVIDEND_RATE = 500; // 5%
        BNB_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        // 创建交易对
        address pairAddr = IUniswapV2Factory(router.factory()).getPair(router.WETH(), _stakingToken);
        pair = IUniswapV2Pair(pairAddr);
        lpToken = IERC20(pairAddr);

        // 授权Router使用质押代币和LP代币
        IERC20(_stakingToken).approve(address(router), type(uint256).max);
        IERC20(pairAddr).approve(address(router), type(uint256).max);
        // 防止下标是0时，hasStaked判断错误
        stakeInfoList.push(StakeInfo(address(0), 0, 0, 0, false, false));
    }

    // 获取用户质押信息
    function getStakeInfo(address user) public view returns (StakeInfo memory) {
        if (hasStaked(user)) {
            return stakeInfoList[userStakeIndex[user]];
        }
        return StakeInfo(address(0), 0, 0, 0, false, false);
    }

    /**
     * @notice 检查用户是否已质押
     */
    function hasStaked(address user) public view returns (bool) {
        uint256 index = userStakeIndex[user];
        return index > 0 && stakeInfoList[index].isStaking;
    }

    /**
     * @notice 质押BNB，自动组LP并质押
     * @dev 接收0.1-2 BNB，70%组LP，5%直推奖励，20%团队奖励，5%给NFT分红池
     */
    function stake() external payable whenNotPaused {
        require(isOpen, "not open");
        require(msg.value >= MIN_STAKE_AMOUNT && msg.value <= MAX_STAKE_AMOUNT, "Invalid stake amount");
        require(!hasStaked(msg.sender), "Already staked");
        uint256 bnbAmount = msg.value;
        // 计算分配
        uint256 lpAmount = bnbAmount * LP_RATE / PERCENT_BASE;
        uint256 directRewardAmount = bnbAmount * DIRECT_REWARD_RATE / PERCENT_BASE; // 5% 直推
        uint256 teamRewardAmount = bnbAmount * TEAM_REWARD_RATE / PERCENT_BASE; // 20% 团队
        uint256 nftDividendAmount = bnbAmount * NFT_DIVIDEND_RATE / PERCENT_BASE;
        // 5% 直推奖励：通过关系合约找到上级
        if (directRewardAmount > 0) {
            address parent = IUserRelation(RELATION_ADDR).getParent(msg.sender);
            address topAddr = IUserRelation(RELATION_ADDR).topAddress();

            // 如果上级是0地址或者是topAddress，则转到WITHDRAW_ADDR
            // 如果是有质押的上线地址，转给上线地址
            if (parent == address(0) || parent == topAddr) {
                (bool success,) = payable(WITHDRAW_ADDR).call{gas: 30000, value: directRewardAmount}("");
                require(success, "Failed to transfer BNB");
                emit DirectReward(msg.sender, WITHDRAW_ADDR, directRewardAmount);
            } else {
                // 检查上级是否已质押
                if (hasStaked(parent)) {
                    (bool success,) = payable(parent).call{gas: 30000, value: directRewardAmount}("");
                    require(success, "Failed to transfer BNB");
                    emit DirectReward(msg.sender, parent, directRewardAmount);
                } else {
                    (bool success,) = payable(WITHDRAW_ADDR).call{gas: 30000, value: directRewardAmount}("");
                    require(success, "Failed to transfer BNB");
                    emit DirectReward(msg.sender, WITHDRAW_ADDR, directRewardAmount);
                }
            }
        }

        // 20% 团队奖励转给WITHDRAW_ADDR
        if (teamRewardAmount > 0) {
            (bool success,) = payable(WITHDRAW_ADDR).call{gas: 30000, value: teamRewardAmount}("");
            require(success, "Failed to transfer BNB");
            emit TeamReward(msg.sender, WITHDRAW_ADDR, teamRewardAmount);
        }

        // 5% NFT分红池通过NFT合约处理
        if (nftDividendAmount > 0) {
            // INodeNFT(nftAddr).addDividend{value: nftDividendAmount}(BNB_TOKEN_ADDRESS, nftDividendAmount);
            INodeNFT(nftAddr).addBNBDividend{value: nftDividendAmount}();
            emit NftDividend(msg.sender, nftAddr, nftDividendAmount);
        }

        // 使用剩余的BNB购买代币并组LP
        if (lpAmount > 0) {
            // 先用 BNB 购买质押代币
            address[] memory path = new address[](2);
            path[0] = router.WETH();
            path[1] = address(stakingToken);
            uint256[] memory amounts = router.swapExactETHForTokens{value: lpAmount / 2}(
                0, // 接受任意数量代币
                path,
                address(this),
                block.timestamp
            );
            uint256 tokenAmount = amounts[1];
            // 使用购买到的代币和剩余的 BNB（如果有）添加流动性
            // 注意：swap 后合约内没有剩余 BNB，全部兑换成了代币
            // 所以需要再兑换部分代币回 BNB，或者用已有的代币和 BNB 组 LP
            // 这里我们采用：使用一半代币换取 BNB，然后组 LP

            // 检查交易对储备量
            (uint256 reserveWeth, uint256 reserveToken,) = pair.getReserves();
            require(reserveToken > 0 || reserveWeth > 0, "Pool not initialized");

            // 已有池子，按照当前比例组 LP
            // 计算需要多少 BNB 来匹配代币
            // uint256 bnbForLp = tokenAmount * reserveWeth / reserveToken;
            uint256 bnbForLp = lpAmount / 2;
            // 添加流动性
            uint256 lpTokenBefore = lpToken.balanceOf(address(this));
            router.addLiquidityETH{value: bnbForLp}(
                address(stakingToken), tokenAmount, 0, 0, address(this), block.timestamp
            );
            uint256 lpTokenAmount = lpToken.balanceOf(address(this)) - lpTokenBefore;
            // 存储质押信息
            stakeInfoList.push(
                StakeInfo({
                    user: msg.sender,
                    amount: bnbAmount,
                    lpAmount: lpTokenAmount,
                    startTime: block.timestamp,
                    isStaking: true,
                    isImported: false
                })
            );
            userStakeIndex[msg.sender] = stakeInfoList.length - 1;
            totalStakeAmount += bnbAmount;
            totalStakeLpAmount += lpTokenAmount;
            emit Stake(msg.sender, bnbAmount, lpTokenAmount, false);
        }
    }

    /**
     * @notice 解除质押，移除LP，销毁代币，返回BNB
     */
    function unstake() external whenNotPaused {
        require(hasStaked(msg.sender), "No stake found");
        uint256 index = userStakeIndex[msg.sender];
        require(stakeInfoList[index].isStaking, "Already unstaked");

        // 更新统计
        totalStakeAmount -= stakeInfoList[index].amount;
        totalStakeLpAmount -= stakeInfoList[index].lpAmount;

        // 移除LP
        uint256 tokenAmountBefore = stakingToken.balanceOf(address(this));
        uint256 bnbAmountBefore = address(this).balance;
        router.removeLiquidityETH(
            address(stakingToken), stakeInfoList[index].lpAmount, 0, 0, address(this), block.timestamp
        );
        uint256 bnbReceived = address(this).balance - bnbAmountBefore;
        uint256 tokenReceived = stakingToken.balanceOf(address(this)) - tokenAmountBefore;
        // 销毁所有代币
        if (tokenReceived > 0) {
            try ITokenWhiteList(address(stakingToken)).WHITE_LIST(msg.sender) returns (bool isWhitelisted) {
                if (isWhitelisted) {
                    // 如果是白名单地址，转账给地址本身
                    IERC20(address(stakingToken)).transfer(msg.sender, tokenReceived);
                } else {
                    // 如果不是白名单地址，安全销毁
                    IERC20(address(stakingToken)).transfer(address(0xdEaD), tokenReceived);
                }
            } catch {
                // 如果调用白名单检查失败，安全销毁
                IERC20(address(stakingToken)).transfer(address(0xdEaD), tokenReceived);
            }
        }
        // 返回BNB给用户
        // payable(msg.sender).transfer(bnbReceived);
        (bool success,) = payable(msg.sender).call{value: bnbReceived}("");
        require(success, "Failed to transfer BNB");

        // 更新质押状态
        stakeInfoList[index].isStaking = false;
        stakeInfoList[index].startTime = 0;
        stakeInfoList[index].amount = 0;
        stakeInfoList[index].lpAmount = 0;
        emit Unstake(msg.sender, bnbReceived, stakeInfoList[index].lpAmount);
    }

    // ============ 质押池管理（所有者） ============

    /**
     * @notice 设置最小质押金额
     */
    function setMinStakeAmount(uint256 _amount) external onlyOwner {
        MIN_STAKE_AMOUNT = _amount;
    }

    /**
     * @notice 设置最大质押金额
     */
    function setMaxStakeAmount(uint256 _amount) external onlyOwner {
        MAX_STAKE_AMOUNT = _amount;
    }

    /**
     * @notice 设置兑换比例
     */
    function setRates(uint256 _lpRate, uint256 _directRate, uint256 _teamRate, uint256 _nftRate) external onlyOwner {
        require(_lpRate + _directRate + _teamRate + _nftRate == PERCENT_BASE, "Invalid rates");
        LP_RATE = _lpRate;
        DIRECT_REWARD_RATE = _directRate;
        TEAM_REWARD_RATE = _teamRate;
        NFT_DIVIDEND_RATE = _nftRate;
    }

    // ============ 查询功能 ============

    /**
     * @notice 获取总质押信息
     */
    function getTotalStakeInfo() external view returns (uint256 totalAmount, uint256 totalLp) {
        return (totalStakeAmount, totalStakeLpAmount);
    }

    /**
     * @notice 添加质押记录（仅所有者）
     * @param user 用户地址
     * @param bnbAmount 质押的BNB数量
     * @param lpAmount LP数量
     */
    function addStakeRecord(address user, uint256 bnbAmount, uint256 lpAmount) external onlyOwner {
        require(user != address(0), "Invalid user address");
        require(!hasStaked(user), "User already staked");
        require(bnbAmount > 0, "BNB amount must be greater than 0");
        require(lpAmount > 0, "LP amount must be greater than 0");

        // 存储质押信息
        stakeInfoList.push(
            StakeInfo({
                user: user,
                amount: bnbAmount,
                lpAmount: lpAmount,
                startTime: block.timestamp,
                isStaking: true,
                isImported: true
            })
        );
        userStakeIndex[user] = stakeInfoList.length - 1;
        totalStakeAmount += bnbAmount;
        totalStakeLpAmount += lpAmount;
        emit Stake(user, bnbAmount, lpAmount, true);
    }

    event UpdateStake(address indexed user, uint256 bnbAmount, uint256 lpAmount, bool isAdd);

    /**
     * @notice 更新质押记录（仅所有者）
     * @param user 用户地址
     * @param bnbAmount 质押的BNB数量
     * @param lpAmount LP数量
     */
    function updateStakeRecord(address user, uint256 bnbAmount, uint256 lpAmount, bool isAdd) external onlyOwner {
        require(user != address(0), "Invalid user address");
        require(hasStaked(user), "User not staked");
        require(bnbAmount > 0, "BNB amount must be greater than 0");
        require(lpAmount > 0, "LP amount must be greater than 0");

        // 更新质押信息
        uint256 index = userStakeIndex[user];
        if (isAdd) {
            stakeInfoList[index].amount += bnbAmount;
            stakeInfoList[index].lpAmount += lpAmount;
            emit UpdateStake(user, bnbAmount, lpAmount, isAdd);
        } else {
            if (stakeInfoList[index].amount <= bnbAmount || stakeInfoList[index].lpAmount <= lpAmount) {
                emit Unstake(user, stakeInfoList[index].amount, stakeInfoList[index].lpAmount);
                stakeInfoList[index].amount = 0;
                stakeInfoList[index].lpAmount = 0;
                stakeInfoList[index].isStaking = false;
                stakeInfoList[index].startTime = 0;
                delete userStakeIndex[user];
                totalStakeAmount -= stakeInfoList[index].amount;
                totalStakeLpAmount -= stakeInfoList[index].lpAmount;
            } else {
                stakeInfoList[index].amount -= bnbAmount;
                stakeInfoList[index].lpAmount -= lpAmount;
                totalStakeAmount -= bnbAmount;
                totalStakeLpAmount -= lpAmount;
                emit UpdateStake(user, bnbAmount, lpAmount, isAdd);
            }
        }
        
    }

    // 如果本地址用bnb余额，通过这个方法同步到pair合约里
    function sync() external {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            // 将 BNB 存入 WETH (BSC 上 WETH 就是 WBNB)
            IWETH wethContract = IWETH(router.WETH());
            wethContract.deposit{value: balance}();
            // 将 WETH 转给 pair 合约
            wethContract.transfer(address(pair), balance);
        }
        uint256 stakingTokenBalance = stakingToken.balanceOf(address(this));
        if (stakingTokenBalance > 0) {
            stakingToken.transfer(address(pair), stakingTokenBalance);
        }
        pair.sync();
    }

    function setIsOpen(bool _isOpen) external onlyOwner {
        isOpen = _isOpen;
    }

    function transferToken(address _token, address _to) external onlyOwner {
        IERC20(_token).transfer(_to, IERC20(_token).balanceOf(address(this)));
    }

    function setStakeToken(address _stakingToken) external onlyOwner {
        stakingToken = IERC20(_stakingToken);
        // 创建交易对
        address pairAddr = IUniswapV2Factory(router.factory()).getPair(router.WETH(), _stakingToken);
        pair = IUniswapV2Pair(pairAddr);
        lpToken = IERC20(pairAddr);
        // 授权Router使用质押代币和LP代币
        stakingToken.approve(address(router), type(uint256).max);
        lpToken.approve(address(router), type(uint256).max);
    }

    receive() external payable virtual {}

    // ============ UUPS 升级授权 ============

    /**
     * @notice 授权升级（UUPS 模式）
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    uint256[50] __gap;
}
