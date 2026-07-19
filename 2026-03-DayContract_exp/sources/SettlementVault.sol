// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface IPancakePair {
    function totalSupply() external view returns (uint) ;
    function balanceOf(address owner) external view returns (uint);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
}

interface IPancakeRouter02 {
    function addLiquidity(
        address tokenA, address tokenB, uint amountADesired, uint amountBDesired,
        uint amountAMin, uint amountBMin, address to, uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
    function removeLiquidity(
        address tokenA, address tokenB, uint liquidity, uint amountAMin, uint amountBMin,
        address to, uint deadline
    ) external returns (uint amountA, uint amountB);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external;
}

interface IPolarxToken {
    function pair() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function getPoolMarketValue() external view returns (uint256);
    function getMonthContractLPValue() external view returns (uint256);
    function checkGrowthThreshold() external view returns (bool canClaim, uint256 currentValue, uint256 requiredValue);
}

interface IReferralContract {
    function accrueReferralRewards(address user, uint256 rewardAmount) external;
}

interface ILevelSystem {
    function addToDividendPool(uint256 totalStaticReward) external;
}

contract SettlementVault {
    string public constant VERSION = "5.3.2-vault-prod";
    bytes32 private constant _DEPLOYMENT_SALT = 0xe5e6e7e8e9f0a1a2b3b4c5c6d7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4cc05;

    event VaultActivated(address indexed guardian, uint256 capacity, bytes32 vaultId);

    function _validateSettlementBounds(uint256 amount, uint256 cap) internal pure returns (bool) {
        return amount <= cap && cap > 0 && amount > 0;
    }

    IERC20 public immutable usdt;
    IPolarxToken public immutable token;
    IPancakeRouter02 public immutable router;
    IPancakePair public immutable pair;

    address public owner;
    address public superAdmin;

    address public referralContract;
    address public levelSystem;
    address public quarterContract;
    address public nodeTokenContract;

    mapping(address => bool) public authorizedContracts;

    uint256 private _locked;

    bool public paused;

    mapping(address => uint256) public userTotalDeposit;
    mapping(address => uint256) public userTotalReward;

    mapping(address => mapping(address => mapping(uint256 => uint256))) public contractLPs;

    uint256 public TOTAL_PAYOUT_CAP = 3;

    uint256 public totalRewardPaid;
    mapping(address => uint256) public userCapReachedTime;

    uint256 public dailyGlobalLimit;
    uint256 public todayClaimedTotal;
    uint256 public lastResetDay;
    int256 private constant TIMEZONE_OFFSET = 8 hours;

    uint256 public lpValueThreshold = 0;

    uint256 public globalMaxDepositPerUser = type(uint256).max;

    uint16 public depositSelfBps = 9000;
    uint16 public depositQuarterBps = 750;
    uint16 public depositNodeBps = 250;

    uint16 public penaltySelfBps = 9000;
    uint16 public penaltyQuarterBps = 750;
    uint16 public penaltyNodeBps = 250;

    uint256 public constant BPS_DENOMINATOR = 10000;

    event DepositRecorded(address indexed user, uint256 amount, uint256 newTotalDeposit);
    event DepositDistributed(uint256 toSelf, uint256 toQuarter, uint256 toNode);
    event RewardSettled(address indexed user, uint256 requested, uint256 paid, bool capReached);
    event PrincipalSettled(address indexed user, uint256 principal, uint256 penalty, uint256 returned);
    event PenaltyDistributed(uint256 toSelf, uint256 toQuarter, uint256 toNode);
    event LPConverted(address indexed fromContract, address indexed user, uint256 orderId, uint256 usdtAmount, uint256 lpAmount);
    event LPReceived(address indexed fromContract, address indexed user, uint256 orderId, uint256 lpAmount);
    event LPRedeemed(address indexed fromContract, address indexed user, uint256 orderId, uint256 usdtAmount);
    event ConfigUpdated(string configName, uint256 oldValue, uint256 newValue);
    event ContractAddressUpdated(string name, address oldAddr, address newAddr);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SuperAdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event SuperAdminRenounced(address indexed previousAdmin);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);
    event DepositIncreased(address indexed user, uint256 amount, uint256 newTotal);
    event DepositDecreased(address indexed user, uint256 amount, uint256 newTotal);
    event RewardDecreased(address indexed user, uint256 amount, uint256 newTotal);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event ExternalCallFailed(string target, address contractAddr, bytes reason);
    event UserCapReached(address indexed user, uint256 totalDeposit, uint256 totalReward);

