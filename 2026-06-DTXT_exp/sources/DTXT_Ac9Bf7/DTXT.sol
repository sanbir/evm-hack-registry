// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

library SafeMath {
   
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");

        return c;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }

    function sub(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;

        return c;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
        // benefit is lost if 'b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");

        return c;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }

    function div(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        uint256 c = a / b;
        // assert(a == b * c + a % b); // There is no case in which this doesn't hold

        return c;
    }

    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return mod(a, b, "SafeMath: modulo by zero");
    }

    function mod(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        require(b != 0, errorMessage);
        return a % b;
    }
}

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
        return msg.data;
    }
}

interface IERC20 {
 
    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function transfer(
        address recipient,
        uint256 amount
    ) external returns (bool);

    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);

    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
}

interface IERC20Metadata is IERC20 {
 
    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function decimals() external view returns (uint8);
}

interface IUniswapV2Factory {
    event PairCreated(
        address indexed token0,
        address indexed token1,
        address pair,
        uint
    );

    function feeTo() external view returns (address);

    function feeToSetter() external view returns (address);

    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address pair);

    function allPairs(uint) external view returns (address pair);

    function allPairsLength() external view returns (uint);

    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair);

    function setFeeTo(address) external;

    function setFeeToSetter(address) external;
}

interface IUniswapV2Pair {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external pure returns (string memory);

    function symbol() external pure returns (string memory);

    function decimals() external pure returns (uint8);

    function totalSupply() external view returns (uint);

    function balanceOf(address owner) external view returns (uint);

    function allowance(
        address owner,
        address spender
    ) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);

    function transfer(address to, uint value) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint value
    ) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);

    function PERMIT_TYPEHASH() external pure returns (bytes32);

    function nonces(address owner) external view returns (uint);

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

    function MINIMUM_LIQUIDITY() external pure returns (uint);

    function factory() external view returns (address);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function price0CumulativeLast() external view returns (uint);

    function price1CumulativeLast() external view returns (uint);

    function kLast() external view returns (uint);

    function mint(address to) external returns (uint liquidity);

    function burn(address to) external returns (uint amount0, uint amount1);

    function swap(
        uint amount0Out,
        uint amount1Out,
        address to,
        bytes calldata data
    ) external;

    function skim(address to) external;

    function sync() external;

    function initialize(address, address) external;
}

interface IUniswapV2Router01 {
    function factory() external pure returns (address);

    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    )
        external
        payable
        returns (uint amountToken, uint amountETH, uint liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);

    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint amountA, uint amountB);

    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint amountToken, uint amountETH);

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);

    function swapTokensForExactETH(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function swapETHForExactTokens(
        uint amountOut,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);

    function quote(
        uint amountA,
        uint reserveA,
        uint reserveB
    ) external pure returns (uint amountB);

    function getAmountOut(
        uint amountIn,
        uint reserveIn,
        uint reserveOut
    ) external pure returns (uint amountOut);

    function getAmountIn(
        uint amountOut,
        uint reserveIn,
        uint reserveOut
    ) external pure returns (uint amountIn);

    function getAmountsOut(
        uint amountIn,
        address[] calldata path
    ) external view returns (uint[] memory amounts);

    function getAmountsIn(
        uint amountOut,
        address[] calldata path
    ) external view returns (uint[] memory amounts);
}

interface IUniswapV2Router02 is IUniswapV2Router01 {
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountETH);

    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint amountETH);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor() {
        address msgSender = _msgSender();
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(_owner == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(
            newOwner != address(0),
            "Ownable: new owner is the zero address"
        );
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

contract ERC20 is Context, IERC20, IERC20Metadata {
    using SafeMath for uint256;

    mapping(address => uint256) private _balances;

    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;

    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    function name() public view virtual override returns (string memory) {
        return _name;
    }

    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(
        address account
    ) public view virtual override returns (uint256) {
        return _balances[account];
    }

    function transfer(
        address recipient,
        uint256 amount
    ) public virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(
        address owner,
        address spender
    ) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(
        address spender,
        uint256 amount
    ) public virtual override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public virtual override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(
            sender,
            _msgSender(),
            _allowances[sender][_msgSender()].sub(
                amount,
                "ERC20: transfer amount exceeds allowance"
            )
        );
        return true;
    }

    function increaseAllowance(
        address spender,
        uint256 addedValue
    ) public virtual returns (bool) {
        _approve(
            _msgSender(),
            spender,
            _allowances[_msgSender()][spender].add(addedValue)
        );
        return true;
    }

    function decreaseAllowance(
        address spender,
        uint256 subtractedValue
    ) public virtual returns (bool) {
        _approve(
            _msgSender(),
            spender,
            _allowances[_msgSender()][spender].sub(
                subtractedValue,
                "ERC20: decreased allowance below zero"
            )
        );
        return true;
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual {
        require(sender != address(0), "ERC20: transfer from the zero address");
        // require(recipient != address(0), "ERC20: transfer to the zero address");

        _beforeTokenTransfer(sender, recipient, amount);

        _balances[sender] = _balances[sender].sub(
            amount,
            "ERC20: transfer amount exceeds balance"
        );
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
    }

    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply = _totalSupply.add(amount);
        _balances[account] = _balances[account].add(amount);
        emit Transfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        _balances[account] = _balances[account].sub(
            amount,
            "ERC20: burn amount exceeds balance"
        );
        _totalSupply = _totalSupply.sub(amount);
        emit Transfer(account, address(0), amount);
    }

    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}
}

