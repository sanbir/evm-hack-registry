// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

/**
 * @title IUniswapV2Pair
 * @notice Pancake/Uniswap V2 Pair 标准接口。
 * @dev 项目主要使用 getReserves、token0/token1、mint/burn、sync 读取价格、加减流动性和同步池子储备。
 */
interface IUniswapV2Pair {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    /// @notice LP token 名称。
    function name() external pure returns (string memory);
    /// @notice LP token 符号。
    function symbol() external pure returns (string memory);
    /// @notice LP token 精度。
    function decimals() external pure returns (uint8);
    /// @notice LP 总供应量。
    function totalSupply() external view returns (uint);
    /// @notice 查询 LP 余额。
    function balanceOf(address owner) external view returns (uint);
    /// @notice 查询 LP 授权额度。
    function allowance(
        address owner,
        address spender
    ) external view returns (uint);

    /// @notice 授权 LP。
    function approve(address spender, uint value) external returns (bool);
    /// @notice 转账 LP。
    function transfer(address to, uint value) external returns (bool);
    /// @notice 代扣转账 LP。
    function transferFrom(
        address from,
        address to,
        uint value
    ) external returns (bool);

    /// @notice permit 域分隔符。
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    /// @notice permit 类型哈希。
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    /// @notice permit nonce。
    function nonces(address owner) external view returns (uint);

    /// @notice EIP-2612 授权签名。
    function permit(
        address owner,
        address spender,
        uint value,
        uint deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(
        address indexed sender,
        uint amount0,
        uint amount1,
        address indexed to
    );
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    /// @notice 最小锁定流动性。
    function MINIMUM_LIQUIDITY() external pure returns (uint);
    /// @notice 工厂地址。
    function factory() external view returns (address);
    /// @notice token0 地址。
    function token0() external view returns (address);
    /// @notice token1 地址。
    function token1() external view returns (address);

    /// @notice 读取池子储备，用于价格计算和自动开启交易判断。
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    /// @notice token0 累计价格。
    function price0CumulativeLast() external view returns (uint);
    /// @notice token1 累计价格。
    function price1CumulativeLast() external view returns (uint);
    /// @notice 上次流动性乘积。
    function kLast() external view returns (uint);

    /// @notice 铸造 LP。
    function mint(address to) external returns (uint liquidity);
    /// @notice 销毁 LP 并返还两种资产。
    function burn(address to) external returns (uint amount0, uint amount1);

    /// @notice 执行 swap。
    function swap(
        uint amount0Out,
        uint amount1Out,
        address to,
        bytes calldata data
    ) external;

    /// @notice 提取超过储备记录的余额。
    function skim(address to) external;
    /// @notice 同步实际余额到储备记录。
    function sync() external;

    /// @notice 初始化 pair 的两个 token 地址。
    function initialize(address, address) external;
}
