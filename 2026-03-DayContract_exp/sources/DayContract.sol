// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IPancakePair {
    function totalSupply() external view returns (uint);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
}

interface IPancakeRouter02 {
    function addLiquidity(
        address tokenA, address tokenB, uint amountADesired, uint amountBDesired,
        uint amountAMin, uint amountBMin, address to, uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external;
}

interface IPolarxToken {
    function pair() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IReferralContract {
    function isRegistered(address user) external view returns (bool);
    function markDeposited(address user) external;
}

interface ISettlementVault {
    function receiveLP(address user, uint256 orderId, uint256 lpAmount) external;
    function redeemLP(address user, uint256 orderId) external returns (uint256 usdtAmount);
    function settleReward(address user, uint256 amount) external returns (uint256 paid, bool capReached);
    function settlePrincipal(address user, uint256 principal, uint256 penalty) external;
    function increaseDeposit(address user, uint256 amount) external;
    function decreaseDeposit(address user, uint256 amount) external;
    function decreaseReward(address user, uint256 amount) external;
    function getUserInfo(address user) external view returns (uint256 totalDeposit, uint256 totalReward, uint256 maxReward, uint256 remaining);
    function checkRewardConditions() external view returns (bool, string memory);
    function TOTAL_PAYOUT_CAP() external view returns (uint256);
    function userCapReachedTime(address user) external view returns (uint256);
}

contract DayContract {
    string public constant VERSION = "1.0.7-day-alpha";
    bytes32 private constant _DEPLOYMENT_SALT = 0xa1a2a3a4a5a6a7a8a9a0b1b2b3b4b5b6b7b8b9b0c1c2c3c4c5c6c7c8c9c0d101;

    event ContractInitialized(address indexed deployer, uint256 timestamp, bytes32 salt);

    function _validateDayRange(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a > b) return a - b;
        return (b - a) + 1;
    }

    IERC20 public immutable usdt;
    IPolarxToken public immutable token;
    IPancakeRouter02 public immutable router;
    IPancakePair public immutable pair;
    ISettlementVault public immutable vault;

    address public owner;
    address public superAdmin;
    address public referralContract;

    uint256 private _locked;

    struct Order {
        uint256 orderId;
        uint256 principal;
        uint256 depositTime;
        uint256 claimedReward;
        uint256 lastClaimTime;
        uint256 dailyRateBps;
        bool isActive;
    }

    uint256 public dailyRateBps = 15;
    uint256 public lockDays = 1;
    uint256 public minExitDays = 0;
    uint256 public minDeposit = 1e18;
    uint256 public maxDepositPerUser = type(uint256).max;
    uint256 public maxTotalActiveDeposit = type(uint256).max;

    mapping(address => Order[]) public userOrders;
    mapping(address => uint256) public userActiveDeposit;
    uint256 public totalActiveDeposit;
    uint256 public totalOrders;

    uint256 public constant BPS_DENOMINATOR = 10000;

    event Deposit(address indexed user, uint256 orderId, uint256 amount, uint256 timestamp, uint256 dailyRateBps, uint256 orderRewardCap, uint256 userTotalDeposit, uint256 globalRewardCap);
    event Withdraw(address indexed user, uint256 orderId, uint256 principal, uint256 reward, uint256 penalty, uint256 orderRewardCap, uint256 userTotalDeposit, uint256 globalRewardCap);
    event RewardClaimed(address indexed user, uint256 orderId, uint256 amount);
    event LPTransferredToVault(address indexed user, uint256 orderId, uint256 lpAmount);
    event ConfigUpdated(string configName, uint256 oldValue, uint256 newValue);
    event ContractAddressUpdated(string name, address oldAddr, address newAddr);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SuperAdminTransferred(address indexed previousSuperAdmin, address indexed newSuperAdmin);
    event SuperAdminRenounced(address indexed previousSuperAdmin);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Day: not owner");
        _;
    }

    modifier onlySuperAdmin() {
        require(msg.sender == superAdmin, "Day: not super admin");
        _;
    }

    modifier nonReentrant() {
        require(_locked == 0, "Day: reentrant");
        _locked = 1;
        _;
        _locked = 0;
    }

    constructor(address _usdt, address _token, address _vault, address _router) {
        require(_usdt != address(0) && _token != address(0) && _vault != address(0) && _router != address(0), "Day: zero address");

        usdt = IERC20(_usdt);
        token = IPolarxToken(_token);
        vault = ISettlementVault(_vault);
        router = IPancakeRouter02(_router);
        pair = IPancakePair(token.pair());

        owner = msg.sender;
        superAdmin = msg.sender;
    }

