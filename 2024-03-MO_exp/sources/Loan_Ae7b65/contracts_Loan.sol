// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IApproveProxy.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Router.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IToken.sol";
import "./interfaces/IPoolV2.sol";
import "./interfaces/IRelationship.sol";
import "./Vault.sol";

struct SupplyOrder {
    uint256 amount;
    uint256 duration;
    uint256 startedTime;
    uint256 expiredTime;
    uint256 rewardRate;
    uint256 claimedRewards;
    bool finished;
}

struct BorrowOrder {
    uint256 amount;
    uint256 total;
    uint256 duration;
    uint256 startedTime;
    uint256 expiredTime;
    uint256 interestRate;
    bool finished;
}

contract Loan is Vault {
    using SafeERC20 for IERC20;

    uint256 public constant BASE = 10000;
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;

    address public approveProxy;
    address public pair;
    address public router;
    address public poolV2;
    address public relationship;

    address public supplyToken;
    uint256 public supplyMinAmount = 100 * 1e6;
    uint256 public supplyMaxAmount = 20000 * 1e6;
    mapping(uint256 => uint256) public supplyRates;
    mapping(uint256 => uint256) public supplyRewardRates;
    mapping(address => SupplyOrder[]) public supplyOrders;
    mapping(address => uint256) public supplyOrdersCount;
    mapping(address => uint256) public totalSupplyOf;
    mapping(address => uint256) public totalSupplyRewardOf;
    mapping(address => uint256) public totalReferralRewardOf;

    address public borrowToken;
    uint256 public borrowMinAmount = 100 * 1e4;
    uint256 public borrowOverCollateral = 2000;
    uint256 public redeemRate = 10000;
    uint256 public burnRate = 9000;
    uint256 public inviteRewardRate = 100;
    mapping(uint256 => uint256) public borrowRates;
    mapping(address => BorrowOrder[]) public borrowOrders;
    mapping(address => uint) public borrowOrdersCount;

    uint256 public totalSupply;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(uint256 => uint256) public multiples;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public userRewardStored;

    event SupplyOrderCreated(address indexed user, uint256 amount, uint256 duration, uint256 rate, uint256 index);
    event SupplyOrderFinished(address indexed user, uint256 index);
    event BorrowOrderCreated(
        address indexed user,
        uint256 amount,
        uint256 total,
        uint256 duration,
        uint256 rate,
        uint256 index
    );
    event BorrowOrderFinished(address indexed user, uint256 index, uint256 amount, uint256 interest);
    event SupplyRewardClaimed(address indexed user, uint256 reward, uint256 index);
    event MORewardClaimed(address indexed user, uint256 reward);
    event ReferralRewardClaimed(address indexed user, uint256 reward);

    error InvalidAmount();
    error InvalidDuration();
    error InvalidIndex();
    error NotExpired();
    error Finished();

    constructor(
        address _approveProxy,
        address _pair,
        address _router,
        address _poolV2,
        address _relationship,
        address _supplyToken,
        address _borrowToken
    ) {
        approveProxy = _approveProxy;
        pair = _pair;
        router = _router;
        poolV2 = _poolV2;
        relationship = _relationship;

        supplyToken = _supplyToken;
        borrowToken = _borrowToken;

        supplyRates[0] = 10;
        supplyRates[7] = 150;
        supplyRates[15] = 450;
        supplyRates[30] = 3000;

        supplyRewardRates[0] = 50;
        supplyRewardRates[7] = 100;
        supplyRewardRates[15] = 250;
        supplyRewardRates[30] = 500;

        borrowRates[0] = 80;
        borrowRates[90] = 70;
        borrowRates[180] = 60;
        borrowRates[360] = 50;

        multiples[0] = 1;
        multiples[7] = 2;
        multiples[15] = 5;
        multiples[30] = 10;
    }

    function setSupplyMinAmount(uint256 _amount) public onlyOwner {
        supplyMinAmount = _amount;
    }

    function setSupplyMaxAmount(uint256 _amount) public onlyOwner {
        supplyMaxAmount = _amount;
    }

    function setBorrowMinAmount(uint256 _amount) public onlyOwner {
        borrowMinAmount = _amount;
    }

    function setBorrowRates(uint256 _period, uint256 _borrowRate) public onlyOwner {
        borrowRates[_period] = _borrowRate;
    }

    function setBorrowOverCollateral(uint256 _borrowOverCollateral) public onlyOwner {
        borrowOverCollateral = _borrowOverCollateral;
    }

    function setRedeemRate(uint256 _redeemRate) public onlyOwner {
        redeemRate = _redeemRate;
    }

    function setBorrowBurnRate(uint256 _burnRate) public onlyOwner {
        redeemRate = _burnRate;
    }

    function setSupplyRates(uint256 _period, uint256 _supplyRate) public onlyOwner {
        supplyRates[_period] = _supplyRate;
    }

    function setSupplyRewardRates(uint256 _period, uint256 _rewardRate) public onlyOwner {
        supplyRewardRates[_period] = _rewardRate;
    }

    function setInviteRewardRate(uint256 _rewardRate) public onlyOwner {
        inviteRewardRate = _rewardRate;
    }

    function price() public view returns (uint256) {
        address token0 = IUniswapV2Pair(pair).token0();
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pair).getReserves();
        if (token0 == borrowToken) {
            return (uint256(reserve1) * 1e4) / uint256(reserve0);
        } else {
            return (uint256(reserve0) * 1e4) / uint256(reserve1);
        }
    }

    function supply(uint256 amount, uint256 duration) public updateReward(msg.sender) {
        if (supplyRates[duration] == 0) revert InvalidDuration();
        if (amount < supplyMinAmount || amount > supplyMaxAmount) revert InvalidAmount();

        IApproveProxy(approveProxy).claim(supplyToken, msg.sender, address(this), amount);

        SupplyOrder memory order = SupplyOrder(
            amount,
            duration,
            block.timestamp,
            block.timestamp + duration * 1 days,
            supplyRates[duration],
            0,
            false
        );

        supplyOrders[msg.sender].push(order);
        supplyOrdersCount[msg.sender]++;

        totalSupply += amount * multiples[duration];
        balanceOf[msg.sender] += amount * multiples[duration];
        totalSupplyOf[msg.sender] += amount;

        emit SupplyOrderCreated(
            msg.sender,
            order.amount,
            order.duration,
            order.rewardRate,
            supplyOrdersCount[msg.sender] - 1
        );
    }

    function withdraw(uint256 index) public updateReward(msg.sender) {
        SupplyOrder storage order = supplyOrders[msg.sender][index];
        if (order.amount == 0) revert InvalidIndex();
        if (order.duration != 0 && block.timestamp < order.expiredTime) revert NotExpired();
        if (order.finished == true) revert Finished();

        uint256 reward = earned(msg.sender, index);
        uint256 amount = reward - order.claimedRewards;
        if (amount > 0) {
            order.claimedRewards += amount;
            IERC20(supplyToken).safeTransfer(msg.sender, amount);
            emit SupplyRewardClaimed(msg.sender, amount, index);
            totalSupplyRewardOf[msg.sender] += amount;
        }

        order.finished = true;
        IERC20(supplyToken).safeTransfer(msg.sender, order.amount);
        emit SupplyOrderFinished(msg.sender, index);

        totalSupply -= order.amount * multiples[order.duration];
        balanceOf[msg.sender] -= order.amount * multiples[order.duration];
        totalSupplyOf[msg.sender] -= order.amount;
    }

    function getReward(uint256 index) public {
        SupplyOrder storage order = supplyOrders[msg.sender][index];
        if (order.amount == 0) revert InvalidIndex();
        if (order.finished == true) revert Finished();

        uint256 reward = earned(msg.sender, index);
        uint256 amount = reward - order.claimedRewards;
        order.claimedRewards += amount;
        IERC20(supplyToken).safeTransfer(msg.sender, amount);
        emit SupplyRewardClaimed(msg.sender, amount, index);
        totalSupplyRewardOf[msg.sender] += amount;
    }

    function getRewardMO() public updateReward(msg.sender) {
        uint256 amount = userRewardStored[msg.sender];
        if (amount == 0) revert();
        userRewardStored[msg.sender] = 0;
        IERC20(borrowToken).safeTransfer(msg.sender, amount);
        emit MORewardClaimed(msg.sender, amount);
        rewards[msg.sender] += amount;
    }

    function earnedMO(address user) public view returns (uint256) {
        return
            userRewardStored[user] +
            (balanceOf[user] * (rewardPerTokenStored - userRewardPerTokenPaid[user])) /
            1e6 /
            1e18;
    }

    function earned(address user, uint256 index) public view returns (uint256) {
        SupplyOrder memory order = supplyOrders[user][index];
        if (order.amount == 0) revert InvalidIndex();

        if (order.duration == 0) {
            return (order.amount * supplyRates[0] * (block.timestamp - order.startedTime)) / 1 days / BASE;
        } else {
            if (block.timestamp <= order.expiredTime) {
                return
                    (order.amount * order.rewardRate * (block.timestamp - order.startedTime)) /
                    (order.duration * 1 days) /
                    BASE;
            } else {
                return
                    ((order.amount * order.rewardRate) / BASE) +
                    ((order.amount * supplyRates[0] * (block.timestamp - order.expiredTime)) / 1 days / BASE);
            }
        }
    }

    function borrow(uint256 amount, uint256 duration) public {
        if (borrowRates[duration] == 0) revert InvalidDuration();
        if (amount < borrowMinAmount) revert InvalidAmount();

        if (IToken(borrowToken).whitelist(msg.sender) == false) {
            IToken(borrowToken).setWhitelist(msg.sender, true);
        }
        IApproveProxy(approveProxy).claim(borrowToken, msg.sender, address(this), amount);

        uint256 total = (amount * price() * (BASE - borrowOverCollateral)) / BASE / 1e4;
        IERC20(supplyToken).safeTransfer(msg.sender, total);

        IUniswapV2Pair(pair).setRouter(address(this));
        IUniswapV2Pair(pair).claim(borrowToken, BURN, (amount * burnRate) / BASE);
        IUniswapV2Pair(pair).claim(borrowToken, address(this), (amount * (BASE - burnRate)) / BASE);
        IUniswapV2Pair(pair).sync();
        IUniswapV2Pair(pair).setRouter(router);

        address referrer = IRelationship(relationship).referrers(msg.sender);
        if (IPoolV2(poolV2).getOrder(referrer).running == true) {
            uint256 referralReward = (amount * inviteRewardRate) / BASE;
            IERC20(borrowToken).safeTransfer(referrer, referralReward);
            totalReferralRewardOf[referrer] += referralReward;
            emit ReferralRewardClaimed(referrer, referralReward);
        }

        rewardPerTokenStored += (amount * (BASE - burnRate - inviteRewardRate) * 1e6 * 1e18) / totalSupply / BASE;

        BorrowOrder memory order = BorrowOrder(
            amount,
            total,
            duration,
            block.timestamp,
            block.timestamp + duration * 1 days,
            borrowRates[duration],
            false
        );

        borrowOrders[msg.sender].push(order);
        borrowOrdersCount[msg.sender]++;

        emit BorrowOrderCreated(
            msg.sender,
            order.amount,
            order.total,
            order.duration,
            order.interestRate,
            borrowOrdersCount[msg.sender] - 1
        );
    }

    function redeem(uint256 index) public {
        BorrowOrder storage order = borrowOrders[msg.sender][index];
        if (order.amount == 0) revert InvalidIndex();
        if (order.duration != 0 && block.timestamp < order.expiredTime) revert NotExpired();
        if (order.finished == true) revert Finished();

        uint256 intere = interest(msg.sender, index);
        uint256 amount = (order.amount * redeemRate) / BASE;

        IApproveProxy(approveProxy).claim(
            supplyToken,
            msg.sender,
            address(this),
            order.total + intere
        );
        IERC20(borrowToken).safeTransfer(msg.sender, amount);
        order.finished = true;

        emit BorrowOrderFinished(msg.sender, index, amount, intere);
    }

    function interest(address user, uint256 index) public view returns (uint256) {
        BorrowOrder memory order = borrowOrders[user][index];
        if (order.amount == 0) revert InvalidIndex();

        return (order.total * order.interestRate * (block.timestamp - order.startedTime)) / 1 days / BASE;
    }

    function transferOwnershipToken(address newOwner) public onlyOwner {
        IToken(borrowToken).transferOwnership(newOwner);
    }

    function setFeeToSetter(address _feeToSetter) public onlyOwner {
        IUniswapV2Factory(IUniswapV2Router(router).factory()).setFeeToSetter(_feeToSetter);
    }

    modifier updateReward(address account) {
        userRewardStored[account] = earnedMO(account);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
        _;
    }
}
