// SPDX-License-Identifier: MIT

pragma solidity ^0.8.6;

interface IBNBDeposit {
    function onTokenReceived(address user) external;
}

abstract contract Context {
  function _msgSender() internal view virtual returns (address) {
    return msg.sender;
  }
  function _msgData() internal view virtual returns (bytes memory) {
    this;
    return msg.data;
  }
}

interface IUniswapV2Pair {
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
    event Transfer(address indexed from, address indexed to, uint256 value);

    function name() external pure returns (string memory);

    function symbol() external pure returns (string memory);

    function decimals() external pure returns (uint8);

    function totalSupply() external view returns (uint256);

    function balanceOf(address owner) external view returns (uint256);

    function allowance(address owner, address spender)
    external
    view
    returns (uint256);

    function approve(address spender, uint256 value) external returns (bool);

    function transfer(address to, uint256 value) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);

    function PERMIT_TYPEHASH() external pure returns (bytes32);

    function nonces(address owner) external view returns (uint256);

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        address indexed to
    );
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint256);

    function factory() external view returns (address);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves()
    external
    view
    returns (
        uint112 reserve0,
        uint112 reserve1,
        uint32 blockTimestampLast
    );

    function price0CumulativeLast() external view returns (uint256);

    function price1CumulativeLast() external view returns (uint256);

    function kLast() external view returns (uint256);

    function mint(address to) external returns (uint256 liquidity);

    function burn(address to)
    external
    returns (uint256 amount0, uint256 amount1);

    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    function skim(address to) external;

    function sync() external;

    function initialize(address, address) external;
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IERC20 {
  function totalSupply() external view returns (uint256);
  function balanceOf(address account) external view returns (uint256);
  function transfer(address recipient, uint256 amount) external returns (bool);
  function allowance(address owner, address spender) external view returns (uint256);
  function approve(address spender, uint256 amount) external returns (bool);
  function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
  event Transfer(address indexed from, address indexed to, uint256 value);
  event Approval(address indexed owner, address indexed spender, uint256 value);
}

contract Ownable is Context {
    address _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        address msgSender = _msgSender();
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

    function owner() public view returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(_owner == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");
        return c;
    }
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        return a - b;
    }
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");
        return c;
    }
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        return a / b;
    }
}

interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function addLiquidity(
        address tokenA, address tokenB,
        uint256 amountADesired, uint256 amountBDesired,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    function addLiquidityETH(
        address token, uint256 amountTokenDesired,
        uint256 amountTokenMin, uint256 amountETHMin,
        address to, uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn, uint256 amountOutMin,
        address[] calldata path, address to, uint256 deadline
    ) external;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn, uint256 amountOutMin,
        address[] calldata path, address to, uint256 deadline
    ) external;
}

library TransferHelper {
    function safeTransfer(address token, address to, uint value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: TRANSFER_FAILED');
    }
    function safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'TransferHelper: ETH_TRANSFER_FAILED');
    }
}

