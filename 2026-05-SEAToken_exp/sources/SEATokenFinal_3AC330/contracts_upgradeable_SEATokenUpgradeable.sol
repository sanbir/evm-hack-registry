// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./base/DualOwnerUpgradeable.sol";

/**
 * @title SEATokenUpgradeable
 * @notice SEA Token - MetaSea 生态代币 (可升级版本)
 *
 * @dev 代币经济模型：
 *   - 总量: 100 亿 SEA，精度 6 位
 *   - 一次性铸造，铸造后 mintingFinished = true，永远无法再铸造
 *
 *   分配比例：
 *   - 基金会 10% → foundationVault（6 月锁仓 + 30 月线性释放）
 *   - 技术运维 10% → techOpsVault（6 月锁仓 + 30 月线性释放）
 *   - 生态矿池 75% → Treasury（IDO 奖励、MetaSea 收益来源）
 *   - 流动性 1% → liquidityVault（用于 DEX 初始流动性）
 *   - 上所预留 4% → flexibleVault
 *
 *   基金会/技术运维的锁仓释放：
 *   - 前 6 个月完全锁定
 *   - 之后 30 个月线性释放
 *   - 任何人都可以调用 releaseFoundationTokens/releaseTechOpsTokens 触发释放
 *
 *   暂停机制：
 *   - 暂停时仅白名单地址可转账（保证合约间 SEA 流转正常）
 *
 * 双 Owner 权限：
 * - platformOwner: 合约升级
 * - projectOwner: 日常运营（暂停、白名单管理）
 */
