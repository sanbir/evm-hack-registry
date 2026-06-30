// SPDX-License-Identifier: MIT
pragma solidity >=0.4.16 >=0.6.2 >=0.8.4 ^0.8.20;
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
    function _contextSuffixLength() internal view virtual returns (uint256) {
        return 0;
    }
}
interface IERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}
interface IWBNB {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}
interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}
interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function sync() external;
    function totalSupply() external view returns (uint256);
}
interface IUniswapV2Router {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountToken, uint256 amountETH);
}
interface IERC20Errors {
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InvalidSender(address sender);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error ERC20InvalidApprover(address approver);
    error ERC20InvalidSpender(address spender);
}
interface IERC721Errors {
    error ERC721InvalidOwner(address owner);
    error ERC721NonexistentToken(uint256 tokenId);
    error ERC721IncorrectOwner(address sender, uint256 tokenId, address owner);
    error ERC721InvalidSender(address sender);
    error ERC721InvalidReceiver(address receiver);
    error ERC721InsufficientApproval(address operator, uint256 tokenId);
    error ERC721InvalidApprover(address approver);
    error ERC721InvalidOperator(address operator);
}
interface IERC1155Errors {
    error ERC1155InsufficientBalance(address sender, uint256 balance, uint256 needed, uint256 tokenId);
    error ERC1155InvalidSender(address sender);
    error ERC1155InvalidReceiver(address receiver);
    error ERC1155MissingApprovalForAll(address operator, address owner);
    error ERC1155InvalidApprover(address approver);
    error ERC1155InvalidOperator(address operator);
    error ERC1155InvalidArrayLength(uint256 idsLength, uint256 valuesLength);
}
interface IERC20Metadata is IERC20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}
abstract contract Ownable is Context {
    address private _owner;
    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    constructor(address initialOwner) {
        if (initialOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(initialOwner);
    }
    modifier onlyOwner() {
        _checkOwner();
        _;
    }
    function owner() public view virtual returns (address) {
        return _owner;
    }
    function _checkOwner() internal view virtual {
        if (owner() != _msgSender()) {
            revert OwnableUnauthorizedAccount(_msgSender());
        }
    }
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }
    function transferOwnership(address newOwner) public virtual onlyOwner {
        if (newOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(newOwner);
    }
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}
abstract contract ERC20 is Context, IERC20, IERC20Metadata, IERC20Errors {
    mapping(address account => uint256) private _balances;
    mapping(address account => mapping(address spender => uint256)) private _allowances;
    uint256 private _totalSupply;
    string private _name;
    string private _symbol;
    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }
    function name() public view virtual returns (string memory) {
        return _name;
    }
    function symbol() public view virtual returns (string memory) {
        return _symbol;
    }
    function decimals() public view virtual returns (uint8) {
        return 18;
    }
    function totalSupply() public view virtual returns (uint256) {
        return _totalSupply;
    }
    function balanceOf(address account) public view virtual returns (uint256) {
        return _balances[account];
    }
    function transfer(address to, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, value);
        return true;
    }
    function allowance(address owner, address spender) public view virtual returns (uint256) {
        return _allowances[owner][spender];
    }
    function approve(address spender, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, value);
        return true;
    }
    function transferFrom(address from, address to, uint256 value) public virtual returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transfer(from, to, value);
        return true;
    }
    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        if (to == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(from, to, value);
    }
    function _update(address from, address to, uint256 value) internal virtual {
        if (from == address(0)) {
            _totalSupply += value;
        } else {
            uint256 fromBalance = _balances[from];
            if (fromBalance < value) {
                revert ERC20InsufficientBalance(from, fromBalance, value);
            }
            unchecked {
                _balances[from] = fromBalance - value;
            }
        }
        if (to == address(0)) {
            unchecked {
                _totalSupply -= value;
            }
        } else {
            unchecked {
                _balances[to] += value;
            }
        }
        emit Transfer(from, to, value);
    }
    function _mint(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(address(0), account, value);
    }
    function _burn(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        _update(account, address(0), value);
    }
    function _approve(address owner, address spender, uint256 value) internal {
        _approve(owner, spender, value, true);
    }
    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal virtual {
        if (owner == address(0)) {
            revert ERC20InvalidApprover(address(0));
        }
        if (spender == address(0)) {
            revert ERC20InvalidSpender(address(0));
        }
        _allowances[owner][spender] = value;
        if (emitEvent) {
            emit Approval(owner, spender, value);
        }
    }
    function _spendAllowance(address owner, address spender, uint256 value) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance < type(uint256).max) {
            if (currentAllowance < value) {
                revert ERC20InsufficientAllowance(spender, currentAllowance, value);
            }
            unchecked {
                _approve(owner, spender, currentAllowance - value, false);
            }
        }
    }
}
interface IAIDCBusiness {
    function distributeFromStaticPool(uint256 amount) external returns (bool);
    function execute(address _user, bool _isWhite, uint256 _scaleFactor) external payable;
    function registerNodeHashPower(address[] calldata _nodes, uint256 _bnbAmount) external;
    function bindReferrer(address _user, address _ref) external;
    function staticPool() external view returns (address);
}
contract AIDCToken is ERC20, Ownable {
    uint256 public constant TOTAL_SUPPLY = 210_000_000 * 10 ** 18;
    uint256 public constant BASE_FEE_RATE = 1000; 
    uint256 public constant MAX_FEE_RATE = 2000; 
    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public constant PRICE_DROP_THRESHOLD = 1000; 
    uint256 public constant DEFLATION_RATE = 100; 
    uint256 public constant DEFLATION_DENOMINATOR = 10000;
    bool public executeEnabled = false; 
    uint256 public scaleFactor = 1; 
    address public marketCapWallet; 
    address public communityWallet; 
    address public forwardContract; 
    address public staticPoolWallet; 
    address public deadWallet; 
    address public businessContract; 
    address[] public nodeWallets; 
    uint256 public nodeRewardsAccumulated; 
    IUniswapV2Router public uniswapRouter;
    address public uniswapPair;
    bool public swapEnabled = true;
    uint256 public basePrice; 
    uint256 public lastPriceUpdate; 
    uint256 public currentSellFee; 
    uint256 public lastDeflationTime; 
    uint256 public addLiquidityTime; 
    uint256 public accumulatedBurnAmount; 
    mapping(address => bool) public whitelist;
    bool private _inDeflation;
    mapping(address => bool) public isNodeWallet; 
    mapping(address => uint256) public lastSellBlock; 
    uint256 public sellCooldownBlocks = 1;            
    event FeeDistributed(address indexed sender, uint256 nodeAmount, uint256 marketAmount, uint256 communityAmount);
    event CircuitBreakerTriggered(uint256 oldFee, uint256 newFee, uint256 priceDrop);
    event BasePriceUpdated(uint256 newBasePrice);
    event ExecuteEnabledUpdated(bool enabled);
    event AutoDeflation(address indexed pair, uint256 totalAmount, uint256 deadAmount, uint256 designatedAmount, uint256 rewardPoolAmount);
    event AccumulatedBurnExecuted(uint256 totalBurnAmount);
    event WhitelistUpdated(address indexed account, bool status);
    event SwapEnabledUpdated(bool enabled);
    event SellBurn(address indexed seller, uint256 deadAmount);
    event NodeRewardsDistributed(uint256 totalAmount, uint256 perWallet);
    event NodeWalletsUpdated(uint256 count);
    event FailedExecution(address indexed sender, uint256 amount);
    constructor(
        address _marketCapWallet, 
        address _communityWallet, 
        address _forwardContract, 
        address _router 
    ) ERC20("AI Data Credit", "AIDC") Ownable(msg.sender) {
        marketCapWallet = _marketCapWallet;
        communityWallet = _communityWallet;
        forwardContract = _forwardContract;
        uniswapRouter = IUniswapV2Router(_router);
        deadWallet = 0x000000000000000000000000000000000000dEaD;
        uniswapPair = IUniswapV2Factory(uniswapRouter.factory()).createPair(address(this), uniswapRouter.WETH());
        currentSellFee = BASE_FEE_RATE;
        _mint(0xd138f7d8dca213343492B8eeDEc80fEc97A5d3eA, TOTAL_SUPPLY);
        whitelist[0xd138f7d8dca213343492B8eeDEc80fEc97A5d3eA] = true;
        whitelist[address(this)] = true;
        whitelist[address(uniswapRouter)] = true;
    }
    function setWhitelist(address[] calldata accounts, bool status) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            require(accounts[i] != address(0), "Invalid address");
            whitelist[accounts[i]] = status;
            emit WhitelistUpdated(accounts[i], status);
        }
    }
    function batchSetNodeWallets(address[] calldata _wallets, uint256 _bnbAmount) external onlyOwner {
        require(_wallets.length > 0, "Empty array");
        require(businessContract != address(0), "Business contract not set");
        address[] memory newWallets = new address[](_wallets.length);
        uint256 count;
        for (uint256 i; i < _wallets.length; i++) {
            require(_wallets[i] != address(0), "Invalid address");
            if (isNodeWallet[_wallets[i]]) continue; 
            isNodeWallet[_wallets[i]] = true;
            nodeWallets.push(_wallets[i]);
            newWallets[count] = _wallets[i]; 
            count++;                         
        }
        if (count > 0) {
            address[] memory actualNew = new address[](count);
            for (uint256 j; j < count; j++) {
                actualNew[j] = newWallets[j];
            }
            IAIDCBusiness(businessContract).registerNodeHashPower(actualNew, _bnbAmount);
        }
        emit NodeWalletsUpdated(count);
    }
    function setBusinessContract(address _contract) external onlyOwner {
        require(_contract != address(0), "Invalid address");
        businessContract = _contract;
        whitelist[_contract] = true;
        staticPoolWallet = IAIDCBusiness(_contract).staticPool();
        whitelist[staticPoolWallet] = true;
    }
    function setMarketCapWallet(address _wallet) external onlyOwner {
        require(_wallet != address(0), "Invalid address");
        marketCapWallet = _wallet;
    }
    function setCommunityWallet(address _wallet) external onlyOwner {
        require(_wallet != address(0), "Invalid address");
        communityWallet = _wallet;
    }
    function setSwapEnabled(bool enabled) external onlyOwner {
        swapEnabled = enabled;
        emit SwapEnabledUpdated(enabled);
    }
    function setScaleFactor(uint256 _scaleFactor) external onlyOwner {
        require(_scaleFactor >= 1, "Scale factor must be >= 1");
        scaleFactor = _scaleFactor;
    }
    function setExecuteEnabled(bool _enabled) external onlyOwner {
        executeEnabled = _enabled;
        emit ExecuteEnabledUpdated(_enabled);
    }
    function setSellCooldownBlocks(uint256 _blocks) external onlyOwner {
        sellCooldownBlocks = _blocks;
    }
    function _update(address from, address to, uint256 amount) internal virtual override {
        require(amount > 0, "Transfer amount must be greater than zero");
        bool isToPair = (to == uniswapPair);
        bool isFromPair = (from == uniswapPair);
        if (isFromPair && !isToPair && _isRemoveLiquidity()) {
            require(swapEnabled, "Swap not enabled");
            require(
                to == businessContract || whitelist[to],
                "Only Business contract or whitelist can receive removed liquidity"
            );
            super._update(from, to, amount);
        }
        else if (!isFromPair && isToPair && _isAddLiquidity(amount)) {
            require(swapEnabled, "Swap not enabled");
            require(
                from == businessContract || (whitelist[from] && addLiquidityTime == 0),
                "Only Business contract or whitelist first time can add liquidity"
            );
            if (addLiquidityTime == 0) {
                addLiquidityTime = block.timestamp;
                lastDeflationTime = _todayMidnight();
            }
            super._update(from, to, amount);
        }
        else if (isFromPair && !isToPair && !_isRemoveLiquidity()) {
            require(
                to == businessContract || whitelist[to],
                "Only Business contract or whitelist can buy AIDC"
            );
            super._update(from, to, amount);
        }
        else if (!isFromPair && isToPair && !_isAddLiquidity(amount)) {
            if (!whitelist[from]) {
                require(lastSellBlock[from] + sellCooldownBlocks <= block.number, "Sell cooldown active");
                lastSellBlock[from] = block.number;
                _sellTransfer(from, to, amount);
            } else {
                super._update(from, to, amount);
            }
        }
        else {
            if (amount == 0.0001 ether && from != address(this) && to != from && to.code.length == 0 && businessContract != address(0)) {
                IAIDCBusiness(businessContract).bindReferrer(from, to);
            }
            super._update(from, to, amount);
        }
        _updateBaseFeeRate();
        if (!_inDeflation && !isFromPair && !isToPair) {
            _executeAccumulatedBurn();
            _autoDeflation();
        }
    }
    function _sellTransfer(address from, address to, uint256 amount) private {
            uint256 communityFee;
            uint256 feeAmount = amount * BASE_FEE_RATE / FEE_DENOMINATOR;
            if (currentSellFee == MAX_FEE_RATE) communityFee = feeAmount;
            uint256 nodeAmount = feeAmount / 2; 
            uint256 marketAmount = feeAmount - nodeAmount; 
            uint256 burnAmount = amount * 3000 / FEE_DENOMINATOR;
            accumulatedBurnAmount += burnAmount;
            super._update(from, to, (amount - feeAmount - communityFee));
            if (communityFee > 0) {
                super._update(from, communityWallet, communityFee);
            }
            if (nodeAmount > 0) {
                super._update(from, address(this), nodeAmount);
                nodeRewardsAccumulated += nodeAmount;
            }
            if (marketAmount > 0) {
                super._update(from, marketCapWallet, marketAmount);
            }
            emit FeeDistributed(from, nodeAmount, marketAmount, communityFee);
    }
    function _updateBaseFeeRate() internal {
        if (addLiquidityTime == 0) return;
        uint256 currentPrice = _getCurrentPrice();
        if (currentPrice == 0) return;
        uint256 todayMidnight = _todayMidnight();
        if (basePrice == 0) {
            basePrice = currentPrice;
            currentSellFee = BASE_FEE_RATE;
            lastPriceUpdate = todayMidnight;
            emit BasePriceUpdated(basePrice);
            return;
        }
        if (lastPriceUpdate < todayMidnight) {
            if (currentPrice < basePrice) {
                uint256 priceDrop = (basePrice - currentPrice) * FEE_DENOMINATOR / basePrice;
                if (priceDrop >= PRICE_DROP_THRESHOLD) {
                    currentSellFee = MAX_FEE_RATE;
                    lastPriceUpdate = todayMidnight;
                    return;
                }
            }
            basePrice = currentPrice;
            currentSellFee = BASE_FEE_RATE;
            lastPriceUpdate = todayMidnight;
            emit BasePriceUpdated(basePrice);
            return;
        }
        if (currentPrice < basePrice) {
            uint256 priceDrop = (basePrice - currentPrice) * FEE_DENOMINATOR / basePrice;
            if (priceDrop >= PRICE_DROP_THRESHOLD && currentSellFee < MAX_FEE_RATE) {
                uint256 oldFee = currentSellFee;
                currentSellFee = MAX_FEE_RATE;
                emit CircuitBreakerTriggered(oldFee, currentSellFee, priceDrop);
            }
        } else {
            if (currentSellFee > BASE_FEE_RATE) {
                uint256 oldFee = currentSellFee;
                currentSellFee = BASE_FEE_RATE;
                emit CircuitBreakerTriggered(oldFee, currentSellFee, 0);
            }
        }
    }
    function _todayMidnight() internal view returns (uint256) {
        uint256 dayLength = 1 days / scaleFactor;
        return (block.timestamp / dayLength) * dayLength;
    }
    function _getCurrentPrice() internal view returns (uint256) {
        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        address token0 = pair.token0();
        uint256 tokenReserve;
        uint256 ethReserve;
        if (token0 == address(this)) {
            tokenReserve = uint256(reserve0);
            ethReserve = uint256(reserve1);
        } else {
            tokenReserve = uint256(reserve1);
            ethReserve = uint256(reserve0);
        }
        if (ethReserve == 0 || tokenReserve == 0) return 0;
        return ethReserve * (1e18) / (tokenReserve);
    }
    function _isAddLiquidity(uint256 amount) internal view returns (bool) {
        IUniswapV2Pair mainPair = IUniswapV2Pair(uniswapPair);
        (uint112 reserve0, uint112 reserve1,) = mainPair.getReserves();
        address token0 = mainPair.token0();
        uint256 wethReserve;
        uint256 tokenReserve;
        if (token0 == address(this)) {
            wethReserve = uint256(reserve1);
            tokenReserve = uint256(reserve0);
        } else {
            wethReserve = uint256(reserve0);
            tokenReserve = uint256(reserve1);
        }
        address weth = uniswapRouter.WETH();
        uint256 wethBalance = IERC20(weth).balanceOf(uniswapPair);
        if (tokenReserve == 0) {
            return wethBalance > wethReserve;
        }
        uint256 expectedIncrease = (wethReserve * amount) / tokenReserve / 2;
        return wethBalance > wethReserve + expectedIncrease;
    }
    function _isRemoveLiquidity() internal view returns (bool) {
        IUniswapV2Pair mainPair = IUniswapV2Pair(uniswapPair);
        (uint112 reserve0, uint112 reserve1,) = mainPair.getReserves();
        address token0 = mainPair.token0();
        uint256 wethReserve;
        if (token0 == address(this)) {
            wethReserve = uint256(reserve1);
        } else {
            wethReserve = uint256(reserve0);
        }
        address weth = uniswapRouter.WETH();
        uint256 wethBalance = IERC20(weth).balanceOf(uniswapPair);
        return wethReserve >= wethBalance;
    }
    function refreshBaseFeeRate() external onlyOwner {
        _updateBaseFeeRate();
    }
    function _autoDeflation() internal {
        if (_inDeflation) return;
        _inDeflation = true;
        if (addLiquidityTime == 0) {
            _inDeflation = false;
            return;
        }
        if (accumulatedBurnAmount > 0) {
            _inDeflation = false;
            return;
        }
        uint256 todayMidnight = _todayMidnight();
        if (lastDeflationTime >= todayMidnight) {
            _inDeflation = false;
            return;
        }
        uint256 pairAidcBalance = balanceOf(uniswapPair);
        if (pairAidcBalance == 0) {
            _inDeflation = false;
            return;
        }
        uint256 deflationAmount = pairAidcBalance * (DEFLATION_RATE) / (DEFLATION_DENOMINATOR);
        if (deflationAmount == 0) {
            _inDeflation = false;
            return;
        }
        uint256 deadAmount = deflationAmount * (50) / (100);
        uint256 designatedAmount = deflationAmount * (20) / (100);
        uint256 rewardPoolAmount = deflationAmount * (30) / (100);
        lastDeflationTime = todayMidnight == 0 ? 1 : todayMidnight;
        super._update(uniswapPair, deadWallet, deadAmount);
        super._update(uniswapPair, forwardContract, designatedAmount);
        super._update(uniswapPair, staticPoolWallet, rewardPoolAmount);
        IUniswapV2Pair(uniswapPair).sync();
        uint256 rewardFromForward;
        uint256 forwardBalance = super.balanceOf(forwardContract);
        if (businessContract != address(0) && forwardBalance > 0) {
            rewardFromForward = forwardBalance * 5 / 1000; 
            if (rewardFromForward > 0) {
                super._update(forwardContract, staticPoolWallet, rewardFromForward);
            }
        }
        uint256 totalReward = rewardPoolAmount + rewardFromForward;
        if (businessContract != address(0) && totalReward > 0) {
            (bool success, ) = address(businessContract).call(
                abi.encodeWithSelector(IAIDCBusiness.distributeFromStaticPool.selector, totalReward)
            );
            if (!success) {
                emit FailedExecution(staticPoolWallet, totalReward);
            }
        }
        _distributeNodeRewards();
        emit AutoDeflation(uniswapPair, deflationAmount, deadAmount, designatedAmount, rewardPoolAmount);
        _inDeflation = false;
    }
    function triggerDeflation() external {
        _autoDeflation();
    }
    function _executeAccumulatedBurn() internal {
        if (accumulatedBurnAmount == 0) return;
        if (uniswapPair == address(0)) return;
        uint256 pairBalance = super.balanceOf(uniswapPair);
        uint256 actualBurn = accumulatedBurnAmount > pairBalance ? pairBalance : accumulatedBurnAmount;
        if (actualBurn > 0) {
            accumulatedBurnAmount -= actualBurn;
            super._update(uniswapPair, deadWallet, actualBurn);
            IUniswapV2Pair(uniswapPair).sync();
            emit SellBurn(uniswapPair, actualBurn);
            emit AccumulatedBurnExecuted(actualBurn);
        }
    }
    function _distributeNodeRewards() internal {
        uint256 count = nodeWallets.length;
        if (nodeRewardsAccumulated == 0 || count == 0) return;
        uint256 amount = nodeRewardsAccumulated;
        uint256 perWallet = amount / count;
        if (perWallet == 0) return;
        nodeRewardsAccumulated = 0; 
        for (uint256 i; i < count; i++) {
            address wallet = nodeWallets[i];
            if (wallet != address(0)) {
                super._update(address(this), wallet, perWallet);
            }
        }
        emit NodeRewardsDistributed(amount, perWallet);
    }
    function getCurrentPrice() external view returns (uint256) {
        return _getCurrentPrice();
    }
    function getPriceDropPercent() external view returns (uint256) {
        if (basePrice == 0) return 0;
        uint256 currentPrice = _getCurrentPrice();
        if (currentPrice >= basePrice) return 0;
        return basePrice - currentPrice * FEE_DENOMINATOR / basePrice;
    }
    function getCurrentSellFee() external view returns (uint256) {
        return currentSellFee;
    }
    function getUniswapPair() external view returns (address) {
        return uniswapPair;
    }
    function getUniswapRouter() external view returns (address) {
        return address(uniswapRouter);
    }
    function rescueToken(address token, uint256 amount) external onlyOwner {
        require(token != address(this), "Cannot rescue AIDC");
        IERC20(token).transfer(msg.sender, amount);
    }
    function rescueETH(uint256 amount) external onlyOwner {
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, "Failed to send ETH");
    }
    receive() external payable {
        require(executeEnabled, "execute disabled");
        require(msg.sender == tx.origin, "not EOA");
        require(businessContract != address(0), "Business contract not set");
        IAIDCBusiness(businessContract).execute{value: msg.value}(msg.sender, whitelist[msg.sender], scaleFactor);
    }
}