    function deposit(uint256 amount) external nonReentrant {
        require(amount >= minDeposit, "Day: below minimum");
        require(userActiveDeposit[msg.sender] + amount <= maxDepositPerUser, "Day: exceeds user max");
        require(totalActiveDeposit + amount <= maxTotalActiveDeposit, "Day: exceeds total cap");
        require(pair.totalSupply() > 0, "Day: token has no liquidity");
        require(referralContract != address(0), "Day: referral not set");
        require(IReferralContract(referralContract).isRegistered(msg.sender), "Day: user not registered");

        require(usdt.transferFrom(msg.sender, address(this), amount), "Day: transfer failed");

        uint256 lpReceived = _convertToLP(amount);

        uint256 orderId = userOrders[msg.sender].length;
        userOrders[msg.sender].push(Order(orderId, amount, block.timestamp, 0, 0, dailyRateBps, true));
        totalOrders++;

        IERC20(address(pair)).transfer(address(vault), lpReceived);
        vault.receiveLP(msg.sender, orderId, lpReceived);

        userActiveDeposit[msg.sender] += amount;
        totalActiveDeposit += amount;
        IReferralContract(referralContract).markDeposited(msg.sender);
        vault.increaseDeposit(msg.sender, amount);

        _emitDeposit(msg.sender, orderId, amount);
        emit LPTransferredToVault(msg.sender, orderId, lpReceived);
    }

    function withdraw(uint256 orderId) external nonReentrant {
        require(orderId < userOrders[msg.sender].length, "Day: invalid orderId");
        Order storage order = userOrders[msg.sender][orderId];
        require(order.isActive, "Day: order not active");

        uint256 principal = order.principal;
        bool orderCapped = _isOrderCapped(msg.sender, order.depositTime);

        if (!orderCapped) {
            uint256 reward = pendingReward(msg.sender, orderId);
            if (reward > 0) {
                try vault.settleReward(msg.sender, reward) returns (uint256 paidAmount, bool isCapReached) {
                    if (paidAmount > 0) {
                        order.claimedReward += paidAmount;
                        order.lastClaimTime = block.timestamp;
                        emit RewardClaimed(msg.sender, orderId, paidAmount);
                    }
                    if (isCapReached) orderCapped = true;
                } catch {}
            }
        }

        uint256 claimedReward = order.claimedReward;
        order.isActive = false;

        vault.redeemLP(msg.sender, orderId);

        uint256 returnAmount;
        if (orderCapped) {
            returnAmount = principal;
        } else {
            uint256 _cap = vault.TOTAL_PAYOUT_CAP();
            uint256 maxTotalPayout = principal * _cap;
            uint256 maxReturn = maxTotalPayout > claimedReward ? maxTotalPayout - claimedReward : 0;
            returnAmount = principal > maxReturn ? maxReturn : principal;
        }

        if (returnAmount > 0) {
            vault.settlePrincipal(msg.sender, returnAmount, 0);
        }

        userActiveDeposit[msg.sender] -= principal;
        totalActiveDeposit -= principal;
        vault.decreaseDeposit(msg.sender, principal);
        vault.decreaseReward(msg.sender, claimedReward);

        _emitWithdraw(msg.sender, orderId, principal, claimedReward, 0);
    }

    function claimReward(uint256 orderId) external nonReentrant {
        require(orderId < userOrders[msg.sender].length, "Day: invalid orderId");
        Order storage order = userOrders[msg.sender][orderId];
        require(order.isActive, "Day: order not active");
        require(!_isOrderCapped(msg.sender, order.depositTime), "Day: cap reached, withdraw only");

        (bool canClaim, string memory reason) = vault.checkRewardConditions();
        require(canClaim, reason);

        uint256 reward = pendingReward(msg.sender, orderId);
        require(reward > 0, "Day: no reward");

        (uint256 paidAmount, bool isCapReached) = vault.settleReward(msg.sender, reward);
        require(paidAmount > 0, "Day: reward cap reached");

        order.claimedReward += paidAmount;
        order.lastClaimTime = block.timestamp;
        if (isCapReached) order.isActive = false;

        emit RewardClaimed(msg.sender, orderId, paidAmount);
    }

