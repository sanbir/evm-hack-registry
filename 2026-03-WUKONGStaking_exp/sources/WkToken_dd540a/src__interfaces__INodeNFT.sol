// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import "./IUserRelation.sol";

/**
 * @title INodeNFT
 * @notice 节点 NFT 合约接口
 * @dev 
 * - 总量 1000 个（800 个签名铸造 + 200 个购买）
 * - 购买价格 1 BNB（限 200 个）
 * - 800 个通过中心化签名铸造（无初始权益）
 * - 按购买数量 + 800 计算总权重
 * - 分红权益跟随 NFT 转移
 * - 产生权益前会关闭购买
 */
interface INodeNFT is IERC721Enumerable {
    // ========== 状态变量查询 ==========

    /**
     * @notice NFT 价格
     * @return NFT 价格（以 wei 为单位）
     */
    function NFT_PRICE() external view returns (uint256);

    /**
     * @notice 签名验证地址（用于验证签名铸造）
     * @return 签名地址
     */
    function signerAddress() external view returns (address);

    /**
     * @notice 权益分红兜底地址
     * @return 分红兜底地址
     */
    function dividendGuaranteeAddress() external view returns (address);

    /**
     * @notice 用户关系合约
     * @return 用户关系合约地址
     */
    function userRelation() external view returns (IUserRelation);

    /**
     * @notice 支持分红的代币列表
     * @param token 代币地址
     * @return 是否支持该代币分红
     */
    function supportedDividendTokens(address token) external view returns (bool);

    /**
     * @notice 支持分红的代币地址列表
     * @return 代币地址数组
     */
    function dividendTokenList() external view returns (address[] memory);

    /**
     * @notice 代币分红池
     * @param token 代币地址
     * @return 代币分红池余额
     */
    function tokenDividendPools(address token) external view returns (uint256);

    /**
     * @notice 代币总分红金额
     * @param token 代币地址
     * @return 代币总分红金额
     */
    function tokenTotalDividends(address token) external view returns (uint256);

    /**
     * @notice 用户代币已提取的分红
     * @param token 代币地址
     * @param user 用户地址
     * @return 已提取的分红金额
     */
    function userTokenWithdrawn(address token, address user) external view returns (uint256);

    /**
     * @notice 购买铸造开关
     * @return 是否开启购买
     */
    function purchaseOpen() external view returns (bool);

    /**
     * @notice 签名铸造开关
     * @return 是否开启签名铸造
     */
    function signatureMintingOpen() external view returns (bool);

    /**
     * @notice 允许分配分红的合约地址列表
     * @return 分配器地址数组
     */
    function dividendAllocatorList() external view returns (address[] memory);

    /**
     * @notice 当前购买铸造数量
     * @return 已购买数量
     */
    function purchaseMintedCount() external view returns (uint256);

    /**
     * @notice 当前签名铸造数量
     * @return 已签名铸造数量
     */
    function signatureMintedCount() external view returns (uint256);

    /**
     * @notice 最大购买铸造数量
     * @return 最大购买供应量
     */
    function MAX_PURCHASE_SUPPLY() external view returns (uint256);

    /**
     * @notice 最大签名铸造数量
     * @return 最大签名供应量
     */
    function MAX_SIGNATURE_SUPPLY() external view returns (uint256);

    /**
     * @notice 总供应量
     * @return 总供应量
     */
    function MAX_TOTAL_SUPPLY() external view returns (uint256);

    /**
     * @notice BNB 的特殊代币地址
     * @return BNB 特殊地址
     */
    function BNB_TOKEN_ADDRESS() external view returns (address);

    /**
     * @notice TOP 地址
     * @return TOP 地址
     */
    function TOP_ADDR() external view returns (address);

    /**
     * @notice BNB 接收地址
     * @return BNB 接收地址
     */
    function bnbReceiver() external view returns (address);

    /**
     * @notice 签名铸造映射
     * @param id 数据库ID
     * @return 是否已签名铸造
     */
    function signatureMintedMap(uint256 id) external view returns (bool);

    /**
     * @notice 每个 Token ID 的累计分红
     * @param tokenId Token ID
     * @return 累计分红金额
     */
    function tokenDividends(uint256 tokenId) external view returns (uint256);

    /**
     * @notice 每个 Token ID 对应每个代币的权益
     * @param tokenId Token ID
     * @param token 代币地址
     * @return 权益金额
     */
    function tokenDividendByToken(uint256 tokenId, address token) external view returns (uint256);

    /**
     * @notice token 权限汇总
     * @param token 代币地址
     * @return 总权益金额
     */
    function tokenDividendByTokenTotal(address token) external view returns (uint256);

    /**
     * @notice 用户已提取的分红
     * @param token 代币地址
     * @return 已提取分红金额
     */
    function withdrawnDividends(address token) external view returns (uint256);

    /**
     * @notice Token ID 是否已铸造
     * @param tokenId Token ID
     * @return 是否已铸造
     */
    function mintedTokens(uint256 tokenId) external view returns (bool);

