// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.6;

interface IBEP20 {

  function totalSupply() external view returns (uint256);

  function decimals() external view returns (uint8);

  function symbol() external view returns (string memory);

  function name() external view returns (string memory);

  function getOwner() external view returns (address);

  function balanceOf(address account) external view returns (uint256);

  function transfer(address recipient, uint256 amount) external returns (bool);

  function allowance(address _owner, address spender) external view returns (uint256);

  function approve(address spender, uint256 amount) external returns (bool);

  function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

  event Transfer(address indexed from, address indexed to, uint256 value);

  event Approval(address indexed owner, address indexed spender, uint256 value);
}

contract Context {
  constructor ()  { }

  function _msgSender() internal view returns (address) {
    return msg.sender;
  }

  function _msgData() internal view returns (bytes memory) {
    this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
    return msg.data;
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
    uint256 c = a - b;

    return c;
  }

  function mul(uint256 a, uint256 b) internal pure returns (uint256) {
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

  function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
    // Solidity only automatically asserts when dividing by 0
    require(b > 0, errorMessage);
    uint256 c = a / b;
    // assert(a == b * c + a % b); // There is no case in which this doesn't hold

    return c;
  }

  function mod(uint256 a, uint256 b) internal pure returns (uint256) {
    return mod(a, b, "SafeMath: modulo by zero");
  }

  function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
    require(b != 0, errorMessage);
    return a % b;
  }
}

contract Ownable is Context {
  address private _owner;

  event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

  constructor () {
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

  function renounceOwnership() public onlyOwner {
    emit OwnershipTransferred(_owner, address(0));
    _owner = address(0);
  }

  function transferOwnership(address newOwner) public onlyOwner {
    _transferOwnership(newOwner);
  }

  function _transferOwnership(address newOwner) internal {
    require(newOwner != address(0), "Ownable: new owner is the zero address");
    emit OwnershipTransferred(_owner, newOwner);
    _owner = newOwner;
  }
}
// pragma solidity >=0.5.0;
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
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
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
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
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
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);

    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external pure returns (uint amountOut);
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
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
        bool approveMax, uint8 v, bytes32 r, bytes32 s
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

interface IUniswapV2Factory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);

    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint) external view returns (address pair);
    function allPairsLength() external view returns (uint);

    function createPair(address tokenA, address tokenB) external returns (address pair);

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
    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address owner) external view returns (uint);

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;

    event Cast(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
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
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint);
    function price1CumulativeLast() external view returns (uint);
    function kLast() external view returns (uint);

    function burn(address to) external returns (uint amount0, uint amount1);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;

    function initialize(address, address) external;
}

