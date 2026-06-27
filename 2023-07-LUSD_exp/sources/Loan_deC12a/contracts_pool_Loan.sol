// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../tool/interface/IPancakeRouter.sol";
import "../token/interface/ILUSD.sol";

/**
 * @title Loan Contract
 * @author LAYER3-TEAM
 * @notice Users can supply token loans to obtain LUSD
 */
contract Loan is AccessControlEnumerable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for ILUSD;
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    ILUSD public LUSD;

    // testnet: 0xC773BA32c3b0fB39362B3D8AE8e3db137FD7f040
    IERC20 public constant USDT =
        IERC20(0x55d398326f99059fF775485246999027B3197955);

    // testnet: 0xD99D1c33F9fC3444f8101754aBC46c52416550D1
    IPancakeRouter public constant router =
        IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    struct Info {
        address payoutToken;
        uint256 redeemFee;
        uint256 supplyRatio;
        uint256 dailyRate;
    }
    mapping(address => Info) public info;

    struct Order {
        address supplyToken;
        address payoutToken;
        uint256 redeemFee;
        uint256 supplyRatio;
        uint256 dailyRate;
        uint256 supplyAmount;
        uint256 payoutAmount;
        uint256 supplyTime;
        uint256 redeemAmount;
        uint256 redeemTime;
    }
    mapping(address => Order[]) public orders;

    event Supply(
        address indexed user,
        uint256 orderId,
        address supplyToken,
        address payoutToken,
        uint256 redeemFee,
        uint256 supplyRatio,
        uint256 dailyRate,
        uint256 supplyAmount,
        uint256 payoutAmount,
        uint256 supplyTime
    );
    event Redeem(
        address indexed user,
        uint256 orderId,
        address supplyToken,
        address payoutToken,
        uint256 redeemFee,
        uint256 supplyRatio,
        uint256 dailyRate,
        uint256 supplyAmount,
        uint256 payoutAmount,
        uint256 supplyTime,
        uint256 redeemAmount,
        uint256 redeemTime
    );

    /**
     * @param manager Initialize Manager Role
     */
    constructor(address manager) {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(MANAGER_ROLE, manager);
    }

    /**
     * @dev Set Addrs
     */
    function setAddrs(address lusdAddress) external onlyRole(MANAGER_ROLE) {
        LUSD = ILUSD(lusdAddress);
    }

    /**
     * @dev Set Info
     */
    function setInfo(
        address supplyToken,
        address payoutToken,
        uint256 redeemFee,
        uint256 supplyRatio,
        uint256 dailyRate
    ) external onlyRole(MANAGER_ROLE) {
        info[supplyToken].payoutToken = payoutToken;
        info[supplyToken].redeemFee = redeemFee;
        info[supplyToken].supplyRatio = supplyRatio;
        info[supplyToken].dailyRate = dailyRate;
    }

    /**
     * @dev Claim Token
     */
    function claimToken(
        address token,
        address user,
        uint256 amount
    ) external onlyRole(MANAGER_ROLE) {
        IERC20(token).safeTransfer(user, amount);
    }

    /**
     * @dev Supply
     */
    function supply(
        address supplyToken,
        uint256 supplyAmount
    ) external nonReentrant {
        address[] memory path = new address[](2);
        path[0] = address(supplyToken);
        path[1] = address(USDT);
        uint256 usdtAmount = router.getAmountsOut(supplyAmount, path)[1];

        Order memory order = Order({
            supplyToken: supplyToken,
            payoutToken: info[supplyToken].payoutToken,
            redeemFee: info[supplyToken].redeemFee,
            supplyRatio: info[supplyToken].supplyRatio,
            dailyRate: info[supplyToken].dailyRate,
            supplyAmount: supplyAmount,
            payoutAmount: (usdtAmount * info[supplyToken].supplyRatio) / 1e4,
            supplyTime: block.timestamp,
            redeemAmount: 0,
            redeemTime: 0
        });
        orders[msg.sender].push(order);

        IERC20(supplyToken).safeTransferFrom(
            msg.sender,
            address(this),
            supplyAmount
        );
        LUSD.mint(msg.sender, order.payoutAmount);

        emit Supply(
            msg.sender,
            orders[msg.sender].length - 1,
            order.supplyToken,
            order.payoutToken,
            order.redeemFee,
            order.supplyRatio,
            order.dailyRate,
            order.supplyAmount,
            order.payoutAmount,
            order.supplyTime
        );
    }

    /**
     * @dev Redeem
     */
    function redeem(uint256 orderId) external nonReentrant {
        Order storage order = orders[msg.sender][orderId];

        require(order.redeemAmount == 0, "This order has been redeemed");

        uint256 redeemAmount = order.payoutAmount +
            (order.payoutAmount *
                order.dailyRate *
                (block.timestamp - order.supplyTime)) /
            1 days /
            1e4;
        order.redeemAmount = redeemAmount;
        order.redeemTime = block.timestamp;

        LUSD.safeTransferFrom(msg.sender, address(this), redeemAmount);
        LUSD.burn(address(this), redeemAmount);
        IERC20(order.supplyToken).safeTransfer(
            msg.sender,
            order.supplyAmount - (order.supplyAmount * order.redeemFee) / 1e4
        );

        emit Redeem(
            msg.sender,
            orderId,
            order.supplyToken,
            order.payoutToken,
            order.redeemFee,
            order.supplyRatio,
            order.dailyRate,
            order.supplyAmount,
            order.payoutAmount,
            order.supplyTime,
            order.redeemAmount,
            order.redeemTime
        );
    }

    /**
     * @dev Get User Redeemable Orders
     */
    function getUserRedeemableOrders(
        address user
    ) external view returns (uint256[] memory) {
        Order[] memory order = orders[user];

        uint256 length;
        for (uint256 i = 0; i < order.length; i++) {
            if (order[i].redeemAmount == 0) length++;
        }

        uint256[] memory orderIds = new uint256[](length);
        uint256 index;
        for (uint256 i = 0; i < order.length; i++) {
            if (order[i].redeemAmount == 0) {
                orderIds[index] = i;
                index++;
            }
        }

        return orderIds;
    }

    /**
     * @dev Get User Redeemed Orders
     */
    function getUserRedeemedOrders(
        address user
    ) external view returns (uint256[] memory) {
        Order[] memory order = orders[user];

        uint256 length;
        for (uint256 i = 0; i < order.length; i++) {
            if (order[i].redeemAmount > 0) length++;
        }

        uint256[] memory orderIds = new uint256[](length);
        uint256 index;
        for (uint256 i = 0; i < order.length; i++) {
            if (order[i].redeemAmount > 0) {
                orderIds[index] = i;
                index++;
            }
        }

        return orderIds;
    }

    /**
     * @dev Get User Orders Length
     */
    function getUserOrdersLength(address user) external view returns (uint256) {
        return orders[user].length;
    }
}