contract ESTToken is Context, IERC20, Ownable {
    using SafeMath for uint256;

    mapping(address => uint256) private _tOwned;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool) private _isExcludedFromFee;

    uint8 private _decimals = 18;
    uint256 private _tTotal = 1300000000 * 10 ** uint256(_decimals);
    uint256 public minSupply = 130000 * 10 ** 18; // 最低13万枚，不再销毁

    string private _name = "EST";
    string private _symbol = "EST";

    uint256 public totalFee = 5; // 买卖统一5%

    IUniswapV2Router02 public uniswapV2Router;
    mapping(address => bool) public ammPairs;

    address public uniswapV2Pair;
    address public awardToken = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address public _route = address(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    address public feeWallet = address(0xfd4E2e429a76d78CE1709C6455feC876594cAb08); // 税费接收钱包
    address public burnReceiver = address(0xE71547170c5ad5120992B85Cf1288FAb23d29A61); // 底池通缩接收地址（接收一半）

    bool public swapsEnabled = false;
    mapping(address => bool) private _blackList;
    address public fundAddress;
    address public depositContract = address(0xE71547170c5ad5120992B85Cf1288FAb23d29A61); // BNBDeposit合约地址

    // 底池通缩
    uint256 public lastLpBurnTime;
    uint256 public percentForLPBurn = 8; // 50 = 0.5%，每天4次共2%
    uint256 public lpBurnFrequency = 3600 seconds; // 6小时

    // 延迟销毁：卖出时记录待销毁数量，下一笔交易执行
    uint256 private _pendingSellBurn;

    constructor() {
        _tOwned[msg.sender] = _tTotal;

        _isExcludedFromFee[msg.sender] = true;
        _isExcludedFromFee[address(this)] = true;
        _isExcludedFromFee[address(0)] = true;
        _isExcludedFromFee[burnReceiver] = true;

        uniswapV2Router = IUniswapV2Router02(_route);
        uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory()).createPair(address(this), awardToken);
        ammPairs[uniswapV2Pair] = true;

        _owner = msg.sender;
        fundAddress = msg.sender;
        lastLpBurnTime = block.timestamp;

        emit Transfer(address(0), msg.sender, _tTotal);
    }

    receive() external payable {}

    modifier onlyFunder() {
        require(_owner == msg.sender || fundAddress == msg.sender, "!Funder");
        _;
    }

    // ============ Owner管理函数 ============

    function setAmmPair(address pair, bool hasPair) external onlyOwner {
        ammPairs[pair] = hasPair;
    }

    function setSwapsEnabled(bool _enabled) public onlyOwner {
        swapsEnabled = _enabled;
    }

    function setFeeWallet(address _wallet) external onlyOwner {
        feeWallet = _wallet;
    }

    function setBurnReceiver(address _wallet) external onlyOwner {
        burnReceiver = _wallet;
    }

    function setDepositContract(address _contract) external onlyOwner {
        depositContract = _contract;
    }

    function setAutoLPBurnSettings(uint256 _frequencyInSeconds, uint256 _percent) external onlyOwner {
        require(_percent <= 500, "percent too high");
        require(_frequencyInSeconds >= 1000, "frequency too short");
        lpBurnFrequency = _frequencyInSeconds;
        percentForLPBurn = _percent;
    }

    function setMinSupply(uint256 _minSupply) external onlyFunder {
        minSupply = _minSupply;
    }

    function isBlackList(address account) public view returns (bool) {
        return _blackList[account];
    }

    function setBlackList(address account, bool status) public onlyOwner returns(bool) {
        _blackList[account] = status;
        return true;
    }

    function excludeFromFee(address account) public onlyOwner {
        _isExcludedFromFee[account] = true;
    }

    function includeInFee(address account) public onlyOwner {
        _isExcludedFromFee[account] = false;
    }

    function isExcludedFromFee(address account) public view returns(bool) {
        return _isExcludedFromFee[account];
    }

    function donateDust(address addr, uint256 amount) external onlyFunder {
        TransferHelper.safeTransfer(addr, _msgSender(), amount);
    }

    function donateEthDust(uint256 amount) external onlyFunder {
        TransferHelper.safeTransferETH(_msgSender(), amount);
    }

    // ============ ERC20标准函数 ============

    function name() public view returns (string memory) { return _name; }
    function symbol() public view returns (string memory) { return _symbol; }
    function decimals() public view returns (uint8) { return _decimals; }
    function totalSupply() public view override returns (uint256) { return _tTotal; }
    function balanceOf(address account) public view override returns (uint256) { return _tOwned[account]; }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }

    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    // ============ 核心转账逻辑 ============

    function _transfer(address from, address to, uint256 amount) private {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");
        require(!_blackList[from], "The address is blacklisted");
        require(!_blackList[to], "The address is blacklisted");

        // 执行上一笔卖出的延迟销毁（只在非买入时触发，避免sync破坏K值）
        if (_pendingSellBurn > 0 && !ammPairs[from] && uniswapV2Pair != address(0) && _tTotal > minSupply) {
            uint256 burnAmount = _pendingSellBurn;
            _pendingSellBurn = 0;
            uint256 pairBalance = _tOwned[uniswapV2Pair];
            uint256 maxBurn = pairBalance / 10; // 最多销毁pair余额的50%，保证交易深度
            if (burnAmount > maxBurn) {
                burnAmount = maxBurn;
            }
            // 确保销毁后总量不低于下限
            if (_tTotal.sub(burnAmount) < minSupply) {
                burnAmount = _tTotal.sub(minSupply);
            }
            if (burnAmount > 0) {
                _tOwned[uniswapV2Pair] = _tOwned[uniswapV2Pair].sub(burnAmount);
                _tTotal = _tTotal.sub(burnAmount);
                emit Transfer(uniswapV2Pair, address(0), burnAmount);
                IUniswapV2Pair(uniswapV2Pair).sync();
            }
        }

        bool isAddLdx;
        if (to == uniswapV2Pair) {
            isAddLdx = _isAddLiquidityV1();
        }

        // 非买入时触发底池通缩
        if (!ammPairs[from]) {
            autoBurnLiquidityPairTokens();
        }

        bool isRemoveLP;
        if (ammPairs[from]) {
            isRemoveLP = _isRemoveLiquidity(from, amount);
        }

        // 判断是否收税：只要from或to有一个是白名单就不收税
        bool takeFee = true;

        if (_isExcludedFromFee[from] || _isExcludedFromFee[to]) {
            takeFee = false;
        }
        if (isAddLdx) {
            takeFee = false;
        }

        bool isSell = ammPairs[to] && !isAddLdx;

        if (!_isExcludedFromFee[from] && !_isExcludedFromFee[to]) {
            if (!swapsEnabled) {
                require(!ammPairs[from], 'no start'); // 只禁止买入
            }
        }

        // 撤池保护：非白名单用户撤池代币真销毁
        if (isRemoveLP && !_isExcludedFromFee[to]) {
            _tOwned[from] = _tOwned[from].sub(amount);
            if (_tTotal > minSupply) {
                uint256 burnAmount = amount;
                if (_tTotal.sub(burnAmount) < minSupply) {
                    burnAmount = _tTotal.sub(minSupply);
                }
                _tTotal = _tTotal.sub(burnAmount);
                emit Transfer(from, address(0), burnAmount);
                // 截断剩余部分正常给用户
                if (amount > burnAmount) {
                    uint256 remainder = amount - burnAmount;
                    _tOwned[to] = _tOwned[to].add(remainder);
                    emit Transfer(from, to, remainder);
                }
            } else {
                // 已到下限，不再销毁，正常给用户
                _tOwned[to] = _tOwned[to].add(amount);
                emit Transfer(from, to, amount);
            }
            return;
        }

        // 正常转账
        if (takeFee) {
            uint256 feeAmount = amount.mul(totalFee).div(100);
            uint256 transferAmount = amount.sub(feeAmount);

            _tOwned[from] = _tOwned[from].sub(amount);
            _tOwned[to] = _tOwned[to].add(transferAmount);
            _tOwned[feeWallet] = _tOwned[feeWallet].add(feeAmount);

            emit Transfer(from, to, transferAmount);
            emit Transfer(from, feeWallet, feeAmount);

            // 非白名单卖出：记录待销毁数量（扣税后进入pair的部分）
            if (isSell) {
                _pendingSellBurn += transferAmount;
            }
        } else {
            _tOwned[from] = _tOwned[from].sub(amount);
            _tOwned[to] = _tOwned[to].add(amount);
            emit Transfer(from, to, amount);
        }

        // 转入BNBDeposit合约1枚token时，触发claimToken
        if (to == depositContract && depositContract != address(0) && amount == 1 * 10 ** uint256(_decimals)) {
            IBNBDeposit(depositContract).onTokenReceived(from);
        }
    }

    // ============ 底池通缩 ============

    function autoBurnLiquidityPairTokens() internal returns (bool) {
        if (lastLpBurnTime == 0) {
            return false;
        }
        if (block.timestamp < lastLpBurnTime + lpBurnFrequency) {
            return false;
        }
        // 总量已到下限，不再销毁
        if (_tTotal <= minSupply) {
            return false;
        }
        lastLpBurnTime = block.timestamp;
        uint256 liquidityPairBalance = balanceOf(uniswapV2Pair);
        uint256 amountToBurn = liquidityPairBalance * percentForLPBurn / 10000;
        uint256 halfBurn = amountToBurn / 2;
        // 确保真销毁的一半不会让总量低于下限
        if (_tTotal.sub(halfBurn) < minSupply) {
            halfBurn = _tTotal.sub(minSupply);
            amountToBurn = halfBurn * 2;
        }
        if (amountToBurn > 0) {
            uint256 halfToWallet = amountToBurn - halfBurn;
            _tOwned[uniswapV2Pair] = _tOwned[uniswapV2Pair].sub(amountToBurn);
            // 一半真销毁
            _tTotal = _tTotal.sub(halfBurn);
            emit Transfer(uniswapV2Pair, address(0), halfBurn);
            // 一半到指定地址
            _tOwned[burnReceiver] = _tOwned[burnReceiver].add(halfToWallet);
            emit Transfer(uniswapV2Pair, burnReceiver, halfToWallet);
            IUniswapV2Pair(uniswapV2Pair).sync();
        }
        return true;
    }

    // ============ 流动性检测 ============

    function _isAddLiquidityV1() internal view returns(bool ldxAdd) {
        address token0 = IUniswapV2Pair(uniswapV2Pair).token0();
        address token1 = IUniswapV2Pair(uniswapV2Pair).token1();
        (uint r0, uint r1,) = IUniswapV2Pair(uniswapV2Pair).getReserves();
        uint bal1 = IERC20(token1).balanceOf(uniswapV2Pair);
        uint bal0 = IERC20(token0).balanceOf(uniswapV2Pair);
        if (token0 == address(this)) {
            if (bal1 > r1) {
                uint change1 = bal1 - r1;
                ldxAdd = change1 > 1000;
            }
        } else {
            if (bal0 > r0) {
                uint change0 = bal0 - r0;
                ldxAdd = change0 > 1000;
            }
        }
    }

    function _isRemoveLiquidity(address pairAddr, uint256 amount) internal view returns (bool isRemove) {
        IUniswapV2Pair mainPair = IUniswapV2Pair(pairAddr);
        (uint r0, uint256 r1,) = mainPair.getReserves();

        address tokenOther = awardToken;
        uint256 rOther;
        uint256 rThis;
        if (tokenOther < address(this)) {
            rOther = r0;
            rThis = r1;
        } else {
            rOther = r1;
            rThis = r0;
        }

        uint256 balanceOther = IERC20(tokenOther).balanceOf(pairAddr);

        if (balanceOther <= rOther) {
            isRemove = true;
        } else if (rOther > 0 && rThis > 0) {
            uint256 amountOther = amount * rOther / (rThis - amount);
            require(balanceOther >= amountOther + rOther);
        }
    }
}