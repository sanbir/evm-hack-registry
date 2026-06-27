// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./SEATokenUpgradeable.sol";

/**
 * @title SEATokenFinal
 * @notice SEA Token 最终版本 — 丢弃所有管理员权限
 *
 * @dev 不可逆！升级到此版本后：
 *   - 无法暂停/恢复转账
 *   - 无法修改白名单
 *   - 无法再次升级合约
 *   - 铸造权限已在 V1 中永久锁死（mintingFinished=true）
 *
 *   保留的功能（任何人可调）：
 *   - releaseFoundationTokens() — 基金会锁仓释放
 *   - releaseTechOpsTokens() — 技术运维锁仓释放
 *   - 标准 ERC20 转账
 */
contract SEATokenFinal is SEATokenUpgradeable {
    /// @notice 禁止暂停
    function pause() external pure override {
        revert("Permanently disabled");
    }

    /// @notice 禁止恢复
    function unpause() external pure override {
        revert("Permanently disabled");
    }

    /// @notice 禁止修改白名单
    function setWhitelist(address, bool) external pure override {
        revert("Permanently disabled");
    }

    /// @notice 禁止批量修改白名单
    function setWhitelistBatch(address[] calldata, bool) external pure override {
        revert("Permanently disabled");
    }

    /// @notice 禁止合约升级（永久锁定）
    function _authorizeUpgrade(address) internal pure override {
        revert("Upgrades permanently disabled");
    }

    function version() external pure override returns (string memory) {
        return "1.0.0-final";
    }
}
