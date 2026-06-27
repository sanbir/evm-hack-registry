// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    function getAmountsOut(uint amountIn, address[] calldata path)
        external view returns (uint[] memory amounts);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Pair {
    function totalSupply() external view returns (uint256);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function transfer(address to, uint value) external returns (bool);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

library TransferHelper {
    function safeTransfer(address token, address to, uint value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: TRANSFER_FAILED');
    }
    function safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'TransferHelper: ETH_TRANSFER_FAILED');
    }
}

contract BNBDeposit {
    IUniswapV2Router02 public constant router =
        IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    // 15代分红比例（基点，总计2600 = 26%）
    uint16[15] public GEN_RATES = [1200, 500, 200, 150, 50, 50, 50, 50, 50, 50, 50, 50, 50, 50, 50];

    address public owner;
    IERC20 public token;
    address public pair;
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955; // BSC USDT
    address public root = address(0x91cDe6D3bF520bbA51F4FEe1417fd6371982a417); // 根节点（创世上级，不参与分红）
    address public nodeWallet = address(0x0A5E65Fd046c00da137DEBaEce245877166D866A);      // 8% 节点分红
    address public feeWallet = address(0xE48914266A77aDc9b0C7fACBA826B9f0Cf0140f9);       // 4% 指定钱包
    address public fallbackWallet = address(0x91cDe6D3bF520bbA51F4FEe1417fd6371982a417);  // 上级不够时的兜底钱包

    bool public withdrawEnabled;    // LP提取开关，默认false
    uint256 public minDeposit = 0.01 ether; // 最小入金，可配置
    uint256 public maxDeposit = 0.2 ether; // 最大入金，可配置

    struct UserInfo {
        address referrer;
        uint256 directCount;
        uint256 lpAmount;
        uint256 lpValueInUSDT;       // LP金本位价值（USDT，累计）
        uint256 claimedValueInUSDT;  // 已领取Token金本位价值（USDT，累计）
        uint256 lastClaimTime;       // 上次领取时间
        bool bound;
    }

    mapping(address => UserInfo) public userInfo;
    uint256 public totalLP;
    uint256 public claimInterval = 1 days; // 领取间隔，可配置

    bool private _locked;

    event Bind(address indexed user, address indexed referrer);
    event Deposit(address indexed user, uint256 bnbAmount, uint256 lpAmount, uint256 lpValueUSDT);
    event GenBonus(address indexed from, address indexed to, uint256 generation, uint256 bnbAmount);
    event FallbackBonus(address indexed from, uint256 bnbAmount);
    event ClaimToken(address indexed user, uint256 tokenAmount, uint256 valueUSDT);
    event WithdrawLP(address indexed user, uint256 lpAmount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier nonReentrant() {
        require(!_locked, "Reentrant");
        _locked = true;
        _;
        _locked = false;
    }

    constructor() {
        owner = msg.sender;

        // 根节点自动标记为已绑定
        userInfo[root].bound = true;
    }

    // ============ Owner管理函数 ============

    function setToken(address _token) external onlyOwner {
        require(_token != address(0), "Invalid token");
        token = IERC20(_token);
        pair = IUniswapV2Factory(router.factory()).getPair(_token, router.WETH());
        require(pair != address(0), "Pair not exist");
        IERC20(_token).approve(address(router), type(uint256).max);
    }

    function setNodeWallet(address _wallet) external onlyOwner {
        nodeWallet = _wallet;
    }

    function setFeeWallet(address _wallet) external onlyOwner {
        feeWallet = _wallet;
    }

    function setFallbackWallet(address _wallet) external onlyOwner {
        fallbackWallet = _wallet;
    }

    function setRoot(address _root) external onlyOwner {
        require(_root != address(0), "Invalid root");
        root = _root;
        userInfo[_root].bound = true;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        owner = newOwner;
    }

    function setWithdrawEnabled(bool _enabled) external onlyOwner {
        withdrawEnabled = _enabled;
    }

    function setMinDeposit(uint256 _minDeposit) external onlyOwner {
        require(_minDeposit > 0, "Invalid min");
        minDeposit = _minDeposit;
    }

    function setMaxDeposit(uint256 _maxDeposit) external onlyOwner {
        require(_maxDeposit >= minDeposit, "Invalid max");
        maxDeposit = _maxDeposit;
    }

    function setClaimInterval(uint256 _interval) external onlyOwner {
        claimInterval = _interval;
    }

    function withdrawStuckToken(address _token, uint256 amount) external onlyOwner {
        TransferHelper.safeTransfer(_token, msg.sender, amount);
    }

    function withdrawStuckETH(uint256 amount) external onlyOwner {
        TransferHelper.safeTransferETH(msg.sender, amount);
    }

    // ============ 绑定推荐人 ============

    function bind(address referrer) external {
        require(!userInfo[msg.sender].bound, "Already bound");
        require(referrer != msg.sender, "Cannot refer self");
        require(referrer != address(0), "Invalid referrer");
        // referrer必须已绑定（或是根节点），保证单向树结构，杜绝循环
        require(userInfo[referrer].bound, "Referrer not bound");

        userInfo[msg.sender].referrer = referrer;
        userInfo[msg.sender].bound = true;
        // userInfo[referrer].directCount++;
        emit Bind(msg.sender, referrer);
    }

    // ============ 核心入金 ============

    function deposit() external payable nonReentrant {
        require(msg.value >= minDeposit, "Below min deposit");
        require(msg.value <= maxDeposit, "Above max deposit");
        require(msg.value % minDeposit == 0, "Must be multiple of min deposit");
        require(address(token) != address(0), "Token not set");
        _deposit(msg.sender, msg.value);
    }

    function _deposit(address user, uint256 totalBNB) internal {
        // 26% 15代分红
        uint256 genBNB = totalBNB * 2600 / 10000;
        // 8% 节点分红
        uint256 nodeBNB = totalBNB * 800 / 10000;
        // 4% 指定钱包
        uint256 feeBNB = totalBNB * 400 / 10000;

        address refer = userInfo[user].referrer;

        if (refer != address(0) && userInfo[user].lpAmount == 0) {
            userInfo[refer].directCount++;
        }

        _distributeGenBonus(user, genBNB);
        _safeTransferBNB(nodeWallet, nodeBNB);
        _safeTransferBNB(feeWallet, feeBNB);

        // 62% 添加LP
        uint256 lpBNB = totalBNB - genBNB - nodeBNB - feeBNB;
        uint256 halfBNB = lpBNB / 2;
        uint256 otherHalfBNB = lpBNB - halfBNB;

        // 用 halfBNB 买Token
        uint256 tokenBefore = token.balanceOf(address(this));
        _swapBNBForToken(halfBNB);
        uint256 tokenBought = token.balanceOf(address(this)) - tokenBefore;

        // 添加LP（setToken时已approve max给router）
        (,, uint256 liquidity) = router.addLiquidityETH{value: otherHalfBNB}(
            address(token),
            tokenBought,
            0,
            0,
            address(this),
            block.timestamp
        );

        // 记录LP
        uint256 lpValue = _getLPValueInUSDT(liquidity);
        userInfo[user].lpAmount += liquidity;
        userInfo[user].lpValueInUSDT += lpValue;
        totalLP += liquidity;

        emit Deposit(user, totalBNB, liquidity, lpValue);
    }

    // ============ 15代分红分配 ============

    function _distributeGenBonus(address user, uint256 totalGenBNB) internal {
        address current = userInfo[user].referrer;
        uint256 distributed = 0;

        for (uint256 gen = 0; gen < 15; gen++) {
            // 遇到空地址或根节点就停止（根节点不参与分红）
            if (current == address(0) || current == root) break;

            uint256 bonus = gen < 14
                ? totalGenBNB * GEN_RATES[gen] / 2600
                : totalGenBNB - distributed; // 最后一代用剩余值兜底精度

            uint256 maxGen = _getMaxGen(userInfo[current].directCount);

            if (gen < maxGen && userInfo[current].lpAmount > 0) {
                _safeTransferBNB(current, bonus);
                emit GenBonus(user, current, gen + 1, bonus);
            } else {
                _safeTransferBNB(fallbackWallet, bonus);
                emit FallbackBonus(user, bonus);
            }

            distributed += bonus;
            current = userInfo[current].referrer;
        }

        // 上级链不足15代，剩余转fallbackWallet
        if (distributed < totalGenBNB) {
            _safeTransferBNB(fallbackWallet, totalGenBNB - distributed);
            emit FallbackBonus(user, totalGenBNB - distributed);
        }
    }

    function _getMaxGen(uint256 directCount) internal pure returns (uint256) {
        if (directCount == 0) return 0;
        if (directCount <= 4) return directCount;
        return 15;
    }

    // ============ Token分红领取 ============

    function claimToken() external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        require(user.lpAmount > 0, "No LP");
        require(user.claimedValueInUSDT < user.lpValueInUSDT * 5, "Already reached 5x limit");

        // 用户需先approve，合约扣1枚Token
        uint256 oneToken = 1e18;
        token.transferFrom(msg.sender, address(this), oneToken);

        _claimToken(msg.sender);
    }

    // EST合约转入1枚token时回调
    function onTokenReceived(address user) external {
        require(!_locked, "Reentrant");
        require(msg.sender == address(token), "Only token");
        require(tx.origin == user, "Only EOA");
        require(userInfo[user].lpAmount > 0, "No LP");
        require(userInfo[user].claimedValueInUSDT < userInfo[user].lpValueInUSDT * 5, "Already reached 5x limit");
        _locked = true;
        _claimToken(user);
        _locked = false;
    }

    function _claimToken(address user) internal {
        UserInfo storage info = userInfo[user];
        require(block.timestamp >= info.lastClaimTime + claimInterval, "Claim too frequent");

        // 按LP占比计算可领取Token
        uint256 contractBalance = token.balanceOf(address(this));
        uint256 claimable = contractBalance * info.lpAmount / totalLP;
        require(claimable > 0, "Nothing to claim");

        // 计算本次领取的USDT金本位价值
        uint256 claimValueUSDT = _getTokenValueInUSDT(claimable);

        // 5倍截断
        uint256 maxValue = info.lpValueInUSDT * 5;
        if (info.claimedValueInUSDT + claimValueUSDT > maxValue) {
            uint256 remainingValue = maxValue - info.claimedValueInUSDT;
            claimable = claimable * remainingValue / claimValueUSDT;
            claimValueUSDT = remainingValue;
        }

        require(claimable > 0, "Claim too small");

        info.claimedValueInUSDT += claimValueUSDT;
        info.lastClaimTime = block.timestamp;
        token.transfer(user, claimable);

        emit ClaimToken(user, claimable, claimValueUSDT);
    }

    // ============ LP提取 ============

    function withdrawLP(uint256 amount) external nonReentrant {
        require(withdrawEnabled, "Withdraw not enabled");
        UserInfo storage user = userInfo[msg.sender];
        require(amount > 0, "Zero amount");
        require(user.lpAmount >= amount, "Insufficient LP");

        user.lpAmount -= amount;
        totalLP -= amount;

        IUniswapV2Pair(pair).transfer(msg.sender, amount);

        emit WithdrawLP(msg.sender, amount);
    }

    // ============ 内部工具函数 ============

    function _swapBNBForToken(uint256 bnbAmount) internal {
        address[] memory path = new address[](2);
        path[0] = router.WETH();
        path[1] = address(token);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: bnbAmount}(
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function _safeTransferBNB(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool success, ) = payable(to).call{value: amount}("");
        require(success, "BNB transfer failed");
    }

    /// @dev 计算LP的USDT金本位价值
    function _getLPValueInUSDT(uint256 lpAmount) internal view returns (uint256) {
        if (lpAmount == 0) return 0;
        IUniswapV2Pair _pair = IUniswapV2Pair(pair);
        uint256 lpTotalSupply = _pair.totalSupply();
        if (lpTotalSupply == 0) return 0;

        (uint112 reserve0, uint112 reserve1, ) = _pair.getReserves();
        address token0 = _pair.token0();

        uint256 bnbReserve;
        uint256 tokenReserve;
        if (token0 == router.WETH()) {
            bnbReserve = uint256(reserve0);
            tokenReserve = uint256(reserve1);
        } else {
            bnbReserve = uint256(reserve1);
            tokenReserve = uint256(reserve0);
        }

        // LP价值 = LP份额对应的BNB折算USDT + LP份额对应的Token折算USDT
        uint256 bnbShare = bnbReserve * lpAmount / lpTotalSupply;
        uint256 tokenShare = tokenReserve * lpAmount / lpTotalSupply;
        uint256 bnbShareInUSDT = _getBNBValueInUSDT(bnbShare);
        uint256 tokenShareInUSDT = _getTokenValueInUSDT(tokenShare);

        return bnbShareInUSDT + tokenShareInUSDT;
    }

    /// @dev 通过Router查询Token的USDT价值 (Token → WBNB → USDT)
    function _getTokenValueInUSDT(uint256 tokenAmount) internal view returns (uint256) {
        if (tokenAmount == 0) return 0;
        address[] memory path = new address[](3);
        path[0] = address(token);
        path[1] = router.WETH();
        path[2] = USDT;
        try router.getAmountsOut(tokenAmount, path) returns (uint[] memory amounts) {
            return amounts[2];
        } catch {
            return 0;
        }
    }

    /// @dev 通过Router查询BNB的USDT价值 (WBNB → USDT)
    function _getBNBValueInUSDT(uint256 bnbAmount) internal view returns (uint256) {
        if (bnbAmount == 0) return 0;
        address[] memory path = new address[](2);
        path[0] = router.WETH();
        path[1] = USDT;
        try router.getAmountsOut(bnbAmount, path) returns (uint[] memory amounts) {
            return amounts[1];
        } catch {
            return 0;
        }
    }

    // ============ 查询函数 ============

    /// @dev 查询用户信息
    function getUserInfo(address user) external view returns (
        address referrer,
        uint256 directCount,
        uint256 lpAmount,
        uint256 lpValueInUSDT,
        uint256 claimedValueInUSDT,
        bool bound
    ) {
        UserInfo storage info = userInfo[user];
        return (
            info.referrer,
            info.directCount,
            info.lpAmount,
            info.lpValueInUSDT,
            info.claimedValueInUSDT,
            info.bound
        );
    }

    /// @dev 查询用户还能领取多少USDT价值的Token
    function getRemainingClaimValue(address user) external view returns (uint256) {
        UserInfo storage info = userInfo[user];
        uint256 maxValue = info.lpValueInUSDT * 5;
        if (info.claimedValueInUSDT >= maxValue) return 0;
        return maxValue - info.claimedValueInUSDT;
    }

    receive() external payable {
        if (!_locked && msg.value >= minDeposit && msg.value <= maxDeposit && msg.value % minDeposit == 0 && address(token) != address(0)) {
            _locked = true;
            _deposit(msg.sender, msg.value);
            _locked = false;
        }
    }
}