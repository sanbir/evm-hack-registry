// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../interfaces/IUniswapV2Router02.sol";
import "../interfaces/IUniswapV2Pair.sol";
import "../interfaces/IBYToken.sol";
import "../interfaces/IBYTaxDistributor.sol";
import "../interfaces/IAggregatorV3.sol";
import "../libraries/SwapHelper.sol";

/**
 * @title BYToken
 * @notice BY 主生态代币，包含交易门禁、卖出税、自动燃烧、价格读取和池子回收能力。
 * @dev 普通钱包转账不扣税；开启交易后向 AMM 池子卖出会按盈利部分收 30% 税费并立即换成 BNB 分发。
 *
 * 交易规则：
 * 1. tradingEnabled 前，普通 Pancake 买入会被拦截；协议免税地址可执行必要的流动性和内部操作。
 * 2. 开启交易后，普通用户卖出 BY 只对盈利部分收 30% 税，合约内部换成 BNB 后交给 BYTaxDistributor。
 * 3. 协议地址卖出、流动性移除和内部结算地址走 taxExempt，避免利息/赎回/节点流程被卖税打断。
 * 4. 自动燃烧按部署参数累计周期执行，优先烧合约余额；余额不足时可从池子烧并 sync。
 * 5. 价格读取依赖 Chainlink BNB/USD，并使用 oracleMaxDelay 防止过期价格参与计算。
 */
