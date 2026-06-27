// SPDX-License-Identifier: MIT

pragma solidity >= 0.8.4;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import '@openzeppelin/contracts/utils/Address.sol';

interface ISwapFactory {
    function getPair(address token0,address token1) external view returns(address);
}

contract BBG is Ownable, ERC20Permit {

    using Address for address;

    uint256 private constant TOTAL_SUPPLY = 100_000_000 * 1e18;
    uint256 public constant RATE_PERCISION = 10_000;
    uint256 public buyFeeRate = 300;
    uint256 public sellFeeRate = 600;

    mapping(address => bool) public isOtherSwapPair;

    address public feeTo;
    address public usdt;
    address public wbnb;
    address public pancakeSwapFactory;

    constructor( address _feeAddress ) Ownable(msg.sender) ERC20("BBG Token", "BBG") ERC20Permit("BBG Token"){
        uint256 chainId = block.chainid;
        if ( chainId == 56 ) {
            // mainnet
            usdt = address(0x55d398326f99059fF775485246999027B3197955);
            wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
            pancakeSwapFactory = address(0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73);
        } else if ( chainId == 97 ) {
            // testnet
            usdt = address(0x894040DCAb6F356B7e3FDC6914A8F765b95bbc6a);
            wbnb = address(0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd);
            pancakeSwapFactory = address(0xB7926C0430Afb07AA7DEfDE6DA862aE0Bde767bc);
        }
        feeTo = address(_feeAddress);

	_mint(msg.sender, TOTAL_SUPPLY);
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        __transfer(_msgSender(), recipient, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        __transfer(sender, recipient, amount);

        uint256 currentAllowance = allowance(sender, _msgSender());
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");

	_spendAllowance(sender, _msgSender(), amount);

        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public returns (bool) {
        _approve(_msgSender(), spender, allowance(_msgSender(), spender) + addedValue, true);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public returns (bool) {
        uint256 currentAllowance = allowance(_msgSender(), spender);
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        unchecked {
            _approve(_msgSender(), spender, currentAllowance - subtractedValue, true);
        }
        return true;
    }

    function __transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal {

        _beforeTokenTransfer(sender, recipient, amount);

        uint recipientAmount = amount;
        bool isBuy = isSwapPair(sender);
        bool isSell = isSwapPair(recipient);
        if(recipient != address(0) && (isBuy || isSell)){
            uint feeRate = isBuy ? buyFeeRate : sellFeeRate;
            uint feeAmount = amount * feeRate / RATE_PERCISION;
            recipientAmount -= feeAmount;
            _takeFee(sender, feeTo, feeAmount);
        }
        
	_transfer(sender, recipient, recipientAmount);

        _afterTokenTransfer(sender, recipient, amount);
    }

    function _takeFee(address _from, address _to, uint _fee) internal {
        if(_fee > 0){
	    _transfer(_from, _to, _fee);
        }
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal {}

    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal {}

    function isSwapPair(address pair) public view returns(bool){
        if(pair == address(0) || pancakeSwapFactory == address(0)){
            return false;
        }

        return ISwapFactory(pancakeSwapFactory).getPair(address(this), usdt) == pair 
            || ISwapFactory(pancakeSwapFactory).getPair(address(this), wbnb) == pair 
            || isOtherSwapPair[pair];
    }

    function burn(uint amount) external returns (uint256){
	_burn(_msgSender(), amount);
	return amount;
    }

    function addOtherSwapPair(address _swapPair) external onlyOwner {
        require(_swapPair != address(0),"_swapPair can not be address 0");
        isOtherSwapPair[_swapPair] = true;
    }

    function removeOtherSwapPair(address _swapPair) external onlyOwner {
        require(_swapPair != address(0),"_swapPair can not be address 0");
        isOtherSwapPair[_swapPair] = false;
    }

    // max 10%
    function setBuyFeeRate(uint _rate) external onlyOwner {
        require(_rate <= 1000, "rate too large");
        buyFeeRate = _rate;
    }

    // max 10%
    function setSellFeeRate(uint _rate) external onlyOwner {
        require(_rate <= 1000, "rate too large");
        sellFeeRate = _rate;
    }

    function setFeeTo(address _feeTo) external onlyOwner {
	require(_feeTo != address(0), "invalid address");
        feeTo = _feeTo;
    }
}
