// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title TIPToken - TIP Token
 * @dev 基于DQT改造，新增功能：
 *      1. 1000亿TIP全部打入底池锁死，无预留，无私募
 *      2. TIP只能卖不能买（买入时90%销毁+6%手续费，用户收到4%）
 *      3. 卖出税6%基础，价格下跌时自动提高手续费（跌5%→20%，跌10%→50%）
 *      4. 交易对黑名单：禁止外部通过Pair移除LP
 *      5. 修复setAdminContract BUG
 */
contract TIPToken is ERC20, Ownable, ERC20Burnable {
    
    uint256 public constant TOTAL_SUPPLY = 1000 * 10**8 * 10**18; // 1000亿
    
    // ============ 买卖税率 (基点，100 = 1%) ============
    uint256 public buyBurnRate = 9000;    // 90% 销毁（TIP只能卖不能买，买入重税）
    uint256 public buyFeeRate = 600;      // 6% 买入手续费
    uint256 public sellTax = 600;         // 6% 基础卖出税
    uint256 public sellTaxLevel1 = 2000;  // 价格跌5%时卖出税 20%
    uint256 public sellTaxLevel2 = 5000;  // 价格跌10%时卖出税 50%
    
    // ============ 价格监控 ============
    uint256 public lastPrice;             // 上一次卖出价格（SOL计价，1 TIP = x SOL，放大1e18）
    bool public priceInitialized;         // 是否已初始化价格
    uint256 public priceDropLevel1 = 500; // 跌5%阈值（基点）
    uint256 public priceDropLevel2 = 1000;// 跌10%阈值（基点）
    
    // ============ 税费接收地址 ============
    address public taxReceiver;           // 买入手续费接收地址
    address public sellFeeReceiver;       // 卖出手续费接收地址
    
    // ============ 合约地址 ============
    address public stakeCoreContract;     // 质押核心合约（接收卖出税分红给单币质押用户）
    address public pool;                  // 底池地址 (Pair合约)
    address public miningContract;        // 爆块合约
    address public adminContract;         // 管理员合约
    
    // ============ 授权 ============
    mapping(address => bool) public minters;
    mapping(address => bool) public isExempt;       // 白名单（买卖不收税）
    mapping(address => bool) public isBlacklisted;  // 黑名单（禁止交易）
    mapping(address => bool) public isLpBlacklist;  // LP黑名单（禁止通过此地址移除LP）
    mapping(address => bool) public authorized;    // 授权合约（可调用mint/burn等）
    
    uint256 public blacklistBalances;
    bool public poolInitialized;
    address public router;
    
    // ============ 事件 ============
    event PoolSet(address indexed pool);
    event RouterSet(address indexed router);
    event MiningContractSet(address indexed mining);
    event AdminContractSet(address indexed admin);
    event PoolInitialized(address indexed pool, uint256 amount);
    event BurnedFromPool(uint256 amount);
    event DistributedFromPool(address indexed to, uint256 amount);
    event Minted(address indexed to, uint256 amount);
    event BuyBurned(address indexed buyer, uint256 burnedAmount, uint256 feeAmount, uint256 receivedAmount);
    event ExemptSet(address indexed account, bool status);
    event BlacklistSet(address indexed account, bool status);
    event LpBlacklistSet(address indexed account, bool status);
    event SellBurned(address indexed seller, uint256 burnedAmount, uint256 remainingAmount);
    event SellBurnStop(uint256 circulatingSupply);
    event PriceUpdated(uint256 oldPrice, uint256 newPrice, uint256 sellTaxUsed);
    event SellTaxAutoAdjusted(uint256 baseTax, uint256 adjustedTax, string reason);
    
    // ============ 修饰符 ============
    modifier onlyMinter() {
        require(msg.sender == adminContract || msg.sender == miningContract || msg.sender == owner() || authorized[msg.sender], "!minter");
        _;
    }
    
    modifier onlyMining() {
        require(msg.sender == miningContract || msg.sender == adminContract || msg.sender == owner() || authorized[msg.sender], "!mining");
        _;
    }
    
    modifier onlyOwnerOrAdmin() {
        require(msg.sender == owner() || msg.sender == adminContract, "!auth");
        _;
    }
    
    constructor() ERC20("TIP Token", "TIP") Ownable(msg.sender) {
        _mint(msg.sender, TOTAL_SUPPLY);
        minters[msg.sender] = true;
        isExempt[msg.sender] = true;
    }
    
    // ============ 白名单/黑名单管理 ============
    
    function setExempt(address account, bool status) external onlyOwnerOrAdmin {
        isExempt[account] = status;
        emit ExemptSet(account, status);
    }
    
    function setBlacklist(address account, bool status) external onlyOwnerOrAdmin {
        if (status && !isBlacklisted[account]) {
            blacklistBalances += balanceOf(account);
        } else if (!status && isBlacklisted[account]) {
            uint256 bal = balanceOf(account);
            blacklistBalances = blacklistBalances > bal ? blacklistBalances - bal : 0;
        }
        isBlacklisted[account] = status;
        emit BlacklistSet(account, status);
    }
    
    /**
     * @dev 设置LP黑名单 - 被加入LP黑名单的地址无法通过Pair移除流动性
     *      交易对(Pair)地址本身应加入此黑名单，防止用户直接通过DEX移除LP
     */
    function setLpBlacklist(address account, bool status) external onlyOwnerOrAdmin {
        isLpBlacklist[account] = status;
        emit LpBlacklistSet(account, status);
    }
    
    // ============ 合约地址设置 ============
    
    function setRouter(address _router) external onlyOwnerOrAdmin {
        router = _router;
        emit RouterSet(_router);
    }
    
    function setPool(address _pool) external onlyOwnerOrAdmin {
        require(_pool != address(0), "Invalid pool");
        pool = _pool;
        poolInitialized = true;
        // pool不设isExempt — 否则用户从池子买入时msg.sender=pool会跳过买入税
        // 内部操作(burnFromPool/distributeFromPool)用_transfer直接调用，不走public transfer
        isLpBlacklist[_pool] = true; // 交易对默认加入LP黑名单
        emit PoolSet(_pool);
        emit PoolInitialized(_pool, 0);
    }
    
    function setMiningContract(address _mining) external onlyOwnerOrAdmin {
        miningContract = _mining;
        isExempt[_mining] = true;
        emit MiningContractSet(_mining);
    }
    
    /**
     * @dev 设置管理员合约 - 修复BUG：必须更新adminContract状态变量
     */
    function setAdminContract(address _admin) external onlyOwnerOrAdmin {
        require(_admin != address(0), "Invalid address");
        adminContract = _admin;
        isExempt[_admin] = true;
        minters[_admin] = true;
        emit AdminContractSet(_admin);
    }
    
    function setTaxReceiver(address _receiver) external onlyOwnerOrAdmin {
        taxReceiver = _receiver;
    }
    
    function setSellFeeReceiver(address _receiver) external onlyOwnerOrAdmin {
        sellFeeReceiver = _receiver;
    }
    
    function setStakeCoreContract(address _contract) external onlyOwnerOrAdmin {
        stakeCoreContract = _contract;
        isExempt[_contract] = true;
    }
    
    function setMinter(address _minter, bool _enabled) external onlyOwnerOrAdmin {
        minters[_minter] = _enabled;
    }

    function setAuthorized(address _addr, bool _enabled) external onlyOwnerOrAdmin {
        authorized[_addr] = _enabled;
    }
    
    // ============ 价格监控配置 ============
    
    /**
     * @dev 设置价格下跌阈值和对应手续费率
     * @param _level1 跌幅阈值1（基点，如500=5%）
     * @param _level2 跌幅阈值2（基点，如1000=10%）
     * @param _tax1 跌幅1对应卖出税（基点，如2000=20%）
     * @param _tax2 跌幅2对应卖出税（基点，如5000=50%）
     */
    function setPriceDropConfig(
        uint256 _level1, uint256 _level2,
        uint256 _tax1, uint256 _tax2
    ) external onlyOwnerOrAdmin {
        require(_level1 < _level2, "Level1 must < Level2");
        require(_tax1 < _tax2, "Tax1 must < Tax2");
        priceDropLevel1 = _level1;
        priceDropLevel2 = _level2;
        sellTaxLevel1 = _tax1;
        sellTaxLevel2 = _tax2;
    }
    
    /**
     * @dev 手动初始化价格（首次设置参考价格）
     */
    function initPrice(uint256 _price) external onlyOwnerOrAdmin {
        require(_price > 0, "Invalid price");
        lastPrice = _price;
        priceInitialized = true;
    }
    
    /**
     * @dev 根据当前价格对比上一次价格，计算动态卖出税率
     * @return 当前应使用的卖出税率（基点）
     */
    function getDynamicSellTax() public view returns (uint256) {
        if (!priceInitialized || lastPrice == 0) {
            return sellTax; // 未初始化价格，使用基础税率
        }
        
        // 获取当前价格（从底池计算）
        uint256 currentPrice = _getCurrentPrice();
        if (currentPrice == 0) {
            return sellTax;
        }
        
        // 计算跌幅：dropBps = (lastPrice - currentPrice) * 10000 / lastPrice
        if (currentPrice >= lastPrice) {
            return sellTax; // 价格未跌，使用基础税率
        }
        
        uint256 dropBps = (lastPrice - currentPrice) * 10000 / lastPrice;
        
        if (dropBps >= priceDropLevel2) {
            return sellTaxLevel2; // 跌>=10%，50%手续费
        } else if (dropBps >= priceDropLevel1) {
            return sellTaxLevel1; // 跌>=5%，20%手续费
        }
        
        return sellTax; // 基础6%
    }
    
    /**
     * @dev 从底池计算当前TIP价格（1 TIP = x SOL，放大1e18）
     */
    function _getCurrentPrice() internal view returns (uint256) {
        if (pool == address(0)) return 0;
        uint256 tipInPool = balanceOf(pool);
        if (tipInPool == 0) return 0;
        
        // 尝试获取池中SOL数量
        try IERC20(solToken).balanceOf(pool) returns (uint256 solInPool) {
            if (solInPool == 0) return 0;
            return solInPool * 1e18 / tipInPool;
        } catch {
            return 0;
        }
    }
    
    // SOL代币地址（BSC链）
    address public solToken;
    
    function setSolToken(address _sol) external onlyOwnerOrAdmin {
        solToken = _sol;
    }
    
    // ============ 从底池操作 ============
    
    function burnFromPool(uint256 amount) external onlyMining {
        require(pool != address(0), "Pool not set");
        require(balanceOf(pool) >= amount, "Pool balance insufficient");
        
        _transfer(pool, address(0xdead), amount);
        _syncPool();
        
        emit BurnedFromPool(amount);
    }
    
    function distributeFromPool(address to, uint256 amount) external onlyMinter {
        require(pool != address(0), "Pool not set");
        require(balanceOf(pool) >= amount, "Pool balance insufficient");
        require(to != address(0), "Invalid recipient");
        
        _transfer(pool, to, amount);
        _syncPool();
        
        emit DistributedFromPool(to, amount);
    }
    
    function batchDistributeFromPool(
        address[] calldata recipients, 
        uint256[] calldata amounts,
        uint256 burnAmount
    ) external onlyMinter {
        require(pool != address(0), "Pool not set");
        require(recipients.length == amounts.length, "Length mismatch");
        
        if (burnAmount > 0) {
            _transfer(pool, address(0xdead), burnAmount);
        }
        
        for (uint256 i = 0; i < recipients.length; i++) {
            if (amounts[i] > 0) {
                _transfer(pool, recipients[i], amounts[i]);
            }
        }
        
        _syncPool();
        emit BurnedFromPool(burnAmount);
    }
    
    function _syncPool() internal {
        if (pool != address(0)) {
            (bool success, ) = pool.call(abi.encodeWithSignature("sync()"));
            success; // 不强制要求sync成功
        }
    }
    
    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
        emit Minted(to, amount);
    }
    
    // ============ 转账逻辑（含买卖税 + LP黑名单 + 动态手续费）============
    
    function transfer(address to, uint256 value) public override returns (bool) {
        require(!isBlacklisted[msg.sender], "From blacklisted");
        require(!isBlacklisted[to], "To blacklisted");
        
        // 卖出：用户转TIP到底池（非owner/mining/白名单）
        if (pool != address(0) && to == pool && msg.sender != owner() && msg.sender != miningContract && !isExempt[msg.sender]) {
            _sellTax(msg.sender, value);
            return true;
        }
        
        // 买入：底池转TIP给用户（非owner/mining/白名单接收者）
        if (pool != address(0) && msg.sender == pool && to != owner() && to != miningContract && !isExempt[to]) {
            _buyTax(msg.sender, to, value);
            return true;
        }
        
        // LP黑名单检查：禁止向LP黑名单地址转出（防止直接移除LP），买卖已在上面处理
        require(!isLpBlacklist[to] || isExempt[msg.sender], "LP removal blocked");
        
        // 普通转账（含白名单免税）
        return super.transfer(to, value);
    }
    
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        require(!isBlacklisted[from], "From blacklisted");
        require(!isBlacklisted[to], "To blacklisted");
        
        // 卖出：用户转TIP到底池（非owner/mining/白名单）
        if (pool != address(0) && to == pool && from != owner() && from != miningContract && !isExempt[from]) {
            _spendAllowance(from, msg.sender, value);
            _sellTax(from, value);
            return true;
        }
        
        // 买入：底池转TIP给用户（非owner/mining/白名单接收者）
        if (pool != address(0) && from == pool && to != owner() && to != miningContract && !isExempt[to]) {
            _spendAllowance(from, msg.sender, value);
            _buyTax(from, to, value);
            return true;
        }
        
        // LP黑名单检查
        require(!isLpBlacklist[to] || isExempt[from], "LP removal blocked");
        
        // 普通转账（含白名单免税）
        return super.transferFrom(from, to, value);
    }
    
    /**
     * @dev 卖出税 - 动态手续费 + 销毁94%
     */
    function _sellTax(address from, uint256 value) internal {
        // 获取动态卖出税率
        uint256 currentSellTax = getDynamicSellTax();
        uint256 tax = value * currentSellTax / 10000;
        uint256 toPool = value - tax;
        
        // 1. 扣手续费
        if (tax > 0) {
            uint256 stakeShare = tax / 2;  // 50% 给单币质押用户
            uint256 feeShare = tax - stakeShare;  // 50% 给手续费地址
            
            if (stakeShare > 0 && stakeCoreContract != address(0)) {
                _transfer(from, stakeCoreContract, stakeShare);
                (bool success, ) = stakeCoreContract.call(
                    abi.encodeWithSignature("distributeSellFee(uint256)", stakeShare)
                );
                success;
            }
            
            if (feeShare > 0 && sellFeeReceiver != address(0)) {
                _transfer(from, sellFeeReceiver, feeShare);
            }
        }
        
        // 2. 剩余部分进入底池
        _transfer(from, pool, toPool);
        
        // 3. 更新价格（卖出后底池SOL减少，TIP增加，价格下降）
        _updatePriceAfterSell(toPool);
        
        // 4. 从底池销毁94%（流通量>1%时执行）
        uint256 circulating = totalSupply() - blacklistBalances - balanceOf(address(0xdead));
        bool shouldBurn = circulating > totalSupply() / 100;
        
        if (shouldBurn) {
            uint256 _burnFromPool = toPool * 9400 / 10000;
            if (_burnFromPool > 0) {
                _burn(pool, _burnFromPool);
                emit SellBurned(from, _burnFromPool, toPool - _burnFromPool);
            }
        }
    }
    
    /**
     * @dev 卖出后更新价格记录
     */
    function _updatePriceAfterSell(uint256 /* tipToPool */) internal {
        uint256 newPrice = _getCurrentPrice();
        if (newPrice > 0) {
            if (priceInitialized) {
                emit PriceUpdated(lastPrice, newPrice, getDynamicSellTax());
            }
            lastPrice = newPrice;
            priceInitialized = true;
        }
    }
    
    /**
     * @dev 买入税 - TIP只能卖不能买，买入90%销毁
     */
    function _buyTax(address from, address to, uint256 value) internal {
        uint256 burnAmount = value * buyBurnRate / 10000;  // 90% 销毁
        uint256 feeAmount = value * buyFeeRate / 10000;    // 6% 手续费
        uint256 userAmount = value - burnAmount - feeAmount;  // 4% 给用户
        
        if (burnAmount > 0) {
            _burn(from, burnAmount);
        }
        
        if (feeAmount > 0 && taxReceiver != address(0)) {
            _transfer(from, taxReceiver, feeAmount);
        }
        
        if (userAmount > 0) {
            _transfer(from, to, userAmount);
        }
        
        emit BuyBurned(to, burnAmount, feeAmount, userAmount);
    }
    
    // ============ 其他功能 ============
    
    /**
     * @dev 管理员从底池销毁（含权限检查）
     */
    function burnFromPoolAdmin(uint256 _amount) external {
        require(msg.sender == owner() || msg.sender == adminContract || minters[msg.sender], "!auth");
        require(pool != address(0), "No pool");
        uint256 bal = balanceOf(pool);
        require(_amount <= bal, "Exceeds pool balance");
        _burn(pool, _amount);
        emit BurnedFromPool(_amount);
    }
    
    function poolBalance() external view returns (uint256) {
        return balanceOf(pool);
    }
    
    function setPair(address _pair, bool _status) external onlyOwnerOrAdmin {
        if (_status) {
            pool = _pair;
            poolInitialized = true;
            isLpBlacklist[_pair] = true;
            emit PoolSet(_pair);
        } else {
            if (pool == _pair) {
                pool = address(0);
                poolInitialized = false;
            }
            isExempt[_pair] = false;
            isLpBlacklist[_pair] = false;
        }
    }
    
    function setSellFeeRate(uint256 _rate) external onlyOwnerOrAdmin {
        require(_rate >= 6 && _rate <= 80, "Rate out of range");
        sellTax = _rate * 100;
    }
    
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwnerOrAdmin {
        if (token == address(0)) {
            payable(to).transfer(amount);
        } else {
            IERC20(token).transfer(to, amount);
        }
    }
    
    receive() external payable {}
}

// IERC20已通过import "@openzeppelin/contracts/token/ERC20/ERC20.sol"引入