    modifier onlyOwner() {
        require(msg.sender == owner, "Vault: not owner");
        _;
    }

    modifier onlySuperAdmin() {
        require(msg.sender == superAdmin, "Vault: not super admin");
        _;
    }

    modifier onlyAuthorized() {
        require(authorizedContracts[msg.sender] || msg.sender == owner, "Vault: not authorized");
        _;
    }

    modifier nonReentrant() {
        require(_locked == 0, "Vault: reentrant");
        _locked = 1;
        _;
        _locked = 0;
    }

    modifier whenNotPaused() {
        require(!paused, "Vault: paused");
        _;
    }

    constructor(address _usdt, address _token, address _router) {
        require(_usdt != address(0) && _token != address(0) && _router != address(0), "Vault: zero address");

        usdt = IERC20(_usdt);
        token = IPolarxToken(_token);
        router = IPancakeRouter02(_router);
        pair = IPancakePair(token.pair());

        owner = msg.sender;
        superAdmin = msg.sender;
        lastResetDay = _getCurrentDay();
    }

    function processDeposit(address user, uint256 totalAmount) external onlyAuthorized whenNotPaused nonReentrant returns (uint256 toSelf) {
        require(totalAmount > 0, "Vault: zero amount");
        require(quarterContract != address(0) && nodeTokenContract != address(0), "Vault: contracts not set");

        uint256 balanceBefore = usdt.balanceOf(address(this));
        require(usdt.transferFrom(msg.sender, address(this), totalAmount), "Vault: USDT transferFrom caller failed");
        require(usdt.balanceOf(address(this)) >= balanceBefore + totalAmount, "Vault: received USDT less than expected, check fee-on-transfer");

        uint256 toQuarter = (totalAmount * depositQuarterBps) / BPS_DENOMINATOR;
        uint256 toNode = (totalAmount * depositNodeBps) / BPS_DENOMINATOR;
        toSelf = totalAmount - toQuarter - toNode;

        if (toQuarter > 0) require(usdt.transfer(quarterContract, toQuarter), "Vault: USDT transfer to quarterContract failed");
        if (toNode > 0) require(usdt.transfer(nodeTokenContract, toNode), "Vault: USDT transfer to nodeToken failed");

        userTotalDeposit[user] += totalAmount;

        emit DepositRecorded(user, totalAmount, userTotalDeposit[user]);
        emit DepositDistributed(toSelf, toQuarter, toNode);

        return toSelf;
    }

    function convertAndStoreLP(
        address fromContract, address user, uint256 orderId, uint256 usdtAmount
    ) external onlyAuthorized whenNotPaused returns (uint256 lpReceived) {
        require(usdtAmount > 0, "Vault: zero amount");

        lpReceived = _convertToLP(usdtAmount);
        contractLPs[fromContract][user][orderId] = lpReceived;

        emit LPConverted(fromContract, user, orderId, usdtAmount, lpReceived);
    }

    function receiveLP(address user, uint256 orderId, uint256 lpAmount) external onlyAuthorized {
        contractLPs[msg.sender][user][orderId] = lpAmount;
        emit LPReceived(msg.sender, user, orderId, lpAmount);
    }

    function redeemLP(address user, uint256 orderId) external onlyAuthorized returns (uint256 usdtAmount) {
        uint256 lpAmount = contractLPs[msg.sender][user][orderId];
        require(lpAmount > 0, "Vault: no LP");
        contractLPs[msg.sender][user][orderId] = 0;

        uint256 actualLP = IERC20(address(pair)).balanceOf(address(this));
        if (lpAmount > actualLP) {
            lpAmount = actualLP;
        }
        if (lpAmount > 0) {
            usdtAmount = _redeemLPToUSDT(lpAmount);
        }
        emit LPRedeemed(msg.sender, user, orderId, usdtAmount);
    }

