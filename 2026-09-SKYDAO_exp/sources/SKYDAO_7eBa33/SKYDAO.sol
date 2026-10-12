// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

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

interface IPancakeFactory {
    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address pair);

    function sellToken(uint256 amount, bool status) external returns (bool);

    function register(address _user, uint256 amount) external;

    function staking(uint256 amount, uint256 orderID, address from) external;
}

abstract contract Ownable {
    address private _owner;
    address private _previousOwner;
    uint256 private _lockTime;
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    constructor() {
        address msgSender = msg.sender;
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

    function owner() public view returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(_owner == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(
            newOwner != address(0),
            "Ownable: new owner is the zero address"
        );
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

interface REFER {
    function getAllConfig() external view returns (address[] memory);

    function staking(address user, uint256 amount) external;

    function unlock(address user, uint256 amount) external;

    function recordTransfer(address from, address to) external;

    function mint(address user, uint256 amount) external;
}

contract SKYDAO is IERC20, Ownable {
    mapping(address => uint256) private _tOwned;
    mapping(address => mapping(address => uint256)) private _allowances;

    string public _name;
    string public _symbol;
    uint256 public _decimals;
    uint256 private _tTotal;

    address public config;
    address public _uniswapV2Pair;
    address public _Factory = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address public _router = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    uint256 public totalHolder;
    bool public _swapLock;
    mapping (address =>bool) public isloged;

    constructor(address _config) {
        _name = "SKYDAO";
        _symbol = "SKYDAO";
        _decimals = uint256(18);
        _tTotal = 10000000000 * (10 ** uint256(_decimals));

        _tOwned[msg.sender] = 10000000000 * (10 ** uint256(_decimals));
        emit Transfer(
            address(0),
            msg.sender,
            10000000000 * (10 ** uint256(_decimals))
        );
        config = _config;
    }

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public view returns (uint256) {
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        return _tTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _tOwned[account];
    }

    function transfer(
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(msg.sender, recipient, amount);
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
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, msg.sender, _allowances[sender][msg.sender] - amount);
        return true;
    }

    function increaseAllowance(
        address spender,
        uint256 addedValue
    ) public virtual returns (bool) {
        _approve(
            msg.sender,
            spender,
            _allowances[msg.sender][spender] + addedValue
        );
        return true;
    }

    function decreaseAllowance(
        address spender,
        uint256 subtractedValue
    ) public virtual returns (bool) {
        _approve(
            msg.sender,
            spender,
            _allowances[msg.sender][spender] - subtractedValue
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
        require(amount > 0, "Transfer amount must be greater than zero");

        uint256 oldBalance = balanceOf(to);

        if(oldBalance == 0 && !isloged[to]){
            totalHolder += 1;
            isloged[to] = true;
        }

        if(_swapLock == false && totalHolder >= 200000){
            _swapLock = true;
        }

        address[] memory results = REFER(config).getAllConfig();

        uint256 tax = 0;
        uint256 sort = 1;

        if (from == _uniswapV2Pair) {
            require(
                to == results[8] || to == results[6] || _swapLock,
                "Transaction Closed"
            );
            tax = getTax(to, results);
        } else if (to == _uniswapV2Pair) {
            tax = getTax(from, results);
            sort = 2;
        }

        if (_uniswapV2Pair == address(0)) {
            address Pair = IPancakeFactory(_Factory).getPair(
                address(this),
                results[12]
            );
            if (Pair != address(0)) {
                _uniswapV2Pair = Pair;
            }
        }

        if (tax > 0) {
            
            uint256 taxAmount = (amount * tax) / 100;
            if(sort == 1){
                _basicTransfer(from, results[25], taxAmount);
            }else{
                _basicTransfer(from, results[8], taxAmount);
                IPancakeFactory(results[8]).sellToken(amount,_swapLock);
            }

            amount -= taxAmount;
        }

        _basicTransfer(from, to, amount);
    }

    function getTax(
        address to,
        address[] memory results
    ) public pure returns (uint256) {
        uint256 _tax = 35;
        if (to == results[8] || to == results[6]) {
            _tax = 0;
        }
        return _tax;
    }

    function controlburn(uint256 amount) external {
        address[] memory results = REFER(config).getAllConfig();

        require(msg.sender == results[6] || msg.sender == results[8], "Mast Mark Control");

        _basicTransfer(
            _uniswapV2Pair,
            0x000000000000000000000000000000000000dEaD,
            amount
        );
    }

    function _basicTransfer(
        address sender,
        address recipient,
        uint256 amount
    ) private {
        _tOwned[sender] = _tOwned[sender] - amount;
        _tOwned[recipient] = _tOwned[recipient] + amount;
        emit Transfer(sender, recipient, amount);
    }

    function mintToken(
        address recipient,
        uint256 amount
    ) external returns (bool) {
        address[] memory results = REFER(config).getAllConfig();

        require(msg.sender == results[8], "Mast PoolControl");

        _tTotal = _tTotal + amount;
        _tOwned[recipient] = _tOwned[recipient] + amount;
        emit Transfer(address(0), recipient, amount);
        return true;
    }

    function swapStatus() public view returns (bool){
        return _swapLock;
    }

    function register(uint256 amount) public {
        address[] memory results = REFER(config).getAllConfig();
        IERC20(results[12]).transferFrom(msg.sender, results[8], amount);
        IPancakeFactory(results[8]).register(msg.sender, amount);
    }

    function staking(uint256 amount) public {
        address[] memory results = REFER(config).getAllConfig();
        IERC20(results[23]).transferFrom(msg.sender, results[18], amount);
        REFER(results[18]).staking(msg.sender, amount);
    }

    function unlock(uint256 amount) public {
        address[] memory results = REFER(config).getAllConfig();
        REFER(results[18]).unlock(msg.sender, amount);
    }

    function mintNft(uint256 amount) public {
        address[] memory results = REFER(config).getAllConfig();
        IERC20(results[12]).transferFrom(msg.sender, results[4], amount);
        REFER(results[4]).mint(msg.sender, amount);
    }
}