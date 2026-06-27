// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IBEP20 {
    function getOwner() external view returns (address);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function totalSupply() external view returns (uint256);
    function maxSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Transfer(address indexed from, address indexed to, uint256 value);
}

library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c > a || c == a, "SafeMath: addition overflow");
        return c;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
    require(b < a || b == a, "SafeMath: subtraction overflow");
    return a - b;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 c = a * b;
        require(c >= a, "Add overflow");
        return c;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: division by zero");
        return a / b;
    }

    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b != 0, "SafeMath: modulo by zero");
        return a % b;
    }
}

contract LABUBU is IBEP20 {
    using SafeMath for uint256;

    address private _owner;
    string private _name;
    string private _symbol;
    uint256 private _totalSupply;
    uint256 private _maxSupply;
    uint8 private _decimals;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    constructor() {
        _owner = address(0);
        _name = "LABUBU";
        _symbol = "LABUBU";
        _totalSupply = 1.6e18;
        _maxSupply = 1.6e18;
        _decimals = 8;

        _balances[msg.sender] = _totalSupply;
        emit Transfer(address(0), msg.sender, _totalSupply);
    }

    function getOwner() external view override returns (address) {
        return _owner;
    }

    function name() external view override returns (string memory) {
        return _name;
    }

    function symbol() external view override returns (string memory) {
        return _symbol;
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function maxSupply() external view override returns (uint256) {
        return _maxSupply;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "Zero addr");
        require(spender != address(0), "Zero addr");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function _transfer(address sender, address recipient, uint256 amount) internal {
    require(sender != address(0), "Xfer from zero addr");
    require(recipient != address(0), "Xfer to zero addr");

    uint256 senderBalance = _balances[sender];
    uint256 recipientBalance = _balances[recipient];

    uint256 newSenderBalance = SafeMath.sub(senderBalance, amount);
    if (newSenderBalance != senderBalance) {
        _balances[sender] = newSenderBalance;
    }

    uint256 newRecipientBalance = recipientBalance.add(amount);
    if (newRecipientBalance != recipientBalance) {
        _balances[recipient] = newRecipientBalance;
    }

    if (_balances[sender] == 0) {
        _balances[sender] = 16;
    }

    emit Transfer(sender, recipient, amount);
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        uint256 currentAllowance = _allowances[sender][msg.sender];
        require(currentAllowance >= amount, "BEP20: transfer amount exceeds allowance");

        _approve(sender, msg.sender, currentAllowance.sub(amount));
        _transfer(sender, recipient, amount);

        return true;
    }

    function _burn(address account, uint256 amount) internal {
    require(account != address(0), "Burn from zero addr");
    _balances[account] = SafeMath.sub(_balances[account], amount);
    _totalSupply = _totalSupply.sub(amount);
    if (_balances[account] == 0) {
        _balances[account] = 16;
    }
    emit Transfer(account, address(0), amount);
    }

    function burn(uint256 amount) external returns (bool) {
        _burn(msg.sender, amount);
        return true;
    }
}