    function redeemLPFrom(address fromContract, address user, uint256 orderId) external onlyAuthorized returns (uint256 usdtAmount) {
        uint256 lpAmount = contractLPs[fromContract][user][orderId];
        require(lpAmount > 0, "Vault: no LP");
        contractLPs[fromContract][user][orderId] = 0;

        uint256 actualLP = IERC20(address(pair)).balanceOf(address(this));
        if (lpAmount > actualLP) {
            lpAmount = actualLP;
        }
        if (lpAmount > 0) {
            usdtAmount = _redeemLPToUSDT(lpAmount);
        }
        emit LPRedeemed(fromContract, user, orderId, usdtAmount);
    }

    function settleReward(address user, uint256 amount)
        external onlyAuthorized whenNotPaused nonReentrant
        returns (uint256 paid, bool capReached)
    {
        require(amount > 0, "Vault: zero amount");

        uint256 actualAmount = _checkAndDeductDailyLimit(amount);
        require(actualAmount > 0, "Vault: daily limit reached");

        uint256 maxReward = userTotalDeposit[user] * (TOTAL_PAYOUT_CAP - 1);
        uint256 currentTotal = userTotalReward[user];

        if (currentTotal >= maxReward) return (0, true);

        uint256 availableReward = maxReward - currentTotal;
        paid = actualAmount > availableReward ? availableReward : actualAmount;
        capReached = (currentTotal + paid) >= maxReward;

        userTotalReward[user] += paid;
        totalRewardPaid += paid;

        _ensureUSDTBalance(paid);
        require(usdt.transfer(user, paid), "Vault: transfer failed");

        _accrueReferralRewards(user, paid);

        _addToDividendPool(paid);

        emit RewardSettled(user, amount, paid, capReached);

        if (capReached) {
            userCapReachedTime[user] = block.timestamp;
            emit UserCapReached(user, userTotalDeposit[user], userTotalReward[user]);
        }
    }

    function settleRewardOnly(address user, uint256 amount)
        external onlyAuthorized whenNotPaused nonReentrant
        returns (uint256 paid, bool capReached)
    {
        require(amount > 0, "Vault: zero amount");

        uint256 maxReward = userTotalDeposit[user] * (TOTAL_PAYOUT_CAP - 1);
        uint256 currentTotal = userTotalReward[user];

        if (currentTotal >= maxReward) return (0, true);

        uint256 availableReward = maxReward - currentTotal;
        paid = amount > availableReward ? availableReward : amount;
        capReached = (currentTotal + paid) >= maxReward;

        if (paid > 0) {
            userTotalReward[user] += paid;
            totalRewardPaid += paid;
            _ensureUSDTBalance(paid);
            require(usdt.transfer(user, paid), "Vault: transfer failed");
        }

        emit RewardSettled(user, amount, paid, capReached);

        if (capReached) {
            userCapReachedTime[user] = block.timestamp;
            emit UserCapReached(user, userTotalDeposit[user], userTotalReward[user]);
        }
    }

    function settlePrincipal(address user, uint256 principal, uint256 penalty)
        external onlyAuthorized whenNotPaused nonReentrant
    {
        uint256 returnAmount = principal > penalty ? principal - penalty : 0;

        _ensureUSDTBalance(principal);

        if (penalty > 0) {
            _distributePenalty(penalty);
        }

        if (returnAmount > 0) {
            require(usdt.transfer(user, returnAmount), "Vault: transfer failed");
        }

        emit PrincipalSettled(user, principal, penalty, returnAmount);
    }

    function increaseDeposit(address user, uint256 amount) external onlyAuthorized whenNotPaused {
        require(userTotalDeposit[user] + amount <= globalMaxDepositPerUser, "Vault: exceeds global user cap");
        userTotalDeposit[user] += amount;
        emit DepositIncreased(user, amount, userTotalDeposit[user]);
    }

    function decreaseDeposit(address user, uint256 amount) external onlyAuthorized whenNotPaused {
        if (userTotalDeposit[user] >= amount) {
            userTotalDeposit[user] -= amount;
        } else {
            userTotalDeposit[user] = 0;
        }
        emit DepositDecreased(user, amount, userTotalDeposit[user]);
    }

    function decreaseReward(address user, uint256 amount) external onlyAuthorized whenNotPaused {
        if (userTotalReward[user] >= amount) {
            userTotalReward[user] -= amount;
        } else {
            userTotalReward[user] = 0;
        }
        emit RewardDecreased(user, amount, userTotalReward[user]);
    }

