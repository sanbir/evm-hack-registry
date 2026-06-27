// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IUniswapV2Router01 {
    function factory() external pure returns (address);
}

interface IUniswapV2Router02 is IUniswapV2Router01 {
    // function removeLiquidityETHSupportingFeeOnTransferTokens( address token, uint liquidity, uint amountTokenMin, uint amountETHMin, address to, uint deadline) external returns (uint amountETH);
    // function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(address token, uint liquidity, uint amountTokenMin,  uint amountETHMin, address to,uint deadline, bool approveMax, uint8 v, bytes32 r, bytes32 s) external returns (uint amountETH);
    // function swapExactTokensForTokensSupportingFeeOnTransferTokens( uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external;
    // function swapExactETHForTokensSupportingFeeOnTransferTokens( uint amountOutMin, address[] calldata path,address to,uint deadline) external payable;
    // function swapExactTokensForETHSupportingFeeOnTransferTokens( uint amountIn, uint amountOutMin, address[] calldata path,address to,uint deadline) external;
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Pair {
    function factory() external view returns (address);
}



library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {uint256 c = a + b;require(c >= a, "SafeMath: addition overflow");return c;}
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {return sub(a, b, "SafeMath: subtraction overflow");}
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {require(b <= a, errorMessage);uint256 c = a - b; return c;}
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {if (a == 0) {return 0;}uint256 c = a * b;require(c / a == b, "SafeMath: multiplication overflow");return c;}
    function div(uint256 a, uint256 b) internal pure returns (uint256) {return div(a, b, "SafeMath: division by zero");}
    // assert(a == b * c + a % b); // There is no case in which this doesn't hold
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {require(b > 0, errorMessage);uint256 c = a / b;return c;}
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {return mod(a, b, "SafeMath: modulo by zero");}
    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) { require(b != 0, errorMessage);return a % b;}
}

contract ERC20TGC is Ownable, ERC20{
    using SafeMath for uint256;
    mapping(address => bool) hei;
    mapping(address => bool) bai;
    IUniswapV2Router02 public uniswapV2Router;
    IUniswapV2Pair public uniswapV2Pair;
    mapping(address => bool) isUPair;

    address deadAddr = address(0x000000000000000000000000000000000000dEaD);
    // address dex =  address(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    // address usdt =  address(0xc2132D05D31c914a87C6611C10748AEb04B58e8F);
    address dex =  address(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    address usdt =  address(0x55d398326f99059fF775485246999027B3197955);
    // address dex =  address(0xB6BA90af76D139AB3170c7df0139636dB6120F7e);
    // address usdt =  address(0xEdA5dA0050e21e9E34fadb1075986Af1370c7BDb);
    address tradAddr = address(0x7367E49979e1b3e616976729Bef602C3823BCACC);
    constructor() ERC20("TGC", "TGC") {
        address _owner = address(0x5B22F2800C7156706EB35b65737247ae1Cf419C9);
        bai[_owner] = true;
        bai[address(this)] = true;
        _mint(_owner, 10_2400_0000 * 10 ** decimals());
        _initSwap();
        _transferOwnership(address(0));
    }
    
    function isBai(address addr) private view returns (bool) {
        return bai[address(addr)];
    }
    function isPair(address addr) private view returns(bool){
        return address(uniswapV2Pair) == addr;
    }
    function calcFmt(uint256 amount, uint256 fee) private pure returns (uint256){
        if (amount <= 0)return 0;
        if (fee <= 0)return amount;
        return amount.mul(fee).div(100);
    }
    function _initSwap() private {
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(dex);
        uniswapV2Router = _uniswapV2Router;
        address _uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory()).createPair(address(this), address(usdt));
        uniswapV2Pair = IUniswapV2Pair(_uniswapV2Pair);
        isUPair[_uniswapV2Pair] = true;
    }


    function _transfer(address from, address to, uint256 amount) internal override {
        require(from != address(0), "TOKEN: transfer from the zero address");
        require(to != address(0), "TOKEN: transfer to the zero address");
        if(amount == 0) {return super._transfer(from, to, 0);}

        bool takeFee;
        if (isBai(from) || isBai(to))takeFee = true;
        if (!takeFee) {
            if(isPair(to)){ //sell
                uint256 _dead_amt = calcFmt(amount,1);
                uint256 _trad_amt = calcFmt(amount,2);
                super._transfer(from, deadAddr, _dead_amt);
                super._transfer(from, tradAddr, _trad_amt);
                amount = amount.sub(_dead_amt).sub(_trad_amt);
            }
        }
        super._transfer(from, to, amount);
    }
}