// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IBYToken
 * @notice BY 主代币接口，包含交易开关、自动燃烧、卖出税、池子回收和价格读取。
 */
interface IBYToken is IERC20 {
    /// @notice 铸造角色。
    function MINTER_ROLE() external view returns (bytes32);
    /// @notice 销毁角色。
    function BURNER_ROLE() external view returns (bytes32);
    /// @notice 从流动性池回收 BY 的角色。
    function RECYCLE_ROLE() external view returns (bytes32);

    /// @notice 最大供应量。
    function MAX_SUPPLY() external view returns (uint256);
    /// @notice 自动燃烧周期。
    function BURN_INTERVAL() external view returns (uint256);
    /// @notice 每周期燃烧率。
    function DAILY_BURN_RATE() external view returns (uint256);
    /// @notice 燃烧率分母。
    function BURN_DENOMINATOR() external view returns (uint256);
    /// @notice 停止自动燃烧的供应量阈值。
    function STOP_BURN_SUPPLY() external view returns (uint256);
    /// @notice 卖出税率。
    function TAX_RATE() external view returns (uint256);

    /// @notice BY/BNB 池地址。
    function pool() external view returns (address);
    /// @notice Pancake Router 地址。
    function router() external view returns (address);

    /// @notice 是否已开启交易。
    function tradingEnabled() external view returns (bool);
    /// @notice 上次自动燃烧时间。
    function lastBurnTimestamp() external view returns (uint256);

    /// @notice 读取 BNB/USD 价格。
    function getBNBPrice() external view returns (uint256);
    /// @notice 读取 BY/USD 价格。
    function getPrice() external view returns (uint256);

    /// @notice 公开触发自动燃烧。
    function triggerAutoBurn() external;
    /// @notice 管理员手动开启交易。
    function enableTrading() external;
    /// @notice 设置 BY/BNB 池地址。
    function setPool(address _pool) external;
    /// @notice 设置 Router 地址。
    function setRouter(address _router) external;
    /// @notice 从合约库存分发 BY。
    function distribute(address to, uint256 amount) external;
    /// @notice 从池子回收部分 BY 并 sync。
    function recycle(address to, uint256 amount) external;
    /// @notice 销毁调用者持有的 BY。
    function burn(uint256 amount) external;
}