    function checkRewardConditions() external view returns (bool, string memory) {
        uint256 lpValue = _getLPValue();
        if (lpValue < lpValueThreshold) return (false, "LP value below threshold");

        (bool canClaim, , ) = token.checkGrowthThreshold();
        if (!canClaim) return (false, "Growth threshold not met");

        return (true, "");
    }

    function getUserInfo(address user) external view returns (
        uint256 totalDeposit, uint256 totalReward, uint256 maxReward, uint256 remaining
    ) {
        totalDeposit = userTotalDeposit[user];
        totalReward = userTotalReward[user];
        maxReward = totalDeposit * (TOTAL_PAYOUT_CAP - 1);
        remaining = maxReward > totalReward ? maxReward - totalReward : 0;
    }

    function getUSDTBalance() external view returns (uint256) {
        return usdt.balanceOf(address(this));
    }

    function getLPBalance() external view returns (uint256) {
        return IERC20(address(pair)).balanceOf(address(this));
    }

    function getLPValue() external view returns (uint256) {
        return _getLPValue();
    }

    function getLPForOrder(address fromContract, address user, uint256 orderId) external view returns (uint256) {
        return contractLPs[fromContract][user][orderId];
    }

    function getTodayRemainingLimit() external view returns (uint256) {
        if (dailyGlobalLimit == 0) return type(uint256).max;
        if (_getCurrentDay() > lastResetDay) return dailyGlobalLimit;
        return dailyGlobalLimit > todayClaimedTotal ? dailyGlobalLimit - todayClaimedTotal : 0;
    }

    function getPoolStats() external view returns (
        uint256 _totalRewardPaid,
        uint256 usdtBalance,
        uint256 lpValue,
        uint256 lpBalance
    ) {
        _totalRewardPaid = totalRewardPaid;
        usdtBalance = usdt.balanceOf(address(this));
        lpBalance = IERC20(address(pair)).balanceOf(address(this));
        lpValue = _getLPValue();
    }

    function _checkAndDeductDailyLimit(uint256 amount) internal returns (uint256) {
        _resetDailyLimitIfNeeded();
        if (dailyGlobalLimit == 0) return amount;
        uint256 remaining = dailyGlobalLimit > todayClaimedTotal ? dailyGlobalLimit - todayClaimedTotal : 0;
        if (remaining == 0) return 0;
        uint256 actualAmount = amount > remaining ? remaining : amount;
        todayClaimedTotal += actualAmount;
        return actualAmount;
    }

    function _resetDailyLimitIfNeeded() internal {
        uint256 today = _getCurrentDay();
        if (today > lastResetDay) {
            todayClaimedTotal = 0;
            lastResetDay = today;
        }
    }

    function _getCurrentDay() internal view returns (uint256) {
        return (block.timestamp + uint256(TIMEZONE_OFFSET)) / 1 days;
    }

    function _ensureUSDTBalance(uint256 needed) internal {
        uint256 maxAttempts = 3;
        for (uint256 i = 0; i < maxAttempts; i++) {
            uint256 balance = usdt.balanceOf(address(this));
            if (balance >= needed) return;

            uint256 shortage = needed - balance;
            uint256 lpBalance = IERC20(address(pair)).balanceOf(address(this));
            if (lpBalance == 0) break;

            uint256 lpTotalSupply = pair.totalSupply();
            uint256 reserveUSDT = _getUSDTReserve();
            if (reserveUSDT == 0 || lpTotalSupply == 0) break;

            uint256 factor = (i == 0) ? 60 : 100;
            uint256 lpNeeded = (shortage * lpTotalSupply * factor) / (reserveUSDT * 100);
            if (lpNeeded > lpBalance) lpNeeded = lpBalance;
            if (lpNeeded == 0) break;

            _redeemLPToUSDT(lpNeeded);
        }
        require(usdt.balanceOf(address(this)) >= needed, "Vault: insufficient USDT");
    }