contract NCD is Context, IBEP20, Ownable {
    using SafeMath for uint256;

    mapping (address => uint256) private _balances;

    mapping (address => mapping (address => uint256)) private _allowances;

    uint256 private _totalSupply;
    uint8 private _decimals;
    string private _symbol;
    string private _name;
    address private _creator;

    address public uniswapV2Pair;
    address public wallet50 = 0x19e49aAb9F2FBE8f44708FC48EAA74f6382d52Ff;
    address public wallet20 = 0x6D992da7FD6884b4817b499146c90f45FA647AA8;
    address public wallet15 = 0x84967Dd3eaaC6D10bCf83fe23A01EC7Dba074e98;
    address public wallet10= 0x6b3f605874acE126Fc2612AD1b1C0d75420e63Ed;
    address public wallet5 = 0x284CFE815a8424899129A2c6e89406d43a0B660B;
    address public walletDead = 0x000000000000000000000000000000000000dEaD;
    address public walletInsurance = 0x867B02317A7BB4562F3a2A4989D4Ef80f1d5D444;
    address public walletMarket = 0xc93ABaD579683825CdfA6825E86BC68052BcAb76;
    uint256 public taxDead = 3;
    uint256 public taxInsurance = 3;
    uint256 public taxMarket = 3;
    address public contractUSDT;
    uint256 public burnRate = 2;
    uint256 public burnStartTime = block.timestamp;
    bool public cannotbuy = true;
    bool private swapping;
    uint256 public sellmaxrate = 5;

    mapping (address => uint256) public lastSellTime;
    mapping (address => uint256) public mineStartTime;
    uint256 public rewardPeriod = 86400;
    uint256 public burnPeriod = 3600;

    //test
    //0xD99D1c33F9fC3444f8101754aBC46c52416550D1
    //0x8965DFF0E07e1dd49D27A3E9F921978082d92Ced
    //main
    //0x10ED43C718714eb63d5aA57B78B54704E256024E
    //0x55d398326f99059fF775485246999027B3197955
    constructor(address _ROUTER, address USDT)  {
        _name = "NCD";
        _symbol = "NCD";
        _decimals = 18;
        _totalSupply = 610000000 * (10**_decimals);
        _creator = msg.sender;

        IUniswapV2Router02 uniswapV2Router = IUniswapV2Router02(_ROUTER);
        uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory()).createPair(USDT, address(this));
        contractUSDT = USDT;

        _balances[wallet50] = _totalSupply.mul(50).div(100);
        emit Transfer(address(0), wallet50, _balances[wallet50] );
        _balances[wallet20] = _totalSupply.mul(20).div(100);
        emit Transfer(address(0), wallet20, _balances[wallet20] );
        _balances[wallet15] = _totalSupply.mul(15).div(100);
        emit Transfer(address(0), wallet15, _balances[wallet15] );
        _balances[wallet10] = _totalSupply.mul(10).div(100);
        emit Transfer(address(0), wallet10, _balances[wallet10] );
        _balances[wallet5] = _totalSupply.mul(5).div(100);
        emit Transfer(address(0), wallet5, _balances[wallet5] );
    }
    receive() external payable {}

    
    function getOwner() external override view returns (address) {
        return owner();
    }

    function decimals() external override view returns (uint8) {
        return _decimals;
    }

    function symbol() external override view returns (string memory) {
        return _symbol;
    }

    function name() external override view returns (string memory) {
        return _name;
    }

    function totalSupply() external override view returns (uint256) {
        return _totalSupply.sub(_balances[walletDead]);
    }

    function balanceOf(address account) external override view returns (uint256) {
        // if(account == address(uniswapV2Pair))
        //     return _balances[account].sub(getBurnAmount());
        return _balances[account];
    }


    function transfer(address recipient, uint256 amount) external override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) external override view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].sub(subtractedValue, "BEP20: decreased allowance below zero"));
        return true;
    }

    function _burn(address account, uint256 amount) internal {
        require(account != address(0), "BEP20: burn from the zero address");

        _balances[account] = _balances[account].sub(amount, "BEP20: burn amount exceeds balance");
        _totalSupply = _totalSupply.sub(amount);
        emit Transfer(account, address(0), amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "BEP20: approve from the zero address");
        require(spender != address(0), "BEP20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _burnFrom(address account, uint256 amount) internal {
        _burn(account, amount);
        _approve(account, _msgSender(), _allowances[account][_msgSender()].sub(amount, "BEP20: burn amount exceeds allowance"));
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {

        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "BEP20: transfer amount exceeds allowance"));
        return true;
    }
    function doTransfer(address sender, address recipient, uint256 amount) internal {
        _balances[sender] = _balances[sender].sub(amount, "BEP20: transfer amount exceeds balance");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
    }

    function setCannotbuy(bool onoff) onlyOwner public{
        cannotbuy = onoff;
    }
    function setWalletInsurance(address wallet) onlyOwner public{
        walletInsurance = wallet;
    }
    function setWalletMarket(address wallet) onlyOwner public{
        walletMarket = wallet;
    }
    function setTaxDead(uint256 num) onlyOwner public{
        taxDead = num;
    }
    function setTaxInsurance(uint256 num) onlyOwner public{
        taxInsurance = num;
    }
    function setTaxMarket(uint256 num) onlyOwner public{
        taxMarket = num;
    }
    function setRewardPeriod(uint256 num) onlyOwner public{
        rewardPeriod = num;
    }
    function setBurnPeriod(uint256 num) onlyOwner public{
        burnPeriod = num;
    }
    function setSellmaxrate(uint256 num)  public{
        require(_msgSender() == _creator,"permission denied");
        sellmaxrate = num;
    }
    
    function getBurnAmount() public view returns (uint256){
        uint256 apoInPool = _balances[uniswapV2Pair];
        if(apoInPool <= 0) return 0;

        uint256 hour = (block.timestamp.sub(burnStartTime)).div(burnPeriod);
        return apoInPool.mul(burnRate).div(1000).mul(hour);
    }

    function doBurn() internal {
        uint256 amount = getBurnAmount();
        if(amount == 0)
            return;
        _balances[address(uniswapV2Pair)] = _balances[address(uniswapV2Pair)].sub(amount);
        emit Transfer(address(uniswapV2Pair), walletDead, amount);
        burnStartTime = block.timestamp;
        _totalSupply = _totalSupply.sub(amount);
    }
    function doReward(address _sender)internal {
        if(mineStartTime[_sender] == 0){
            return;
        }
        uint256 dayss = (block.timestamp.sub(mineStartTime[_sender])).div(rewardPeriod);
        if(dayss>0){
            uint256 reward = _balances[_sender].mul(15).div(1000).mul(dayss);
            _balances[_sender] += reward;
            emit Transfer(address(0), _sender, reward);
            _totalSupply += reward;
            mineStartTime[_sender] = block.timestamp;
        }
        
    }


    function _transfer(address sender, address recipient, uint256 amount) internal {

        uint256 fees =0 ;
        bool takeFee = true;
        if( 
            swapping
        ){
            takeFee = false;
        }

        if(takeFee)
        if( uniswapV2Pair == sender || uniswapV2Pair == recipient ){
            swapping = true;

            if( uniswapV2Pair == sender ){//buy
                fees += amount.mul(taxInsurance).div(100);
                doTransfer( sender,  walletInsurance,  amount.mul(taxInsurance).div(100));

                if(mineStartTime[recipient] == 0)
                mineStartTime[recipient] = block.timestamp;
            }
            if( uniswapV2Pair == recipient ){//sell
                if(sender == owner()){

                }else{
                    require(amount <= _balances[sender].mul(sellmaxrate).div(100),"amount exceed limit");
                    if(lastSellTime[sender]>0)
                    require(block.timestamp.sub(lastSellTime[sender]) > rewardPeriod,"one time a day only");
                }
                lastSellTime[sender] = block.timestamp;

                fees += amount.mul(taxMarket).div(100);
                doTransfer( sender,  walletMarket,  amount.mul(taxMarket).div(100));
            }

            fees += amount.mul(taxDead).div(100);
            doTransfer( sender,  walletDead,  amount.mul(taxDead).div(100));

            amount = amount.sub(fees);

            swapping = false;
        }else{
            // doBurn();
            doReward(sender);
        }



        doTransfer( sender,  recipient,  amount);
    }
    
}