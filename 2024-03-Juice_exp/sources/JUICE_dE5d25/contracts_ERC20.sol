pragma solidity ^0.8.9;

// SPDX-License-Identifier: MIT

import "./Context.sol";
import "./IERC20.sol";
import "./SafeMath.sol";
import "./IUniswapV2Router02.sol";

contract ERC20 is Context, IERC20 {
    using SafeMath for uint256;

    IUniswapV2Router02 public uniswapRouter;
    address public wethAddress;
    address[] public pairsList;
    address public lpPair;

    bool public isTradingEnabled = false;

    mapping (address => uint256) private _balances;
    mapping (address => bool) public isExcludedFromFee;
    mapping (address => bool) public isPair;

    mapping (address => mapping (address => uint256)) private _allowances;

    
    uint256 private _totalSupply;

    uint256 public transferFee = 0;
    uint256 public buyFee = 20;
    uint256 public sellFee = 20;

    string private _name;
    string private _symbol;   
    uint8 private _decimals; 

    bool inSwap;
    bool public contractSwapEnabled = false;
    uint256 public swapThreshold;
    uint256 public swapAmount;
    bool public piContractSwapsEnabled;
    uint256 public piSwapPercent;

    struct TaxWallets {
        address payable development;
    }

    TaxWallets public _taxWallets = TaxWallets({
        development: payable(0x3a5198c44E14C61C5Af67C8b44DbA19533FeD23d)
        });

    event SwapTokensForETH(uint256 tokenAmount, address[] path);
    event LiquidityAdded(uint256 amountTokenA, uint256 amountETH);
    event ContractSwapEnabledUpdated(bool enabled);

    modifier lockTheSwap {
        inSwap = true;
        _;
        inSwap = false;
    }

    constructor (string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = 18;
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

    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool) {
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

    function _transfer(address sender, address recipient, uint256 amount) internal virtual {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");
        bool buy = false;
        bool sell = false;
        bool other = false;
        if (isPair[sender]) {
            buy = true;
        } else if (isPair[recipient]) {
            sell = true;
        } else {
            other = true;
        }

        _beforeTokenTransfer(sender, recipient, amount);
        if (!isExcludedFromFee[sender] && !isExcludedFromFee[recipient]) {
            require(isTradingEnabled, "ERC20: Trading is not enabled yet..");
                if (sell) {
                    if (!inSwap) {
                        if (contractSwapEnabled) {
                            uint256 contractTokenBalance = balanceOf(address(this));
                            if (contractTokenBalance >= swapThreshold) {
                                uint256 swapAmt = swapAmount;
                                if (piContractSwapsEnabled) { swapAmt = (balanceOf(lpPair) * piSwapPercent); }
                                if (contractTokenBalance >= swapAmt) { contractTokenBalance = swapAmt; }
                                contractSwap(contractTokenBalance);
                            }
                        }
                    }
                }
                if (!isPair[sender] && !isPair[recipient]) {
                    uint256 fee = amount.mul(transferFee).div(100);                   
                    amount = amount.sub(fee);
                    _balances[sender] = _balances[sender].sub(fee, "ERC20: transfer amount exceeds balance");
                    _balances[address(this)] = _balances[address(this)].add(fee);
                    emit Transfer(sender, address(this), fee);
                }
                if (isPair[sender]) {
                    uint256 fee = amount.mul(buyFee).div(100);
                    amount = amount.sub(fee);
                    _balances[sender] = _balances[sender].sub(fee, "ERC20: transfer amount exceeds balance");
                    _balances[address(this)] = _balances[address(this)].add(fee);
                    emit Transfer(sender, address(this), fee);
                }
                if (isPair[recipient]) {
                    uint256 fee = amount.mul(sellFee).div(100);                  
                    amount = amount.sub(fee);
                    _balances[sender] = _balances[sender].sub(fee, "ERC20: transfer amount exceeds balance");
                    _balances[address(this)] = _balances[address(this)].add(fee);
                    emit Transfer(sender, address(this), fee);
                }
        }
        
        _balances[sender] = _balances[sender].sub(amount, "ERC20: transfer amount exceeds balance");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
    }

    function contractSwap(uint256 contractTokenBalance) internal lockTheSwap {

        if(_allowances[address(this)][address(uniswapRouter)] != type(uint256).max) {
            _allowances[address(this)][address(uniswapRouter)] = type(uint256).max;
        }
        
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapRouter.WETH();

        try uniswapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            contractTokenBalance,
            0,
            path,
            address(this),
            block.timestamp
        ) {} catch {
            return;
        }

        uint256 amtBalance = address(this).balance;
        bool success;
        uint256 developmentBalance = amtBalance;
        (success,) = _taxWallets.development.call{value: developmentBalance, gas: 35000}("");
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

        _balances[account] = _balances[account].sub(amount, "ERC20: burn amount exceeds balance");
        _totalSupply = _totalSupply.sub(amount);
        emit Transfer(account, address(0), amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _setupDecimals(uint8 decimals_) internal {
        _decimals = decimals_;
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual { }
}