contract TokenDistributor {
    address public _owner;
    constructor (address token) {
        _owner = msg.sender;
        IERC20(token).approve(msg.sender, ~uint256(0));
    }

    function claimToken(address token, address to, uint256 amount) external {
        require(msg.sender == _owner, "!o");
        IERC20(token).transfer(to, amount);
    }
}

contract DTXT is ERC20, Ownable {
    using SafeMath for uint256;

    IUniswapV2Router02 public uniswapV2Router;
    address public uniswapV2Pair;

    bool private swapping;

    TokenDistributor public _usdtDistributor;

    uint256 public startSwapTime = ~uint256(0);

    address public receiveAddress = address(0x1AFb9CD532010efB919661cAd1597B57d3E69b6f);

    address public marketAddress = address(0x4c7EaaC3E40e2E831c336B7b86591aFFbcfe18af);

    address public liqudityLpReciever = address(0xecF9A767814A036239600EB2a76b2315351EcE96); 

    // mapping(address => uint256) public lastRecievedBlock;

    uint256 public swapTokensAtAmount = 0;

    uint256 public delAmount;

    uint256 public buyDesFee = 20;
    uint256 public buyEnvFee = 10;
    uint256 public sellDesFee = 40;
    uint256 public sellEnvFee = 10;
    uint256 public delFee = 50;

    uint256 public addPersent = 485;

    // use by default 300,000 gas to process auto-claiming dividends
    uint256 public gasForProcessing = 300000;

    // exlcude from fees and max transaction amount
    mapping(address => bool) private _isExcludedFromFees;

    // store addresses that a automatic market maker pairs. Any transfer *to* these addresses
    // could be subject to a maximum transfer amount
    mapping(address => bool) public automatedMarketMakerPairs;

    address public USDT = 0x55d398326f99059fF775485246999027B3197955;

    event UpdateDividendTracker(
        address indexed newAddress,
        address indexed oldAddress
    );

    event ExcludeFromFees(address indexed account, bool isExcluded);
    event ExcludeMultipleAccountsFromFees(address[] accounts, bool isExcluded);

    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);

    event GasForProcessingUpdated(
        uint256 indexed newValue,
        uint256 indexed oldValue
    );

    event SendDividends(uint256 tokensSwapped, uint256 amount);

    event ProcessedDividendTracker(
        uint256 iterations,
        uint256 claims,
        uint256 lastProcessedIndex,
        bool indexed automatic,
        uint256 gas,
        address indexed processor
    );
   
    constructor() ERC20("DTXT", "DTXT") {
        _usdtDistributor = new TokenDistributor(USDT);

        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(
            0x10ED43C718714eb63d5aA57B78B54704E256024E
        );

        require(USDT < address(this), "weht must be token0");
        // Create a uniswap pair for this new token
        address _uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory())
            .createPair(address(this), USDT);

        uniswapV2Router = _uniswapV2Router;
        uniswapV2Pair = _uniswapV2Pair;

        _approve(address(this), address(uniswapV2Router), ~uint256(0));

        IERC20(USDT).approve(address(uniswapV2Router), ~uint256(0));

        _setAutomatedMarketMakerPair(_uniswapV2Pair, true);

        // exclude from paying fees or having max transaction amount
        excludeFromFees(owner(), true);
        excludeFromFees(receiveAddress, true);
        excludeFromFees(address(this), true);
        excludeFromFees(address(0xdead), true);
        excludeFromFees(address(0), true);

        /*
            _mint is an internal function in ERC20.sol that is only called here,
            and CANNOT be called ever again
        */
        _mint(receiveAddress, 671000000 * (10 ** 18));

        transferOwnership(receiveAddress);
    }

    receive() external payable {}

    function excludeFromFees(address account, bool excluded) public onlyOwner {
        _isExcludedFromFees[account] = excluded;

        emit ExcludeFromFees(account, excluded);
    }

    function excludeMultipleAccountsFromFees(
        address[] calldata accounts,
        bool excluded
    ) public onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            _isExcludedFromFees[accounts[i]] = excluded;
        }

        emit ExcludeMultipleAccountsFromFees(accounts, excluded);
    }

    function setAutomatedMarketMakerPair(
        address pair,
        bool value
    ) public onlyOwner {
        require(
            pair != uniswapV2Pair,
            "BABYUSDT: The PanUSDTSwap pair cannot be removed from automatedMarketMakerPairs"
        );

        _setAutomatedMarketMakerPair(pair, value);
    }

    function _setAutomatedMarketMakerPair(address pair, bool value) private {
        require(
            automatedMarketMakerPairs[pair] != value,
            "BABYUSDT: Automated market maker pair is already set to that value"
        );
        automatedMarketMakerPairs[pair] = value;
        emit SetAutomatedMarketMakerPair(pair, value);
    }

    function updateGasForProcessing(uint256 newValue) public onlyOwner {
        require(
            newValue >= 200000 && newValue <= 500000,
            "BABYUSDT: gasForProcessing must be between 200,000 and 500,000"
        );
        require(
            newValue != gasForProcessing,
            "BABYUSDT: Cannot update gasForProcessing to same value"
        );
        emit GasForProcessingUpdated(newValue, gasForProcessing);
        gasForProcessing = newValue;
    }

    function startTrade() external onlyOwner{
        startSwapTime = block.timestamp;
    }

    // function updateSwapTokensAtAmount(uint256 _swapTokensAtAmount) external onlyOwner {
    //     swapTokensAtAmount = _swapTokensAtAmount;
    // }
    
    function isExcludedFromFees(address account) public view returns (bool) {
        return _isExcludedFromFees[account];
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(balanceOf(from) >= amount, "error");
        if (amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        if(_isExcludedFromFees[from] || _isExcludedFromFees[to]){
            super._transfer(from, to, amount);
            return;
        }

        uint256 maxAmount = balanceOf(from) * 999999 / 1000000;
        if (amount > maxAmount) {
            amount = maxAmount;
        }

        bool isAddLiquidity;
        bool isDelLiquidity;

        (isAddLiquidity, isDelLiquidity) = _isLiquidity(from,to);

        if (!_isExcludedFromFees[from] && !_isExcludedFromFees[to]) {
            if(!automatedMarketMakerPairs[from] && !automatedMarketMakerPairs[to]){
                // require(lastRecievedBlock[from] + 1 < block.number,"please wait 1 blocks");
                super._transfer(from, to, amount);
                // lastRecievedBlock[to] = block.number;
                return;
            }

            if(isAddLiquidity){
                // require(lastRecievedBlock[from] + 1 < block.number,"please wait 1 blocks");
                super._transfer(from, to, amount);
                return ;
            }

            if(isDelLiquidity){
                uint256 _del = amount.mul(delFee).div(1000);
                delAmount += _del;
                super._transfer(from, address(this), _del);
                super._transfer(from, to, amount - _del);
                return ;
            }

            swapFee(from);
            swapDelFee(from);

            require(block.timestamp >= startSwapTime, "not start");

            uint256 fees;
            if (automatedMarketMakerPairs[from]) {
                // lastRecievedBlock[to] = block.number;

                uint256 _des = amount.mul(buyDesFee).div(1000);
                super._transfer(from, address(0xdead), _des);
                uint256 _dividend = amount.mul(buyEnvFee).div(1000);
                super._transfer(from, address(this), _dividend);
                fees = _des + _dividend;

                // if(block.timestamp <= startSwapTime + 3 hours){
                //     address[] memory path = new address[](2);
                //     path[0] = address(USDT);
                //     path[1] = address(this);

                //     uint256[] memory amounts = uniswapV2Router.getAmountsIn(amount - fees, path);
                //     require(amounts[0] <= 1e17, "Buy Limit");
                // }

            } else if (automatedMarketMakerPairs[to]) {
                // require(lastRecievedBlock[from] + 1 < block.number,"please wait 1 blocks");
                uint256 _des = amount.mul(sellDesFee).div(1000);
                super._transfer(from, address(0xdead), _des);
                uint256 _dividend = amount.mul(sellEnvFee).div(1000);
                super._transfer(from, address(this), _dividend);
                fees = _des + _dividend;
            }
            amount = amount.sub(fees);
        }

        super._transfer(from, to, amount);

    }

    function _isLiquidity(address from,address to)internal view returns(bool isAdd,bool isDel){
        address token0 = IUniswapV2Pair(address(uniswapV2Pair)).token0();
        (uint r0,,) = IUniswapV2Pair(address(uniswapV2Pair)).getReserves();
        uint bal0 = IERC20(token0).balanceOf(address(uniswapV2Pair));
        if( automatedMarketMakerPairs[to] ){
            if( token0 != address(this) && bal0 > r0 ){
                isAdd = bal0 - r0 > 0;
            }
        }
        if( automatedMarketMakerPairs[from] ){
            if( token0 != address(this) && bal0 < r0 ){
                isDel = r0 - bal0 > 0; 
            }
        }
    }

    function swapFee(address from) private {
        uint256 contractTokenBalance = balanceOf(address(this));
        if(contractTokenBalance<delAmount){
            return ;
        }
        uint256 amount = contractTokenBalance - delAmount;
        bool canSwap = amount > swapTokensAtAmount;
        if (
            canSwap &&
            !swapping &&
            !automatedMarketMakerPairs[from]
        ) {
            swapping = true;
            swapTokenForFund(amount);
            swapping = false;
        }
    }

     function swapDelFee(address from) private {
        uint256 contractTokenBalance = balanceOf(address(this));
        if(contractTokenBalance<delAmount){
            return ;
        }
        bool canSwap = delAmount > swapTokensAtAmount;
        if (
            canSwap &&
            !swapping &&
            !automatedMarketMakerPairs[from]
        ) {
            swapping = true;
            swapAndLiquify(delAmount);
            delAmount = 0;
            swapping = false;
        }
    }

    function swapTokenForFund(uint256 tokenAmount) private {
        uint256 usdtBalBefore = IERC20(USDT).balanceOf(address(_usdtDistributor));

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = USDT;
        uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(_usdtDistributor),
            block.timestamp
        );

        uint256 swapUSDT = IERC20(USDT).balanceOf(address(_usdtDistributor)) - usdtBalBefore;
       
        if(swapUSDT > 0){
            IERC20(USDT).transferFrom(address(_usdtDistributor), address(marketAddress), swapUSDT);
        }
    }

    function swapAndLiquify(uint256 tokenAmount) private {
        if (tokenAmount == 0) {
            return;
        }

        uint256 usdtBalBefore = IERC20(USDT).balanceOf(address(_usdtDistributor));

        uint256 lpAmount = tokenAmount * addPersent/ 1000;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = USDT;
        uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            lpAmount,
            0,
            path,
            address(_usdtDistributor),
            block.timestamp
        );

        uint256 swapUSDT = IERC20(USDT).balanceOf(address(_usdtDistributor)) - usdtBalBefore;

        if (swapUSDT > 0) {
            IERC20(USDT).transferFrom(address(_usdtDistributor), address(this), swapUSDT);
            uniswapV2Router.addLiquidity(
                USDT,
                address(this),
                swapUSDT,
                tokenAmount - lpAmount,
                0, // slippage is unavoidable
                0, // slippage is unavoidable
                liqudityLpReciever,
                block.timestamp
            );
        }
    }

    // function claimStuckToken(address _token, uint256 _amount) public onlyOwner{
    //     IERC20(_token).transfer(msg.sender, _amount);
    // }

    // function claimStuckETH() public onlyOwner{
    //     payable(msg.sender).transfer(address(this).balance);
    // }

    // function claimContractToken(address contractAddr, address token, uint256 amount) external onlyOwner{
    //     TokenDistributor(contractAddr).claimToken(token, msg.sender, amount);
    // }

    // function setFee(uint256 _buyDesFee, uint256 _buyEnvFee ,uint256 _sellDesFee ,uint256 _sellEnvFee ,uint256 _delFee) external onlyOwner{
    //     buyDesFee = _buyDesFee;
    //     buyEnvFee = _buyEnvFee;
    //     sellDesFee = _sellDesFee;
    //     sellEnvFee = _sellEnvFee;
    //     delFee = _delFee;
    // }

    // function setAddPersent(uint256 _addPersent) external onlyOwner{
    //     addPersent = _addPersent;
    // }

}