contract SEATokenUpgradeable is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    DualOwnerUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    uint8 private constant _decimals = 6;
    uint256 public constant TOTAL_SUPPLY = 10_000_000_000 * 10**6; // 100 亿

    // ===== 代币分配比例 =====
    uint256 public constant FOUNDATION_RATIO = 10;      // 基金会 10%
    uint256 public constant TECH_OPS_RATIO = 10;        // 技术运维 10%
    uint256 public constant ECOSYSTEM_POOL_RATIO = 75;  // 生态矿池 75%
    uint256 public constant LIQUIDITY_RATIO = 1;        // 流动性 1%
    uint256 public constant FLEXIBLE_RATIO = 4;         // 上所预留 4%

    // ===== 分配地址 =====
    address public foundationVault;   // 基金会 Vault 合约地址
    address public techOpsVault;      // 技术运维 Vault 合约地址
    address public ecosystemPool;     // 生态矿池（Treasury 合约地址）
    address public liquidityVault;    // 流动性 Vault 合约地址
    address public flexibleVault;     // 上所预留 Vault 合约地址

    // ===== 锁仓释放 =====
    uint256 public deployTime;                          // 合约部署时间
    uint256 public constant LOCK_PERIOD = 180 days;     // 6 个月锁仓期
    uint256 public constant RELEASE_PERIOD = 900 days;  // 30 个月线性释放期

    uint256 public foundationReleased;  // 基金会已释放数量
    uint256 public techOpsReleased;     // 技术运维已释放数量

    // ===== 状态 =====
    bool public mintingFinished;  // 铸造已完成（不可逆）

    /// @notice 黑洞地址（用于代币销毁）
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice 白名单（暂停时仍可转账的地址）
    mapping(address => bool) public whitelist;

    event MintingFinished();
    event VaultTokensReleased(address indexed vault, uint256 amount);
    event WhitelistUpdated(address indexed account, bool status);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice 初始化合约
     * @param _platformOwner 平台方地址（升级权限）
     * @param _projectOwner 项目方地址（运营权限）
     */
    function initialize(address _platformOwner, address _projectOwner) public initializer {
        __ERC20_init("SEA Token", "SEA");
        __ERC20Burnable_init();
        __DualOwner_init(_platformOwner, _projectOwner);
        __Pausable_init();

        deployTime = block.timestamp;
    }

    function decimals() public pure override returns (uint8) {
        return _decimals;
    }

    /**
     * @notice 初始化并铸造所有代币（仅可调用一次）
     * @dev 基金会/技术运维代币铸造到合约本身（锁仓），其余直接发到目标地址
     * @param _foundationVault 基金会 Vault 地址
     * @param _techOpsVault 技术运维 Vault 地址
     * @param _ecosystemPool 生态矿池地址（Treasury）
     * @param _liquidityVault 流动性 Vault 地址
     * @param _flexibleVault 上所预留 Vault 地址
     */
    function initializeAndMint(
        address _foundationVault,
        address _techOpsVault,
        address _ecosystemPool,
        address _liquidityVault,
        address _flexibleVault
    ) external onlyOwner {
        require(!mintingFinished, "Minting already finished");
        require(_foundationVault != address(0), "Invalid foundation vault");
        require(_techOpsVault != address(0), "Invalid tech ops vault");
        require(_ecosystemPool != address(0), "Invalid ecosystem pool");
        require(_liquidityVault != address(0), "Invalid liquidity vault");
        require(_flexibleVault != address(0), "Invalid flexible vault");

        foundationVault = _foundationVault;
        techOpsVault = _techOpsVault;
        ecosystemPool = _ecosystemPool;
        liquidityVault = _liquidityVault;
        flexibleVault = _flexibleVault;

        uint256 foundationAmount = (TOTAL_SUPPLY * FOUNDATION_RATIO) / 100;
        uint256 techOpsAmount = (TOTAL_SUPPLY * TECH_OPS_RATIO) / 100;
        uint256 ecosystemAmount = (TOTAL_SUPPLY * ECOSYSTEM_POOL_RATIO) / 100;
        uint256 liquidityAmount = (TOTAL_SUPPLY * LIQUIDITY_RATIO) / 100;
        uint256 flexibleAmount = (TOTAL_SUPPLY * FLEXIBLE_RATIO) / 100;

        // 基金会和技术运维代币锁在合约中（需通过 release 函数释放）
        _mint(address(this), foundationAmount + techOpsAmount);

        // 其他直接发放到目标地址
        _mint(ecosystemPool, ecosystemAmount);
        _mint(liquidityVault, liquidityAmount);
        _mint(flexibleVault, flexibleAmount);

        // 将财库地址加入白名单（暂停时仍可流转）
        whitelist[foundationVault] = true;
        whitelist[techOpsVault] = true;
        whitelist[ecosystemPool] = true;
        whitelist[liquidityVault] = true;
        whitelist[flexibleVault] = true;

        mintingFinished = true;
        emit MintingFinished();
    }

    /// @notice 查询基金会当前可释放的代币数量
    function getFoundationReleasable() public view returns (uint256) {
        return _getReleasableAmount(
            (TOTAL_SUPPLY * FOUNDATION_RATIO) / 100,
            foundationReleased
        );
    }

    /// @notice 查询技术运维当前可释放的代币数量
    function getTechOpsReleasable() public view returns (uint256) {
        return _getReleasableAmount(
            (TOTAL_SUPPLY * TECH_OPS_RATIO) / 100,
            techOpsReleased
        );
    }

    /**
     * @dev 计算线性释放的可释放数量
     * @param totalAmount 总分配量
     * @param released 已释放量
     * @return 当前可释放量
     */
    function _getReleasableAmount(uint256 totalAmount, uint256 released) internal view returns (uint256) {
        // 锁仓期内不可释放
        if (block.timestamp < deployTime + LOCK_PERIOD) {
            return 0;
        }

        uint256 timeElapsed = block.timestamp - deployTime - LOCK_PERIOD;
        // 释放期结束后全部可释放
        if (timeElapsed >= RELEASE_PERIOD) {
            return totalAmount - released;
        }

        // 线性释放
        uint256 totalReleasable = (totalAmount * timeElapsed) / RELEASE_PERIOD;
        if (totalReleasable <= released) {
            return 0;
        }
        return totalReleasable - released;
    }

    /// @notice 释放基金会代币（任何人可调用）
    function releaseFoundationTokens() external {
        uint256 releasable = getFoundationReleasable();
        require(releasable > 0, "No tokens to release");

        foundationReleased += releasable;
        _transfer(address(this), foundationVault, releasable);

        emit VaultTokensReleased(foundationVault, releasable);
    }

    /// @notice 释放技术运维代币（任何人可调用）
    function releaseTechOpsTokens() external {
        uint256 releasable = getTechOpsReleasable();
        require(releasable > 0, "No tokens to release");

        techOpsReleased += releasable;
        _transfer(address(this), techOpsVault, releasable);

        emit VaultTokensReleased(techOpsVault, releasable);
    }

    /// @notice 设置单个地址的白名单状态
    function setWhitelist(address account, bool status) external virtual onlyOwner {
        whitelist[account] = status;
        emit WhitelistUpdated(account, status);
    }

    /// @notice 批量设置白名单
    function setWhitelistBatch(address[] calldata accounts, bool status) external virtual onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            whitelist[accounts[i]] = status;
            emit WhitelistUpdated(accounts[i], status);
        }
    }

    function pause() external virtual onlyOwner {
        _pause();
    }

    function unpause() external virtual onlyOwner {
        _unpause();
    }

    /**
     * @dev 转账前置检查 - 暂停时仅白名单可转账
     * @param from 发送方（address(0) 表示铸造）
     * @param to 接收方（address(0) 表示销毁）
     * @param amount 转账数量
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        if (paused()) {
            require(
                whitelist[from] || whitelist[to] || from == address(0) || to == address(0),
                "Token transfer paused"
            );
        }
        super._update(from, to, amount);
    }

    /// @dev 合约升级授权 - 仅平台方可升级
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyPlatformOwner {}

    function version() external pure virtual returns (string memory) {
        return "1.0.0";
    }
}