    function _convertToLP(uint256 usdtAmount) internal returns (uint256 lpReceived) {
        uint256 swapAmount = _getOptimalSwapAmount(usdtAmount);
        uint256 remainingUSDT = usdtAmount - swapAmount;

        usdt.approve(address(router), swapAmount);
        address[] memory path = new address[](2);
        path[0] = address(usdt);
        path[1] = address(token);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(swapAmount, 0, path, address(this), block.timestamp);

        uint256 totalToken = token.balanceOf(address(this));
        usdt.approve(address(router), remainingUSDT);
        token.approve(address(router), totalToken);

        uint256 lpBefore = IERC20(address(pair)).balanceOf(address(this));
        router.addLiquidity(address(token), address(usdt), totalToken, remainingUSDT, 0, 0, address(this), block.timestamp);
        lpReceived = IERC20(address(pair)).balanceOf(address(this)) - lpBefore;
    }

    function _getOptimalSwapAmount(uint256 amountIn) internal view returns (uint256) {
        uint256 r = _getUSDTReserve();
        uint256 a = amountIn;
        uint256 inner = r * (r * 19975 * 19975 + a * 4 * 9975 * 10000);
        return (_sqrt(inner) - r * 19975) / 19950;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
        return y;
    }

    function _redeemLPToUSDT(uint256 lpAmount) internal returns (uint256 usdtTotal) {
        IERC20(address(pair)).approve(address(router), lpAmount);

        uint256 tokenBefore = token.balanceOf(address(this));
        uint256 usdtBalBefore = usdt.balanceOf(address(this));

        try router.removeLiquidity(
            address(token), address(usdt), lpAmount, 0, 0, address(this), block.timestamp
        ) {
        } catch (bytes memory) {
            revert("Vault: LP redeem failed (insufficient LP or DEX error)");
        }

        uint256 tokenReceived = token.balanceOf(address(this)) - tokenBefore;
        usdtTotal = usdt.balanceOf(address(this)) - usdtBalBefore;

        if (tokenReceived > 0) {
            token.approve(address(router), tokenReceived);
            address[] memory path = new address[](2);
            path[0] = address(token);
            path[1] = address(usdt);
            uint256 usdtBefore = usdt.balanceOf(address(this));
            try router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                tokenReceived, 0, path, address(this), block.timestamp
            ) {
            } catch (bytes memory) {
                revert("Vault: PSTAR swap failed (DEX error)");
            }
            usdtTotal += usdt.balanceOf(address(this)) - usdtBefore;
        }
    }

    function _getUSDTReserve() internal view returns (uint256) {
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        return pair.token0() == address(usdt) ? uint256(reserve0) : uint256(reserve1);
    }

    function _getLPValue() internal view returns (uint256) {
        uint256 lpBalance = IERC20(address(pair)).balanceOf(address(this));
        if (lpBalance == 0) return 0;
        uint256 lpTotalSupply = pair.totalSupply();
        if (lpTotalSupply == 0) return 0;
        uint256 usdtReserve = _getUSDTReserve();
        return (lpBalance * usdtReserve * 2) / lpTotalSupply;
    }

    function _distributePenalty(uint256 penalty) internal {
        if (penalty == 0) return;
        uint256 toQuarter = (penalty * penaltyQuarterBps) / BPS_DENOMINATOR;
        uint256 toNode = (penalty * penaltyNodeBps) / BPS_DENOMINATOR;
        uint256 toSelf = penalty - toQuarter - toNode;

        if (toQuarter > 0 && quarterContract != address(0)) {
            require(usdt.transfer(quarterContract, toQuarter), "Vault: penalty transfer to quarterContract failed");
        }
        if (toNode > 0 && nodeTokenContract != address(0)) {
            require(usdt.transfer(nodeTokenContract, toNode), "Vault: penalty transfer to nodeToken failed");
        }

        emit PenaltyDistributed(toSelf, toQuarter, toNode);
    }

    function _accrueReferralRewards(address user, uint256 rewardAmount) internal {
        if (referralContract != address(0) && rewardAmount > 0) {
            try IReferralContract(referralContract).accrueReferralRewards(user, rewardAmount) {} catch (bytes memory reason) {
                emit ExternalCallFailed("referralContract", referralContract, reason);
            }
        }
    }

    function _addToDividendPool(uint256 rewardAmount) internal {
        if (levelSystem != address(0) && rewardAmount > 0) {
            try ILevelSystem(levelSystem).addToDividendPool(rewardAmount) {} catch (bytes memory reason) {
                emit ExternalCallFailed("levelSystem", levelSystem, reason);
            }
        }
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Vault: zero address");
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function setContractAddresses(
        address _quarter, address _nodeToken, address _referral, address _level
    ) external onlyOwner {
        emit ContractAddressUpdated("quarterContract", quarterContract, _quarter);
        emit ContractAddressUpdated("nodeTokenContract", nodeTokenContract, _nodeToken);
        emit ContractAddressUpdated("referralContract", referralContract, _referral);
        emit ContractAddressUpdated("levelSystem", levelSystem, _level);

        quarterContract = _quarter;
        nodeTokenContract = _nodeToken;
        referralContract = _referral;
        levelSystem = _level;
    }

    function setAuthorizedContract(address contractAddr, bool status) external onlyOwner {
        authorizedContracts[contractAddr] = status;
    }

    function setPayoutCap(uint256 cap) external onlyOwner {
        require(cap >= 2 && cap <= 10, "Vault: cap must be 2~10");
        emit ConfigUpdated("TOTAL_PAYOUT_CAP", TOTAL_PAYOUT_CAP, cap);
        TOTAL_PAYOUT_CAP = cap;
    }

    function setDailyGlobalLimit(uint256 limit) external onlyOwner {
        emit ConfigUpdated("dailyGlobalLimit", dailyGlobalLimit, limit);
        dailyGlobalLimit = limit;
    }

    function setLPValueThreshold(uint256 _threshold) external onlyOwner {
        emit ConfigUpdated("lpValueThreshold", lpValueThreshold, _threshold);
        lpValueThreshold = _threshold;
    }

    function setGlobalMaxDepositPerUser(uint256 _max) external onlyOwner {
        emit ConfigUpdated("globalMaxDepositPerUser", globalMaxDepositPerUser, _max);
        globalMaxDepositPerUser = _max;
    }

    function setDepositRatio(uint16 selfBps, uint16 quarterBps, uint16 nodeBps) external onlyOwner {
        require(selfBps + quarterBps + nodeBps == BPS_DENOMINATOR, "Vault: deposit ratios must total 10000");
        depositSelfBps = selfBps;
        depositQuarterBps = quarterBps;
        depositNodeBps = nodeBps;
    }

    function setPenaltyRatio(uint16 selfBps, uint16 quarterBps, uint16 nodeBps) external onlyOwner {
        require(selfBps + quarterBps + nodeBps == BPS_DENOMINATOR, "Vault: penalty ratios must total 10000");
        penaltySelfBps = selfBps;
        penaltyQuarterBps = quarterBps;
        penaltyNodeBps = nodeBps;
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function transferSuperAdmin(address newAdmin) external onlySuperAdmin {
        require(newAdmin != address(0), "Vault: zero address");
        address oldAdmin = superAdmin;
        superAdmin = newAdmin;
        emit SuperAdminTransferred(oldAdmin, newAdmin);
    }

    function renounceSuperAdmin() external onlySuperAdmin {
        address oldAdmin = superAdmin;
        superAdmin = address(0);
        emit SuperAdminRenounced(oldAdmin);
    }

    function emergencyWithdrawToken(address tokenAddress, address to, uint256 amount) external onlySuperAdmin {
        require(to != address(0), "Vault: zero address");
        require(IERC20(tokenAddress).transfer(to, amount), "Vault: transfer failed");
        emit EmergencyWithdraw(tokenAddress, to, amount);
    }

    function emergencyWithdrawAllUSDT(address to) external onlySuperAdmin {
        require(to != address(0), "Vault: zero address");
        uint256 balance = usdt.balanceOf(address(this));
        require(usdt.transfer(to, balance), "Vault: transfer failed");
        emit EmergencyWithdraw(address(usdt), to, balance);
    }

    function emergencyWithdrawAllLP(address to) external onlySuperAdmin {
        require(to != address(0), "Vault: zero address");
        uint256 balance = IERC20(address(pair)).balanceOf(address(this));
        require(IERC20(address(pair)).transfer(to, balance), "Vault: transfer failed");
        emit EmergencyWithdraw(address(pair), to, balance);
    }

    function emergencyWithdrawBNB(address payable to) external onlySuperAdmin {
        require(to != address(0), "Vault: zero address");
        uint256 balance = address(this).balance;
        (bool success, ) = to.call{value: balance}("");
        require(success, "Vault: BNB transfer failed");
        emit EmergencyWithdraw(address(0), to, balance);
    }
}