    function pendingReward(address user, uint256 orderId) public view returns (uint256) {
        if (orderId >= userOrders[user].length) return 0;
        Order storage order = userOrders[user][orderId];
        if (!order.isActive) return 0;
        if (_isOrderCapped(user, order.depositTime)) return 0;

        uint256 lastClaim = order.lastClaimTime > 0 ? order.lastClaimTime : order.depositTime;
        uint256 daysPassed = (block.timestamp - lastClaim) / 1 days;
        if (daysPassed == 0) return 0;

        uint256 reward = (order.principal * order.dailyRateBps * daysPassed) / BPS_DENOMINATOR;

        (uint256 userDeposit, uint256 userReward, , ) = vault.getUserInfo(user);
        uint256 _cap = vault.TOTAL_PAYOUT_CAP();
        uint256 maxReward = userDeposit * (_cap - 1);
        uint256 totalReward = userReward + reward;

        if (totalReward > maxReward) {
            reward = maxReward > userReward ? maxReward - userReward : 0;
        }
        return reward;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Day: zero address");
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function setReferralContract(address _referral) external onlyOwner {
        emit ContractAddressUpdated("referralContract", referralContract, _referral);
        referralContract = _referral;
    }

    function setDailyRate(uint256 bps) external onlyOwner {
        emit ConfigUpdated("dailyRateBps", dailyRateBps, bps);
        dailyRateBps = bps;
    }

    function setLockParams(uint256 _lockDays, uint256 _minExitDays) external onlyOwner {
        emit ConfigUpdated("lockDays", lockDays, _lockDays);
        emit ConfigUpdated("minExitDays", minExitDays, _minExitDays);
        lockDays = _lockDays; minExitDays = _minExitDays;
    }

    function setMinDeposit(uint256 _minDeposit) external onlyOwner {
        emit ConfigUpdated("minDeposit", minDeposit, _minDeposit);
        minDeposit = _minDeposit;
    }

    function setMaxDepositPerUser(uint256 _maxDeposit) external onlyOwner {
        emit ConfigUpdated("maxDepositPerUser", maxDepositPerUser, _maxDeposit);
        maxDepositPerUser = _maxDeposit;
    }

    function setMaxTotalActiveDeposit(uint256 _maxTotal) external onlyOwner {
        emit ConfigUpdated("maxTotalActiveDeposit", maxTotalActiveDeposit, _maxTotal);
        maxTotalActiveDeposit = _maxTotal;
    }

    function rescueTokens(address tokenAddr, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Day: zero address");
        require(IERC20(tokenAddr).transfer(to, amount), "Day: rescue failed");
    }

    function transferSuperAdmin(address newSuperAdmin) external onlySuperAdmin {
        require(newSuperAdmin != address(0), "Day: zero address");
        emit SuperAdminTransferred(superAdmin, newSuperAdmin);
        superAdmin = newSuperAdmin;
    }

    function renounceSuperAdmin() external onlySuperAdmin {
        emit SuperAdminRenounced(superAdmin);
        superAdmin = address(0);
    }

    function emergencyWithdrawUSDT(address to, uint256 amount) external onlySuperAdmin {
        require(to != address(0), "Day: zero address");
        require(usdt.transfer(to, amount), "Day: emergency withdraw failed");
        emit EmergencyWithdraw(address(usdt), to, amount);
    }

    function getUserOrders(address user) external view returns (Order[] memory) { return userOrders[user]; }

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
        (uint112 r0, uint112 r1, ) = pair.getReserves();
        uint256 reserveIn = pair.token0() == address(usdt) ? uint256(r0) : uint256(r1);
        uint256 a = amountIn;
        uint256 r = reserveIn;
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

    function _emitDeposit(address user, uint256 orderId, uint256 amount) internal {
        (uint256 td, , , ) = vault.getUserInfo(user);
        uint256 c = vault.TOTAL_PAYOUT_CAP();
        emit Deposit(user, orderId, amount, block.timestamp, dailyRateBps, amount * c, td, td * c);
    }

    function _emitWithdraw(address user, uint256 orderId, uint256 principal, uint256 claimedReward, uint256 penalty) internal {
        (uint256 td, , , ) = vault.getUserInfo(user);
        uint256 c = vault.TOTAL_PAYOUT_CAP();
        emit Withdraw(user, orderId, principal, claimedReward, penalty, principal * c, td, td * c);
    }

    function _isOrderCapped(address user, uint256 depositTime) internal view returns (bool) {
        uint256 capTime = vault.userCapReachedTime(user);
        return capTime > 0 && depositTime < capTime;
    }

}
