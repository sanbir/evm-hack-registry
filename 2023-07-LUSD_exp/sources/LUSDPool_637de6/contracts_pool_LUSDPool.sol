// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../tool/interface/IPancakeRouter.sol";
import "../token/interface/ILUSD.sol";

/**
 * @title LUSD Pool
 * @author LAYER3-TEAM
 * @notice Contract to store LUSD
 */
contract LUSDPool is AccessControlEnumerable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for ILUSD;
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    // testnet: 0xC773BA32c3b0fB39362B3D8AE8e3db137FD7f040
    IERC20 public constant USDT =
        IERC20(0x55d398326f99059fF775485246999027B3197955);

    // testnet: 0xD99D1c33F9fC3444f8101754aBC46c52416550D1
    IPancakeRouter public constant router =
        IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    IERC20 public ETB;
    IERC20 public L3;
    ILUSD public LUSD;

    address public marketingWallet;
    address public nodePool;
    uint256 public nodeFee = 200;
    uint256 public lpFee = 100;

    mapping(address => bool) public isBlackListed;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Swap(address indexed user, uint256 amount);

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
    function setAddrs(
        address etbAddress,
        address l3Address,
        address lusdAddress,
        address _marketingWallet,
        address _nodePool
    ) external onlyRole(MANAGER_ROLE) {
        ETB = IERC20(etbAddress);
        L3 = IERC20(l3Address);
        LUSD = ILUSD(lusdAddress);
        marketingWallet = _marketingWallet;
        nodePool = _nodePool;
    }

    /**
     * @dev Set Data
     */
    function setData(
        uint256 _nodeFee,
        uint256 _lpFee
    ) external onlyRole(MANAGER_ROLE) {
        nodeFee = _nodeFee;
        lpFee = _lpFee;
    }

    /**
     * @dev Set Black List
     */
    function setBlackList(
        address[] memory users,
        bool _isBlackListed
    ) external onlyRole(MANAGER_ROLE) {
        for (uint256 i = 0; i < users.length; i++) {
            isBlackListed[users[i]] = _isBlackListed;
        }
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
     * @dev Deposit
     */
    function deposit(uint256 amount) external nonReentrant {
        USDT.safeTransferFrom(msg.sender, marketingWallet, amount);

        LUSD.mint(msg.sender, amount);

        emit Deposit(msg.sender, amount);
    }

    /**
     * @dev Withdraw
     */
    function withdraw(uint256 amount) external nonReentrant {
        require(!isBlackListed[msg.sender], "This account is abnormal");

        LUSD.safeTransferFrom(msg.sender, address(this), amount);

        uint256 nodeAmount = (amount * nodeFee) / 1e4;
        LUSD.safeTransfer(nodePool, nodeAmount);

        uint256 lpAmount = (amount * lpFee) / 1e4;
        LUSD.burn(address(this), lpAmount);

        uint256 l3Balance = L3.balanceOf(address(this));
        L3.approve(address(router), l3Balance);
        USDT.approve(address(router), lpAmount);
        router.addLiquidity(
            address(L3),
            address(USDT),
            l3Balance,
            lpAmount,
            0,
            0,
            address(this),
            block.timestamp
        );

        LUSD.burn(address(this), amount - nodeAmount - lpAmount);
        USDT.safeTransfer(msg.sender, amount - nodeAmount - lpAmount);

        emit Withdraw(msg.sender, amount);
    }

    /**
     * @dev Swap
     */
    function swap(uint256 amount) external nonReentrant {
        ETB.safeTransferFrom(msg.sender, address(this), amount);

        L3.safeTransfer(msg.sender, amount);

        emit Swap(msg.sender, amount);
    }
}