    /**
     * @notice Token ID 的铸造方式
     * @param tokenId Token ID
     * @return 是否为购买铸造
     */
    function isPurchased(uint256 tokenId) external view returns (bool);

    /**
     * @notice 用户是否已经使用过签名领取
     * @param signature 签名哈希
     * @return 是否已使用
     */
    function usedSignatures(bytes32 signature) external view returns (bool);

    // ========== 铸造功能 ==========

    /**
     * @notice 购买铸造 NFT
     * @dev 
     * - 支付 1 BNB（全额进入分红池）
     * - 不限制购买数量
     * - 购买的 NFT 在分红产生前可购买
     */
    function purchaseNFT() external payable;

    /**
     * @notice 通过签名铸造 NFT
     * @dev 
     * - 通过中心化签名铸造
     * - 限 800 个
     * - 自动分配连续的 Token ID
     * - 初始无权益（分红基数设为当前值）
     * @param quantity 要铸造的数量
     * @param id 数据库ID（用于回写数据库）
     * @param deadline 过期时间戳
     * @param signature 签名
     */
    function signatureMint(uint256 quantity, uint256 id, uint256 deadline, bytes calldata signature) external;

    // ========== 分红功能 ==========

    /**
     * @notice 统一添加分红（自动平分到已铸造的 NFT）
     * @dev 外部可以向合约转账代币或BNB增加分红池，自动平分给所有已铸造的 NFT
     * @param token 代币地址（BNB 使用 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE）
     * @param amount 代币数量
     */
    function addDividend(address token, uint256 amount) external payable;

    /**
     * @notice 添加 BNB 分红池（自动平分到已铸造的 NFT）
     * @dev 便捷方法，自动使用 BNB 特殊地址调用 addDividend
     */
    function addBNBDividend() external payable;

    /**
     * @notice 添加代币分红池（自动平分到已铸造的 NFT）
     * @dev 便捷方法，自动调用 addDividend
     * @param token 代币地址
     * @param amount 代币数量
     */
    function addTokenDividend(address token, uint256 amount) external;

    /**
     * @notice 计算用户可提取的代币分红（基于 NFT 上的权益记录）
     * @dev 
     * - 计算用户所有持有的 NFT 的权益总和
     * @param user 用户地址
     * @param token 代币地址
     * @return 可提取的代币数量
     */
    function calculateTokenDividend(address user, address token) external view returns (uint256);

    /**
     * @notice 提取 BNB 分红
     * @dev 权益跟随 NFT，转出 NFT 时分红权益也会转移
     */
    function withdrawDividend() external;

    /**
     * @notice 提取代币分红
     * @dev 
     * - 权益跟随 NFT 转移
     * - 领取时清空该地址下所有 NFT 的权益
     * @param token 代币地址
     */
    function withdrawTokenDividend(address token) external;

    // ========== 查询功能 ==========

    /**
     * @notice 获取铸造信息
     * @return _purchaseOpen 购买开关
     * @return _signatureOpen 签名铸造开关
     * @return purchasedCount 已购买数量
     * @return signatureCount 已签名铸造数量
     * @return remainingPurchase 可购买数量
     * @return remainingSignature 可签名铸造数量
     * @return chainId 链ID
     */
    function getMintInfo()
        external
        view
        returns (
            bool _purchaseOpen,
            bool _signatureOpen,
            uint256 purchasedCount,
            uint256 signatureCount,
            uint256 remainingPurchase,
            uint256 remainingSignature,
            uint256 chainId
        );

    /**
     * @notice 获取用户拥有的所有 Token ID 及其分红
     * @param user 用户地址
     * @return tokens Token ID 数组
     * @return dividends 对应的分红数组
     */
    function getUserTokensWithDividends(address user)
        external
        view
        returns (uint256[] memory tokens, uint256[] memory dividends);

    /**
     * @notice 获取用户拥有的所有 Token ID
     * @param user 用户地址
     * @return Token ID 数组
     */
    function getUserTokens(address user) external view returns (uint256[] memory);

    /**
     * @notice 获取分红池信息
     * @return totalWeight 总权重（购买数量 + 800）
     * @return purchaseCount 购买铸造数量
     * @return signatureCount 签名铸造数量
     */
    function getDividendInfo()
        external
        view
        returns (uint256 totalWeight, uint256 purchaseCount, uint256 signatureCount);

    /**
     * @notice 获取代币分红信息
     * @param token 代币地址
     * @return poolSize 代币分红池大小
     * @return totalAllocated 总分配金额
     * @return isSupported 是否支持该代币
     */
    function getTokenDividendInfo(address token)
        external
        view
        returns (uint256 poolSize, uint256 totalAllocated, bool isSupported);

    /**
     * @notice 获取所有支持的分红代币列表
     * @return 支持的代币地址数组
     */
    function getSupportedDividendTokens() external view returns (address[] memory);

