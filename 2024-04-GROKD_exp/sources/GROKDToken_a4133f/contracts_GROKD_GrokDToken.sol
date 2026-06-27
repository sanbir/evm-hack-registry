// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;
import "@openzeppelin/contracts@5.0.2/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts@5.0.2/access/Ownable.sol"; 
import "@openzeppelin/contracts@5.0.2/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts@4.9/utils/math/SafeMath.sol";

contract GROKDToken is ERC20,Ownable,ERC20Pausable {
    using SafeMath for uint256;

    mapping(address=>bool) public isExcludeFee;
    mapping(address=>bool) public automatedMarketMakerPairs;

    address public immutable WETH;
    address public immutable basePair;

    address public foundationAddress;
    address public labAddress;
    address public marketAddress;
    address public manager;
    
    uint256 public sellFee;
    uint256 public buyFee;

    ISwapRouter public immutable SwapRouter;
        
    address public LiquiditySharePool;

    bool public launched;

    bool inSwap;

    modifier swapping(){
        inSwap=true;
        _;
        inSwap=false;
    }

    constructor() ERC20("GROKD","GROKD") Ownable(msg.sender){
        foundationAddress=0x80F68A60f403691b8b426832816667cC68ac78e5;
        labAddress=0xC20e1671ABFcd8998DFF7EbDADA96363C4DAdDF6;
        marketAddress=0xcFf994BB6a1DdF2c9b9b1Bbfabe66592f5d6f544;
        manager=labAddress;
        
        SwapRouter=ISwapRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        WETH=SwapRouter.WETH();
        
        sellFee=35;
        buyFee=35;
        
        basePair=ISwapFactory(SwapRouter.factory()).createPair(WETH,address(this));
        automatedMarketMakerPairs[basePair]=true;
        
        isExcludeFee[msg.sender]=true;
        isExcludeFee[foundationAddress]=true;
        
        IERC20(WETH).approve(address(SwapRouter), type(uint256).max);
        _approve(address(this),address(SwapRouter),type(uint256).max);

        _mint(foundationAddress, 2100000e18);
    }

    receive() external payable { }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }


    function _update(address from,address to,uint256 amount) internal override(ERC20,ERC20Pausable) {
        
        if(inSwap||isExcludeFee[from]||isExcludeFee[to]){
            return super._update(from, to, amount);
        }

        require(launched,"ERC20: require launched"); 
        
        (bool isSell,bool isBuy)=isSwap(from, to);

        if(isBuy){
            uint256 fees=amount.mul(buyFee).div(1000);
            super._update(from, to, amount.sub(fees));
            return super._update(from, address(this), fees);
        }
        
        if(isSell){ 
            uint256 fees=amount.mul(sellFee).div(1000);
            super._update(from, address(this), fees);
            process();
            return super._update(from, to, amount.sub(fees));
        }
        
        return super._update(from, to, amount);
        
    }

    function process() internal swapping {
        uint256 balance=balanceOf(address(this));
        if(balance<10e18){
            return;
        }

        uint256 deadAmount=balance.div(7);
        super._update(address(this), address(0xDead), deadAmount);

        uint256 swapAmount=balance.sub(deadAmount);

        address[] memory path=new address[](2);
        path[0]=address(this);
        path[1]=WETH;
        SwapRouter.swapExactTokensForETH(swapAmount,0,path,address(this),block.timestamp);

        uint256 bnbAmount=payable(this).balance;

        uint256 rewardAmount=bnbAmount.div(2);
        
        payable(labAddress).transfer(rewardAmount.div(10));
        payable(foundationAddress).transfer(rewardAmount.div(2));
        payable(marketAddress).transfer(rewardAmount.mul(4).div(10));

        try IFund(LiquiditySharePool).fund{value:rewardAmount}() {} catch{}
    }

    function isSwap(address from,address to) public view returns(bool isSell,bool isBuy){
        if(automatedMarketMakerPairs[from]){
            return (false,true);
        }else if(automatedMarketMakerPairs[to]){
            return (true,false);
        }

        if(isContract(from)){
            try ISwapPair(from).token0()  {
                if(ISwapPair(from).token0()==address(this)||ISwapPair(from).token1()==address(this)){
                    return (false,true);
                }else{
                    return (true,false);
                }
            } catch {}
        }   
        
        if(isContract(to)){
            try ISwapPair(to).token0()  {
                if(ISwapPair(to).token0()==address(this)||ISwapPair(to).token1()==address(this)){
                    return (true,false);
                }else{
                    return (false,true);
                }
            } catch {}
        }
    
    }

    function isContract(address addr) internal view returns (bool) {
        uint size;
        assembly { size := extcodesize(addr) }
        return size > 0;
    }

    function setAutomatedMarketMakerPairs(address _pair,bool _isPair) external onlyOwner {
        automatedMarketMakerPairs[_pair]=_isPair;
    }

    function multiSetExcludeFee(address[] memory users,bool isExclude) external onlyOwner {
        for(uint i;i<users.length;i++){
            isExcludeFee[users[i]]=isExclude;
        }
    }

    function setFees(uint256 buy,uint256 sell) external onlyOwner {
        sellFee=sell;
        buyFee=buy;
    }

    function launch(uint256 buy,uint256 sell) external onlyOwner {
        require(!launched,"err launch status");
        sellFee=sell;
        buyFee=buy;
        launched=true;
    }

    function setLiquiditySharePool(address addr) external onlyOwner {
        LiquiditySharePool=addr;
        isExcludeFee[addr]=true;
    }

    function setAddress(uint8 _type,address to) external {
        require(msg.sender==manager,"err permission");
        if(_type==1){
            labAddress=to;
        }else if(_type==2){
            foundationAddress=to;
        }else if(_type==3){
            marketAddress=to;
        }else if(_type==4){
            manager=to;
        }
    }
}

interface IFund {
    function fund() external payable ;
}


interface ISwapPair is IERC20{
    function factory() external pure returns (address);
    
    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function sync() external;
}

interface ISwapFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);

    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface ISwapRouter {
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
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);    
}
