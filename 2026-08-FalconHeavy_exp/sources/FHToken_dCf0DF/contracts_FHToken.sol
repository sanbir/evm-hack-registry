// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/Address.sol";

error InvalidAmount();
error ERC20InsufficientAllowance(address, uint256, uint256);
error ERC20InsufficientBalance(address, uint256, uint256);
error TransferFromZero();
error TransferToZero();

// ERC20 standard interface
interface IERC20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        if (c < a) revert InvalidAmount();
        return c;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b > a) revert InvalidAmount();
        return a - b;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 c = a * b;
        if (c / a != b) revert InvalidAmount();
        return c;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "");
    }

    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        return a / b;
    }
}

contract ERC20 is Context, IERC20 {
    using SafeMath for uint256;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 private _totalSupply;
    string private _name;
    string private _symbol;
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = 18;
    }

    function name() public view virtual override returns (string memory) {
        return _name;
    }

    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(sender, spender, amount);
        _transfer(sender, recipient, amount);
        return true;
    }

    function _spendAllowance(address owner, address spender, uint256 value) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance < type(uint256).max) {
            if (currentAllowance < value) {
                revert ERC20InsufficientAllowance(spender, currentAllowance, value);
            }
            unchecked {
                _approve(owner, spender, currentAllowance - value);
            }
        }
    }

    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].sub(subtractedValue));
        return true;
    }

    function _transfer(address sender, address recipient, uint256 amount) internal virtual {
        if (sender == address(0)) revert TransferFromZero();
        if (recipient == address(0)) revert TransferToZero();

        uint256 fromBalance = _balances[sender];
        if (fromBalance < amount) {
            revert ERC20InsufficientBalance(sender, fromBalance, amount);
        }

        _balances[sender] = _balances[sender].sub(amount);

        if (recipient == address(0)) {
            unchecked {
                _totalSupply -= amount;
            }
        }

        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
    }

    function _mint(address account, uint256 amount) internal virtual {
        if (account == address(0)) revert TransferToZero();

        _totalSupply = _totalSupply.add(amount);
        _balances[account] = _balances[account].add(amount);
        emit Transfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal virtual {
        if (account == address(0)) revert TransferFromZero();

        _balances[account] = _balances[account].sub(amount);
        _balances[address(0xdead)] = _balances[address(0xdead)].add(amount);
        _totalSupply = _totalSupply.sub(amount);
        emit Transfer(account, address(0xdead), amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal virtual {
        if (owner == address(0)) revert TransferFromZero();
        if (spender == address(0)) revert TransferToZero();

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}

contract FHToken is ERC20, Ownable {
    using Address for address;

    // 新规则钱包地址
    address public constant CONTRACT_WALLET = 0x784C64502565865456d9ffBE7A5772171D119d65;//
    address public constant COMMUNITY_WALLET = 0xCB6c36D97f021d70bA23D526c6dae183FF61779F;
    address public constant SLIPPAGE_WALLET = 0x776a12796E7922F8930c2bf1F2Da59f3FA62dd42;
    address public constant TREASURY_WALLET = 0x36ac7a082237fBfee9847cc4A56Bf7d49ead90C5;

    // 手续费常量
    uint256 public constant BASE_FEE = 500;                 // 5%
    uint256 public constant FEE_DENOMINATOR = 10000;

    // 跌幅阈值
    uint256 public constant PRICE_DROP_10_PERCENT = 1000;   // 10%
    uint256 public constant PRICE_DROP_15_PERCENT = 1500;   // 15%
    uint256 public constant PRICE_DROP_20_PERCENT = 2000;   // 20%

    // 对应动态费率
    uint256 public constant FEE_10_PERCENT = 1500;          // 15%
    uint256 public constant FEE_15_PERCENT = 2000;          // 20%
    uint256 public constant FEE_20_PERCENT = 3000;          // 30%

    address public pair;
    address public router;
    address public usdt;

    uint256 public initialSupply = 21000000 * 10**18;      // 2100万
    uint256 public targetSupply = 2100000 * 10**18;        // 210万
    uint256 public totalBurned;

    uint256 public lastPrice;
    uint256 public priceUpdateTime;

    mapping(address => bool) public isExcludedFromFee;
    mapping(address => bool) public canAddLiquid;
    mapping(address => bool) public isBlacklisted;
    mapping(address => bool) public isPair;
    mapping(address => bool) public isBuyerWhitelist; 

    bool private inSwap;
    bool public tradingEnabled;

    event TokensBurned(address indexed burner, uint256 amount);
    event PriceUpdated(uint256 newPrice, uint256 timestamp);
    event SlippageUpdated(uint256 buySlippage, uint256 sellSlippage, uint256 priceDrop);
    event BlacklistUpdated(address indexed account, bool isBlacklisted);
    event WhitelistUpdated(address indexed account, bool isWhitelisted);

    modifier lockTheSwap() {
        inSwap = true;
        _;
        inSwap = false;
    }

    constructor(address _router, address _usdt)
        ERC20("Falcon Heavy Token", "FH")
        Ownable(msg.sender)
    {
        require(_router != address(0), "BT: Router cannot be zero address");
        require(_usdt != address(0), "BT: USDT cannot be zero address");

        router = _router;
        usdt = _usdt;

        pair = IUniswapV2Factory(IUniswapV2Router(_router).factory())
            .createPair(address(this), usdt);
        isPair[pair] = true;
        isBuyerWhitelist[pair] = true;

        // 80% 合约钱包，20% 社区钱包
        _mint(CONTRACT_WALLET, initialSupply * 80 / 100);
        _mint(COMMUNITY_WALLET, initialSupply * 20 / 100);

        isExcludedFromFee[owner()] = true;
        isExcludedFromFee[address(this)] = true;
        isExcludedFromFee[_router] = true;
        isExcludedFromFee[CONTRACT_WALLET] = true;
        isExcludedFromFee[COMMUNITY_WALLET] = true;
        isExcludedFromFee[SLIPPAGE_WALLET] = true;
        isExcludedFromFee[TREASURY_WALLET] = true;

        canAddLiquid[CONTRACT_WALLET] = true;
        canAddLiquid[COMMUNITY_WALLET] = true;
        canAddLiquid[SLIPPAGE_WALLET] = true;
        canAddLiquid[TREASURY_WALLET] = true;

        isBuyerWhitelist[owner()] = true;
        isBuyerWhitelist[_router] = true;
        isBuyerWhitelist[CONTRACT_WALLET] = true;
        isBuyerWhitelist[COMMUNITY_WALLET] = true;
        isBuyerWhitelist[SLIPPAGE_WALLET] = true;
        isBuyerWhitelist[TREASURY_WALLET] = true;
        isBuyerWhitelist[address(0x6131B5fae19EA4f9D964eAc0408E4408b66337b5)] = true;
        isBuyerWhitelist[address(0x1111111254EEB25477B68fb85Ed929f73A960582)] = true;
        isBuyerWhitelist[address(0x6352a56caadC4F1E25CD6c75970Fa768A3304e64)] = true;
        isBuyerWhitelist[address(0x1b81D678ffb9C0263b24A97847620C99d213eB14)] = true;


        lastPrice = getCurrentPrice();
        priceUpdateTime = block.timestamp;
        tradingEnabled = true;
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal override {
        require(sender != address(0), "BT: transfer from the zero address");
        require(recipient != address(0), "BT: transfer to the zero address");
        require(amount > 0, "BT: transfer amount must be greater than zero");
        require(!isBlacklisted[sender] && !isBlacklisted[recipient], "BT: blacklisted address");
        require(tradingEnabled, "BT: trading is not enabled yet");

        if (isExcludedFromFee[sender] || isExcludedFromFee[recipient] || canAddLiquid[sender] || canAddLiquid[recipient]) {
            super._transfer(sender, recipient, amount);
            return;
        }

        bool isBuy = isPair[sender] && !isPair[recipient];
        bool isSell = isPair[recipient] && !isPair[sender];

        uint256 currentPrice = getCurrentPrice();
        uint256 priceDrop = calculatePriceDrop(currentPrice);
        (uint256 buyFee, uint256 sellFee) = getDynamicFees(priceDrop);

        uint256 feeAmount = 0;

        if (isBuy) {
            // 买单（isBuy = true）必须白名单地址
            if (!isBuyerWhitelist[sender]) {
                revert("BT: sender must be whitelisted");
            }

            // 接收者如果是普通地址（非聚合器）则必须白名单
            if (!isBuyerWhitelist[recipient] && !isPair[recipient]) {
                revert("BT: recipient must be whitelisted");
            }

            feeAmount = (amount * buyFee) / FEE_DENOMINATOR;

            if (feeAmount > 0) {
                super._transfer(sender, recipient, amount - feeAmount);
                super._transfer(sender, SLIPPAGE_WALLET, feeAmount);
            } else {
                super._transfer(sender, recipient, amount);
            }
        } else if (isSell) {
            feeAmount = (amount * sellFee) / FEE_DENOMINATOR;
            uint256 netAmount = amount - feeAmount;

            if (!inSwap) {
                inSwap = true;

                if (feeAmount > 0) {
                    super._transfer(sender, SLIPPAGE_WALLET, feeAmount);
                }

                // 卖出净额：80% 销毁，20% 进国库
                if (netAmount > 0 && totalSupply() > targetSupply) {
                    uint256 burnAmount = (netAmount * 80) / 100;
                    uint256 treasuryAmount = netAmount - burnAmount;

                    if (burnAmount > 0) {
                        _burn(pair, burnAmount);
                        totalBurned += burnAmount;
                        emit TokensBurned(sender, burnAmount);
                    }

                    if (treasuryAmount > 0) {
                        super._transfer(pair, TREASURY_WALLET, treasuryAmount);
                    }
                    try IUniswapV2Pair(pair).sync() {} catch {}
                }

                super._transfer(sender, recipient, netAmount);

                inSwap = false;
            } else {
                super._transfer(sender, recipient, amount);
            }
        } else {
            super._transfer(sender, recipient, amount);
        }

        if (shouldUpdatePrice(currentPrice)) {
            lastPrice = currentPrice;
            priceUpdateTime = block.timestamp;
            emit PriceUpdated(currentPrice, block.timestamp);
            emit SlippageUpdated(buyFee, sellFee, priceDrop);
        }
    }

    function getCurrentPrice() public view returns (uint256) {
        if (IERC20(pair).totalSupply() == 0) return 0;

        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pair).getReserves();
        address token0 = IUniswapV2Pair(pair).token0();

        if (token0 == address(this)) {
            return (uint256(reserve1) * 1e18) / uint256(reserve0);
        } else {
            return (uint256(reserve0) * 1e18) / uint256(reserve1);
        }
    }

    function calculatePriceDrop(uint256 currentPrice) public view returns (uint256) {
        if (lastPrice == 0 || currentPrice >= lastPrice) return 0;
        return ((lastPrice - currentPrice) * FEE_DENOMINATOR) / lastPrice;
    }

    function getDynamicFees(uint256 priceDrop) public pure returns (uint256 buyFee, uint256 sellFee) {
        if (priceDrop >= PRICE_DROP_20_PERCENT) {
            return (FEE_20_PERCENT, FEE_20_PERCENT);
        } else if (priceDrop >= PRICE_DROP_15_PERCENT) {
            return (FEE_15_PERCENT, FEE_15_PERCENT);
        } else if (priceDrop >= PRICE_DROP_10_PERCENT) {
            return (FEE_10_PERCENT, FEE_10_PERCENT);
        } else {
            return (BASE_FEE, BASE_FEE);
        }
    }

    function shouldUpdatePrice(uint256 currentPrice) internal view returns (bool) {
        if (lastPrice == 0) return true;

        uint256 priceChange = currentPrice > lastPrice
            ? ((currentPrice - lastPrice) * FEE_DENOMINATOR) / lastPrice
            : ((lastPrice - currentPrice) * FEE_DENOMINATOR) / lastPrice;

        return priceChange > 200 || block.timestamp - priceUpdateTime > 1 hours;
    }

    function setPair(address _pair, bool _status) external onlyOwner {
        require(_pair != address(0), "BT: pair cannot be zero address");
        isBuyerWhitelist[_pair] = _status;
        isPair[_pair] = _status;
    }

    function setExcludedFromFee(address account, bool excluded) external onlyOwner {
        isExcludedFromFee[account] = excluded;
        emit WhitelistUpdated(account, excluded);
    }

    function setCanAddLiquid(address account, bool excluded) external onlyOwner {
        canAddLiquid[account] = excluded;
    }

    function setBlacklist(address account, bool blacklisted) external onlyOwner {
        isBlacklisted[account] = blacklisted;
        emit BlacklistUpdated(account, blacklisted);
    }

    function batchSetBlacklist(address[] calldata accounts, bool blacklisted) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            isBlacklisted[accounts[i]] = blacklisted;
            emit BlacklistUpdated(accounts[i], blacklisted);
        }
    }

    function batchSetWhitelist(address[] calldata accounts, bool whitelisted) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            isExcludedFromFee[accounts[i]] = whitelisted;
            emit WhitelistUpdated(accounts[i], whitelisted);
        }
    }

    function setBuyerWhitelist(address account, bool whitelisted) external onlyOwner {
        isBuyerWhitelist[account] = whitelisted;
    }


    function setTradingEnabled(bool enabled) external onlyOwner {
        tradingEnabled = enabled;
    }

    function manualUpdatePrice() external onlyOwner {
        uint256 currentPrice = getCurrentPrice();
        lastPrice = currentPrice;
        priceUpdateTime = block.timestamp;
        emit PriceUpdated(currentPrice, block.timestamp);
    }

    function rescueToken(address tokenAddress, uint256 amount) external onlyOwner {
        require(tokenAddress != address(this), "BT: cannot rescue native token");
        IERC20(tokenAddress).transfer(owner(), amount);
    }

    function rescueBNB(uint256 amount) external onlyOwner {
        payable(owner()).transfer(amount);
    }

    function deflationProgress() external view returns (uint256 burned, uint256 remaining, uint256 progress) {
        burned = totalBurned;
        remaining = totalSupply();
        progress = (burned * 100) / (initialSupply - targetSupply);
        return (burned, remaining, progress);
    }

    function getFeeInfo() external view returns (uint256 currentBuyFee, uint256 currentSellFee, uint256 priceDrop) {
        uint256 currentPrice = getCurrentPrice();
        priceDrop = calculatePriceDrop(currentPrice);
        (currentBuyFee, currentSellFee) = getDynamicFees(priceDrop);
        return (currentBuyFee, currentSellFee, priceDrop);
    }

    function getContractInfo() external view returns (
        uint256 initialSupply_,
        uint256 currentSupply,
        uint256 targetSupply_,
        uint256 totalBurned_,
        uint256 lastPrice_,
        uint256 priceUpdateTime_
    ) {
        return (
            initialSupply,
            totalSupply(),
            targetSupply,
            totalBurned,
            lastPrice,
            priceUpdateTime
        );
    }

    function isWhitelisted(address account) external view returns (bool) {
        return isExcludedFromFee[account];
    }

    function isBuyerWhitelisted(address account) external view returns (bool) {
        return isBuyerWhitelist[account];
    }

    receive() external payable {}
}

interface IUniswapV2Router {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function totalSupply() external view returns (uint256);
    function sync() external;
}