contract BYToken is
    ERC20,
    ERC20Permit,
    AccessControl,
    ReentrancyGuard,
    IBYToken
{
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE"); // 预留铸造角色。
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE"); // 手动销毁角色。
    bytes32 public constant RECYCLE_ROLE = keccak256("RECYCLE_ROLE"); // 从池子回收 BY 的角色。

    uint256 public constant MAX_SUPPLY = 6_780_000 * 1e18; // BY 总量。
    uint256 public constant BURN_DENOMINATOR = 10000; // 燃烧比例分母。
    uint256 public constant STOP_BURN_SUPPLY = 700_000 * 1e18; // 自动燃烧停止供应量。
    uint256 public constant TAX_RATE = 3000; // 卖出税 30%。
    uint256 public constant TAX_DENOMINATOR = 10000; // 税率分母。
    uint256 public immutable TRADING_ENABLE_BNB_THRESHOLD; // 自动开启交易所需池子 BNB 储备。
    uint256 public immutable BURN_INTERVAL; // 自动燃烧周期，主网/测试网部署参数不同。
    uint256 public immutable DAILY_BURN_RATE; // 每周期燃烧率。
    uint256 public constant MIN_ORACLE_MAX_DELAY = 5 minutes; // 预言机最大延迟下限。
    uint256 public constant MAX_ORACLE_MAX_DELAY = 24 hours; // 预言机最大延迟上限。
    uint256 public oracleMaxDelay = 1 hours; // Chainlink 价格最大允许过期时间。

    AggregatorV3Interface public priceFeedBNB; // BNB/USD Chainlink 价格源。
    address public pool; // BY/BNB Pair。
    address public router; // Pancake Router。
    address public taxDistributor; // 卖税 BNB 分发器。

    bool public tradingEnabled = false; // 普通 Pancake 买卖开关。
    uint256 public lastBurnTimestamp; // 最近一次自动燃烧结算时间。
    mapping(address => bool) public taxExempt; // 协议地址免税/交易门禁白名单。
    mapping(address => uint256) public costBasisUSDT; // 用户当前持仓成本，USDT 18 位精度。
    mapping(address => uint256) public costBasisAmount; // 与成本对应的用户持仓数量。
    uint256 public defaultCostPriceUSDT = 1e18; // 无买入记录时使用的默认成本价，USDT 18 位精度。

    event AutoBurn(uint256 amount, uint256 currentSupply);
    event TaxExecuted(address indexed from, uint256 tax, uint256 net);
    event SellBurned(address indexed from, uint256 amount);
    event SellTaxDistributed(
        address indexed from,
        address indexed distributor,
        uint256 tokenTax,
        uint256 bnbAmount
    );
    event TradingEnabled();
    event TaxExemptUpdated(address indexed account, bool exempt);
    event TaxDistributorUpdated(address indexed distributor);
    event OracleMaxDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event DefaultCostPriceUpdated(uint256 oldPrice, uint256 newPrice);

    constructor(
        address _priceFeedBNB,
        address _pool,
        address _router,
        uint256 _tradingEnableBnbThreshold,
        uint256 _burnInterval,
        uint256 _burnRate
    ) ERC20("BY", "BY") ERC20Permit("BY") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(BURNER_ROLE, msg.sender);

        require(_priceFeedBNB != address(0), "PriceFeed cannot be zero");
        require(_pool != address(0), "Pool cannot be zero");
        require(_router != address(0), "Router cannot be zero");
        require(_tradingEnableBnbThreshold > 0, "Invalid trading threshold");
        require(_burnInterval > 0, "Invalid burn interval");
        require(
            _burnRate > 0 && _burnRate <= BURN_DENOMINATOR,
            "Invalid burn rate"
        );

        priceFeedBNB = AggregatorV3Interface(_priceFeedBNB);
        pool = _pool;
        router = _router;
        TRADING_ENABLE_BNB_THRESHOLD = _tradingEnableBnbThreshold;
        BURN_INTERVAL = _burnInterval;
        DAILY_BURN_RATE = _burnRate;
        lastBurnTimestamp = block.timestamp;

        _mint(address(this), MAX_SUPPLY);
    }

    /**
     * @notice 读取 BNB/USD 价格，并校验价格没有过期。
     */
    function getBNBPrice() public view returns (uint256) {
        (, int price, , uint256 updatedAt, ) = priceFeedBNB.latestRoundData();
        require(price > 0 && updatedAt > 0, "Invalid price");
        require(
            block.timestamp - updatedAt <= oracleMaxDelay,
            "Stale oracle price"
        );
        return uint256(price);
    }

    /**
     * @notice 根据 BY/BNB 池子储备和 BNB/USD 预言机计算 BY 的 USD 价格。
     */
    function getPrice() public view returns (uint256) {
        if (pool == address(0) || router == address(0)) return 0;
        IUniswapV2Pair pair = IUniswapV2Pair(pool);
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        require(reserve0 > 0 && reserve1 > 0, "Invalid Reserves");
        uint256 priceInBNB = _priceInBNB(pair, reserve0, reserve1);
        uint256 bnbPriceUSD = getBNBPrice(); // 8 decimals
        uint256 bnbPriceUSD18 = bnbPriceUSD * 1e10; // convert to 18 decimals
        return (priceInBNB * bnbPriceUSD18) / 1e18;
    }

    /**
     * @notice 根据 Pair token0/token1 顺序计算 1 BY 对应多少 BNB。
     */
    function _priceInBNB(
        IUniswapV2Pair pair,
        uint112 reserve0,
        uint112 reserve1
    ) internal view returns (uint256) {
        address wbnb = IUniswapV2Router02(router).WETH();
        if (pair.token0() == wbnb) {
            return (uint256(reserve0) * 1e18) / uint256(reserve1);
        }
        return (uint256(reserve1) * 1e18) / uint256(reserve0);
    }

    /**
     * @notice 从 Pair 储备中取出 BNB 一侧的储备量。
     */
    function _poolBNBReserve(
        IUniswapV2Pair pair,
        uint112 reserve0,
        uint112 reserve1
    ) internal view returns (uint256) {
        address wbnb = IUniswapV2Router02(router).WETH();
        return pair.token0() == wbnb ? reserve0 : reserve1;
    }

    /**
     * @notice 自动燃烧逻辑，支持按错过周期线性累计，最多一次结算 7 个周期。
     * @dev allowPoolBurn=false 时只烧合约自身余额，避免 AMM 买卖/加减池过程中触碰 Pair。
     */
    function _autoBurn(bool allowPoolBurn) internal {
        if (totalSupply() <= STOP_BURN_SUPPLY) return;
        uint256 intervalsPassed = (block.timestamp - lastBurnTimestamp) /
            BURN_INTERVAL;
        if (intervalsPassed == 0) return;
        if (intervalsPassed > 7) intervalsPassed = 7;

        uint256 burnRate = DAILY_BURN_RATE * intervalsPassed;
        if (burnRate > BURN_DENOMINATOR) burnRate = BURN_DENOMINATOR;
        uint256 burnAmount = (totalSupply() * burnRate) / BURN_DENOMINATOR;
        uint256 maxBurnToStop = totalSupply() - STOP_BURN_SUPPLY;
        if (burnAmount > maxBurnToStop) burnAmount = maxBurnToStop;
        if (burnAmount == 0) return;

        uint256 contractBalance = balanceOf(address(this));
        uint256 fromContract = burnAmount > contractBalance
            ? contractBalance
            : burnAmount;
        uint256 remaining = burnAmount - fromContract;
        if (remaining > 0) {
            if (!allowPoolBurn) return;
            if (balanceOf(pool) < remaining) return;
        }

        if (fromContract > 0) {
            _burn(address(this), fromContract);
        }
        if (remaining > 0) {
            _burn(pool, remaining);
            IUniswapV2Pair(pool).sync();
        }

        lastBurnTimestamp += intervalsPassed * BURN_INTERVAL;
        if (lastBurnTimestamp > block.timestamp)
            lastBurnTimestamp = block.timestamp;
        emit AutoBurn(burnAmount, totalSupply());
    }

    /**
     * @notice 公开触发自动燃烧。
     */
    function triggerAutoBurn() external {
        _autoBurn(true);
    }

    /**
     * @notice 当池子 BNB 储备达到阈值时自动开启交易。
     */
    function _checkAndEnableTrading() internal {
        if (!tradingEnabled && pool != address(0) && router != address(0)) {
            IUniswapV2Pair pair = IUniswapV2Pair(pool);
            (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
            if (reserve0 == 0 || reserve1 == 0) return;
            uint256 bnbReserve = _poolBNBReserve(pair, reserve0, reserve1);
            if (bnbReserve >= TRADING_ENABLE_BNB_THRESHOLD) {
                tradingEnabled = true;
                emit TradingEnabled();
            }
        }
    }

    /**
     * @notice BY 转账核心逻辑：交易门禁、成本记录、盈利税换 BNB 和净额入池。
     */
    function _transferWithTax(
        address from,
        address to,
        uint256 amount
    ) internal {
        bool isLiquidityRemovalToRouter = from == pool && to == router;
        if (isLiquidityRemovalToRouter) {
            super._transfer(from, to, amount);
            return;
        }
        _checkAndEnableTrading();
        bool isAmmBuy = from == pool;
        bool isAmmSell = to == pool || to == router;
        if (
            !tradingEnabled &&
            (isAmmBuy || isAmmSell) &&
            !taxExempt[from] &&
            !taxExempt[to] &&
            from != address(this)
        ) {
            revert("Trading not enabled");
        }
        bool isSell = isAmmSell && tradingEnabled;
        bool isExcluded = (from == address(0) ||
            to == address(0) ||
            from == address(this) ||
            taxExempt[from]);

        if (isExcluded || amount == 0 || !isSell) {
            super._transfer(from, to, amount);
            if (!isExcluded && isAmmBuy) {
                _addCostBasis(to, amount, getPrice());
            } else if (
                !isExcluded &&
                !isAmmBuy &&
                !isAmmSell &&
                from != address(0) &&
                to != address(0)
            ) {
                _moveCostBasis(from, to, amount);
            }
            return;
        }

        uint256 sellValueUSDT = _expectedSellValueUSDT(amount);
        uint256 tax = _profitTaxTokenAmount(from, amount, sellValueUSDT);
        uint256 net = amount - tax;

        _decreaseCostBasis(from, amount);

        if (tax > 0) {
            require(taxDistributor != address(0), "Tax distributor not set");
            super._transfer(from, address(this), tax);
            uint256 bnbReceived = SwapHelper.swapTokenToBNB(
                IERC20(address(this)),
                IUniswapV2Router02(router),
                tax
            );
            if (bnbReceived > 0) {
                IBYTaxDistributor(taxDistributor).distributeTax{
                    value: bnbReceived
                }(address(this), bnbReceived, from);
            }
            emit SellTaxDistributed(from, taxDistributor, tax, bnbReceived);
        }

        super._transfer(from, to, net);
        emit TaxExecuted(from, tax, net);
    }

    /**
     * @notice 按当前价记录 AMM 买入成本。
     */
    function _addCostBasis(
        address user,
        uint256 amount,
        uint256 priceUSDT
    ) internal {
        if (user == address(0) || amount == 0 || priceUSDT == 0) return;
        _addCostBasisValue(user, amount, (amount * priceUSDT) / 1e18);
    }

    /**
     * @notice 直接按 USDT 成本值记录持仓成本。
     */
    function _addCostBasisValue(
        address user,
        uint256 amount,
        uint256 costUSDT
    ) internal {
        if (user == address(0) || amount == 0 || costUSDT == 0) return;
        costBasisAmount[user] += amount;
        costBasisUSDT[user] += costUSDT;
    }

    /**
     * @notice 普通转账时按比例转移成本，避免转账绕过盈利税。
     */
    function _moveCostBasis(address from, address to, uint256 amount) internal {
        if (from == address(0) || to == address(0) || amount == 0) return;
        (uint256 cost, uint256 trackedAmount) = _consumeCostPreview(
            from,
            amount
        );
        if (trackedAmount == 0 && cost == 0) return;
        _decreaseCostBasis(from, amount);
        costBasisAmount[to] += amount;
        costBasisUSDT[to] += cost;
    }

    /**
     * @notice 预览某个数量对应的成本；无记录部分按默认成本价。
     */
    function _consumeCostPreview(
        address user,
        uint256 amount
    ) internal view returns (uint256 cost, uint256 trackedAmount) {
        uint256 tracked = costBasisAmount[user];
        uint256 trackedCost = costBasisUSDT[user];
        if (tracked > 0 && trackedCost > 0) {
            trackedAmount = amount < tracked ? amount : tracked;
            cost = (trackedCost * trackedAmount) / tracked;
        }
        if (amount > trackedAmount && defaultCostPriceUSDT > 0) {
            cost += ((amount - trackedAmount) * defaultCostPriceUSDT) / 1e18;
        }
    }

    /**
     * @notice 从用户成本账本中扣除已卖出或已转出的数量。
     */
    function _decreaseCostBasis(address user, uint256 amount) internal {
        uint256 tracked = costBasisAmount[user];
        if (tracked == 0 || amount == 0) return;
        if (amount >= tracked) {
            delete costBasisAmount[user];
            delete costBasisUSDT[user];
            return;
        }
        uint256 cost = (costBasisUSDT[user] * amount) / tracked;
        costBasisAmount[user] = tracked - amount;
        costBasisUSDT[user] -= cost;
    }

    /**
     * @notice 按 Router 预估卖出所得 BNB，并换算成 USDT 卖出价值。
     */
    function _expectedSellValueUSDT(
        uint256 amount
    ) internal view returns (uint256) {
        if (amount == 0) return 0;
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = IUniswapV2Router02(router).WETH();
        uint256 bnbOut = IUniswapV2Router02(router).getAmountsOut(
            amount,
            path
        )[1];
        return (bnbOut * getBNBPrice()) / 1e8;
    }

    /**
     * @notice 根据盈利部分折算本次应扣的 token 税。
     */
    function _profitTaxTokenAmount(
        address seller,
        uint256 amount,
        uint256 sellValueUSDT
    ) internal view returns (uint256) {
        if (amount == 0 || sellValueUSDT == 0) return 0;
        (uint256 cost, ) = _consumeCostPreview(seller, amount);
        if (sellValueUSDT <= cost) return 0;
        uint256 profitTaxValue = ((sellValueUSDT - cost) * TAX_RATE) /
            TAX_DENOMINATOR;
        uint256 taxToken = (profitTaxValue * amount) / sellValueUSDT;
        return taxToken > amount ? amount : taxToken;
    }

    /**
     * @notice 普通转账入口，先尝试自动燃烧再执行税费逻辑。
     */
    function transfer(
        address to,
        uint256 amount
    ) public override(ERC20, IERC20) returns (bool) {
        _autoBurn(_canAutoBurnPool(to));
        _transferWithTax(msg.sender, to, amount);
        return true;
    }

    /**
     * @notice 授权转账入口，同样执行自动燃烧和税费逻辑。
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override(ERC20, IERC20) returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _autoBurn(_canAutoBurnPool(to));
        _transferWithTax(from, to, amount);
        return true;
    }

    /**
     * @notice 判断本次转账是否允许从池子燃烧。
     * @dev AMM 买卖/移除流动性相关路径不允许池子燃烧，避免 Pair 锁定期间失败。
     */
    function _canAutoBurnPool(address to) internal view returns (bool) {
        return msg.sender != pool && to != pool && to != router;
    }

    /**
     * @notice 管理员手动开启交易。
     */
    function enableTrading() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!tradingEnabled, "Already enabled");
        tradingEnabled = true;
        emit TradingEnabled();
    }

    /**
     * @notice 设置 BY/BNB Pair 地址。
     */
    function setPool(address _pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_pool != address(0), "Pool cannot be zero");
        pool = _pool;
    }

    /**
     * @notice 设置 Pancake Router。
     */
    function setRouter(address _router) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_router != address(0), "Router cannot be zero");
        router = _router;
    }

    /**
     * @notice 设置 BNB/USD 预言机。
     */
    function setPriceFeedBNB(
        address _priceFeedBNB
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_priceFeedBNB != address(0), "PriceFeed cannot be zero");
        priceFeedBNB = AggregatorV3Interface(_priceFeedBNB);
    }

    /**
     * @notice 设置预言机最大允许过期时间。
     */
    function setOracleMaxDelay(
        uint256 _newDelay
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(
            _newDelay >= MIN_ORACLE_MAX_DELAY &&
                _newDelay <= MAX_ORACLE_MAX_DELAY,
            "Invalid oracle delay"
        );
        uint256 oldDelay = oracleMaxDelay;
        oracleMaxDelay = _newDelay;
        emit OracleMaxDelayUpdated(oldDelay, _newDelay);
    }

    /**
     * @notice 设置无买入记录地址的默认成本价，USDT 18 位精度。
     */
    function setDefaultCostPriceUSDT(
        uint256 _price
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 old = defaultCostPriceUSDT;
        defaultCostPriceUSDT = _price;
        emit DefaultCostPriceUpdated(old, _price);
    }

    /**
     * @notice 设置免税地址，常用于协议合约、加池地址和部署运维地址。
     */
    function setTaxExempt(
        address account,
        bool exempt
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "Account cannot be zero");
        taxExempt[account] = exempt;
        emit TaxExemptUpdated(account, exempt);
    }

    /**
     * @notice 设置卖税分发器，并自动把分发器加入免税名单。
     */
    function setTaxDistributor(
        address _taxDistributor
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_taxDistributor != address(0), "Distributor cannot be zero");
        taxDistributor = _taxDistributor;
        taxExempt[_taxDistributor] = true;
        emit TaxDistributorUpdated(_taxDistributor);
        emit TaxExemptUpdated(_taxDistributor, true);
    }

    /**
     * @notice 管理员从代币合约自身分发 BY，用于部署初始分配。
     */
    function distribute(
        address to,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(
            to != address(0) &&
                amount > 0 &&
                balanceOf(address(this)) >= amount,
            "Invalid"
        );
        super._transfer(address(this), to, amount);
    }

    /**
     * @notice 从流动性池回收最多 1/3 BY 到指定地址。
     * @dev 该函数会改变池子储备并 sync，属于高权限敏感操作。
     */
    function recycle(
        address to,
        uint256 amount
    ) external onlyRole(RECYCLE_ROLE) {
        require(pool != address(0), "Pool not set");
        uint256 poolBalance = IERC20(address(this)).balanceOf(pool);
        uint256 maxRecycle = poolBalance / 3;
        uint256 recycleAmount = amount > maxRecycle ? maxRecycle : amount;
        if (recycleAmount == 0) return;
        super._transfer(pool, to, recycleAmount);
        IUniswapV2Pair(pool).sync();
    }

    /**
     * @notice BURNER_ROLE 销毁自己持有的 BY。
     */
    function burn(uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(msg.sender, amount);
    }

    receive() external payable {}
}
