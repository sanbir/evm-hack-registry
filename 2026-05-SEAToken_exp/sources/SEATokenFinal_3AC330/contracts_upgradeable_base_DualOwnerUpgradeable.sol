// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title DualOwnerUpgradeable
 * @notice 双 Owner 权限管理基类 - 所有业务合约的公共父合约
 *
 * @dev 权限分离设计：
 *   platformOwner (平台方):
 *     - 合约升级权限（UUPS _authorizeUpgrade）
 *     - 指定/更换 projectOwner
 *     - 转移自身权限
 *
 *   projectOwner (项目方):
 *     - 日常运营权限（onlyOwner 修饰的所有函数）
 *     - 不可自行转移权限（transferOwnership 被禁用）
 *
 * 继承关系：
 *   - platformOwner 存储在 ERC-7201 命名空间存储槽中
 *   - owner() 返回 projectOwner（兼容 OwnableUpgradeable）
 *   - 禁用了 transferOwnership 和 renounceOwnership 防止项目方越权
 */
abstract contract DualOwnerUpgradeable is Initializable, OwnableUpgradeable {
    /// @custom:storage-location erc7201:metasea.storage.DualOwner
    struct DualOwnerStorage {
        address platformOwner;
    }

    // keccak256(abi.encode(uint256(keccak256("metasea.storage.DualOwner")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DUAL_OWNER_STORAGE_LOCATION =
        0x8c8c9e6c1a1f6b7e5a4c3d2b1a0f9e8d7c6b5a49382716050403020100000000;

    event PlatformOwnerTransferred(address indexed previousOwner, address indexed newOwner);
    event ProjectOwnerTransferred(address indexed previousOwner, address indexed newOwner);

    error OnlyPlatformOwner();
    error InvalidPlatformOwner();
    error InvalidProjectOwner();

    function _getDualOwnerStorage() private pure returns (DualOwnerStorage storage $) {
        assembly {
            $.slot := DUAL_OWNER_STORAGE_LOCATION
        }
    }

    /// @dev 仅平台方可调用的修饰器
    modifier onlyPlatformOwner() {
        if (msg.sender != platformOwner()) {
            revert OnlyPlatformOwner();
        }
        _;
    }

    /**
     * @dev 初始化双 Owner（在子合约的 initialize 中调用）
     * @param _platformOwner 平台方地址（升级权限）
     * @param _projectOwner 项目方地址（运营权限，即 owner()）
     */
    function __DualOwner_init(address _platformOwner, address _projectOwner) internal onlyInitializing {
        __DualOwner_init_unchained(_platformOwner, _projectOwner);
    }

    function __DualOwner_init_unchained(address _platformOwner, address _projectOwner) internal onlyInitializing {
        if (_platformOwner == address(0)) revert InvalidPlatformOwner();
        if (_projectOwner == address(0)) revert InvalidProjectOwner();

        DualOwnerStorage storage $ = _getDualOwnerStorage();
        $.platformOwner = _platformOwner;

        // 通过 OwnableUpgradeable 设置 projectOwner 为 owner()
        __Ownable_init(_projectOwner);

        emit PlatformOwnerTransferred(address(0), _platformOwner);
    }

    /// @notice 获取平台方地址
    function platformOwner() public view returns (address) {
        DualOwnerStorage storage $ = _getDualOwnerStorage();
        return $.platformOwner;
    }

    /// @notice 获取项目方地址（等同于 owner()）
    function projectOwner() public view returns (address) {
        return owner();
    }

    /**
     * @notice 平台方转移自身权限给新地址
     * @param newPlatformOwner 新的平台方地址
     */
    function transferPlatformOwnership(address newPlatformOwner) external onlyPlatformOwner {
        if (newPlatformOwner == address(0)) revert InvalidPlatformOwner();

        DualOwnerStorage storage $ = _getDualOwnerStorage();
        address oldOwner = $.platformOwner;
        $.platformOwner = newPlatformOwner;

        emit PlatformOwnerTransferred(oldOwner, newPlatformOwner);
    }

    /**
     * @notice 平台方更换项目方
     * @param newProjectOwner 新的项目方地址
     */
    function setProjectOwner(address newProjectOwner) external onlyPlatformOwner {
        if (newProjectOwner == address(0)) revert InvalidProjectOwner();

        address oldOwner = owner();
        _transferOwnership(newProjectOwner);

        emit ProjectOwnerTransferred(oldOwner, newProjectOwner);
    }

    /**
     * @dev 重写 OwnableUpgradeable._checkOwner()
     *      允许 platformOwner 和 projectOwner 都能调用 onlyOwner 函数
     *      platformOwner 负责部署和配置，projectOwner 负责日常运营
     */
    function _checkOwner() internal view virtual override {
        require(
            msg.sender == owner() || msg.sender == platformOwner(),
            "Not owner or platform owner"
        );
    }

    /// @notice 禁用 transferOwnership - 项目方无法自行转移权限
    function transferOwnership(address) public pure override {
        revert("Use setProjectOwner via platformOwner");
    }

    /// @notice 禁用 renounceOwnership - 不允许放弃所有权
    function renounceOwnership() public pure override {
        revert("Ownership renouncement disabled");
    }
}