    /**
     * @notice 获取用户分红信息
     * @param user 用户地址
     * @param tokens 要查询的权益代币地址数组
     * @return nftCount 持有的 NFT 数量
     * @return _tokens 权益代币地址数组
     * @return _availables 可提取分红
     * @return _withdrawns 已提取分红
     */
    function getUserDividendInfo(address user, address[] memory tokens)
        external
        view
        returns (uint256 nftCount, address[] memory _tokens, uint256[] memory _availables, uint256[] memory _withdrawns);

    // ========== 管理员功能 ==========

    /**
     * @notice 开启购买
     */
    function openPurchase() external;

    /**
     * @notice 关闭购买
     */
    function closePurchase() external;

    /**
     * @notice 开启签名铸造
     */
    function openSignatureMinting() external;

    /**
     * @notice 关闭签名铸造
     */
    function closeSignatureMinting() external;

    /**
     * @notice 设置签名地址
     * @param _signerAddress 新的签名地址
     */
    function setSignerAddress(address _signerAddress) external;

    /**
     * @notice 添加支持分红的代币
     * @param token 代币地址
     */
    function addSupportedToken(address token) external;

    /**
     * @notice 移除支持分红的代币
     * @param token 代币地址
     */
    function removeSupportedToken(address token) external;

    /**
     * @notice 设置权益分红兜底地址
     * @param _dividendGuaranteeAddress 新的分红保障地址
     */
    function setDividendGuaranteeAddress(address _dividendGuaranteeAddress) external;

    /**
     * @notice 设置 BNB 接收地址
     * @param _bnbReceiver 新的 BNB 接收地址
     */
    function setBNBReceiver(address _bnbReceiver) external;

    /**
     * @notice 设置基础 Token URI
     * @param baseURI 新的基础 URI
     */
    function setBaseURI(string calldata baseURI) external;

    /**
     * @notice 获取 Token URI
     * @param tokenId Token ID
     * @return Token URI
     */
    function tokenURI(uint256 tokenId) external view returns (string memory);

    // ========== 事件 ==========

    /**
     * @notice NFT 铸造事件
     * @param to 接收地址
     * @param tokenId Token ID
     * @param referrer 推荐人
     */
    event NFTMinted(address indexed to, uint256 indexed tokenId, address indexed referrer);

    /**
     * @notice 通过签名领取事件
     * @param receiver 接收地址
     * @param tokenId Token ID
     * @param id 数据库ID
     * @param signature 签名
     */
    event ClaimedWithSignature(address indexed receiver, uint256 indexed tokenId, uint256 indexed id, bytes signature);

    /**
     * @notice 分红提取事件
     * @param user 用户地址
     * @param amount 提取金额
     */
    event DividendWithdrawn(address indexed user, uint256 indexed amount);

    /**
     * @notice 铸造开关变更事件
     * @param isOpen 开关状态
     */
    event MintingStatusChanged(bool isOpen);

    /**
     * @notice 签名地址变更事件
     * @param newSigner 新的签名地址
     */
    event SignerAddressChanged(address indexed newSigner);

    /**
     * @notice 购买开关变更事件
     * @param isOpen 开关状态
     */
    event PurchaseStatusChanged(bool isOpen);

    /**
     * @notice 签名铸造开关变更事件
     * @param isOpen 开关状态
     */
    event SignatureMintingStatusChanged(bool isOpen);

    /**
     * @notice 代币分红添加事件
     * @param token 代币地址
     * @param amount 添加金额
     * @param donor 捐赠者
     */
    event TokenDividendAdded(address indexed token, uint256 indexed amount, address indexed donor);

    /**
     * @notice 代币分红分配事件
     * @param token 代币地址
     * @param totalAllocated 总分配金额
     */
    event TokenDividendAllocated(address indexed token, uint256 indexed totalAllocated);

    /**
     * @notice 代币分红提取事件
     * @param user 用户地址
     * @param token 代币地址
     * @param amount 提取金额
     */
    event TokenDividendWithdrawn(address indexed user, address indexed token, uint256 indexed amount);

    /**
     * @notice 分配器添加事件
     * @param allocator 分配器地址
     */
    event DividendAllocatorAdded(address indexed allocator);

    /**
     * @notice 分配器移除事件
     * @param allocator 分配器地址
     */
    event DividendAllocatorRemoved(address indexed allocator);

    /**
     * @notice 支持的代币添加/移除事件
     * @param token 代币地址
     * @param isSupported 是否支持
     */
    event SupportedTokenChanged(address indexed token, bool isSupported);

    /**
     * @notice 分红保障地址变更事件
     * @param oldAddress 旧的分红保障地址
     * @param newAddress 新的分红保障地址
     */
    event DividendGuaranteeAddressChanged(address indexed oldAddress, address indexed newAddress);

    /**
     * @notice Token URI 设置事件
     * @param newURI 新的 URI
     */
    event BaseURISet(string newURI);
}
