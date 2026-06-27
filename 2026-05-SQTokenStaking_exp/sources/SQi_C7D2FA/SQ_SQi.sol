// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

interface IUniswapV2Pair {

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

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

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

interface IUniswapV2Factory {

    function getPair(address tokenA, address tokenB)
    external
    view
    returns (address pair);

    function allPairs(uint256) external view returns (address pair);

    function allPairsLength() external view returns (uint256);

    function createPair(address tokenA, address tokenB)
    external
    returns (address pair);

    function feeTo() external view returns (address);
}

interface IUniswapV2Router01 {
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
    )
    external
    returns (
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );

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
    returns (
        uint256 amountToken,
        uint256 amountETH,
        uint256 liquidity
    );

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountToken, uint256 amountETH);

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountA, uint256 amountB);

    function removeLiquidityETHWithPermit(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountToken, uint256 amountETH);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapTokensForExactETH(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapETHForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}

interface IUniswapV2Router02 is IUniswapV2Router01 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

library EnumerableSet {
    struct Set {
        bytes32[] _values;
        mapping(bytes32 => uint256) _indexes;
    }

    function _add(Set storage set, bytes32 value) private returns (bool) {
        if (!_contains(set, value)) {
            set._values.push(value);
            set._indexes[value] = set._values.length;
            return true;
        } else {
            return false;
        }
    }

    function _remove(Set storage set, bytes32 value) private returns (bool) {
        uint256 valueIndex = set._indexes[value];

        if (valueIndex != 0) {
            uint256 toDeleteIndex = valueIndex - 1;
            uint256 lastIndex = set._values.length - 1;

            if (lastIndex != toDeleteIndex) {
                bytes32 lastvalue = set._values[lastIndex];
                set._values[toDeleteIndex] = lastvalue;
                set._indexes[lastvalue] = valueIndex;
            }

            set._values.pop();

            delete set._indexes[value];

            return true;
        } else {
            return false;
        }
    }

    function _contains(Set storage set, bytes32 value)
        private
        view
        returns (bool)
    {
        return set._indexes[value] != 0;
    }

    function _length(Set storage set) private view returns (uint256) {
        return set._values.length;
    }

    function _at(Set storage set, uint256 index)
        private
        view
        returns (bytes32)
    {
        return set._values[index];
    }

    function _values(Set storage set) private view returns (bytes32[] memory) {
        return set._values;
    }

    struct AddressSet {
        Set _inner;
    }

    function add(AddressSet storage set, address value)
        internal
        returns (bool)
    {
        return _add(set._inner, bytes32(uint256(uint160(value))));
    }

    function remove(AddressSet storage set, address value)
        internal
        returns (bool)
    {
        return _remove(set._inner, bytes32(uint256(uint160(value))));
    }

    function contains(AddressSet storage set, address value)
        internal
        view
        returns (bool)
    {
        return _contains(set._inner, bytes32(uint256(uint160(value))));
    }

    function length(AddressSet storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

    function at(AddressSet storage set, uint256 index)
        internal
        view
        returns (address)
    {
        return address(uint160(uint256(_at(set._inner, index))));
    }

    function values(AddressSet storage set)
        internal
        view
        returns (address[] memory)
    {
        bytes32[] memory store = _values(set._inner);
        address[] memory result;

        assembly {
            result := store
        }

        return result;
    }
}

interface INodeDividend {
    function dividend(uint256 amount) external;
}

contract TokenReceiver {
    constructor(address _father, address reToken) {
        IERC20(reToken).approve(_father, ~uint256(0));
    }
}

contract SQi is Ownable, ERC20 {
    using EnumerableSet for EnumerableSet.AddressSet;
    IUniswapV2Router02 public uniswapV2Router;
    uint256 private constant MAX = ~uint256(0);

    address public _uniswapV2Pair;
    address private router = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address private USDT = 0x55d398326f99059fF775485246999027B3197955;    
    address private _destroyAddress = 0x000000000000000000000000000000000000dEaD;    

    address public GOI;
    address public feeAddress = 0x4F0DA193480CE10aA4974460ccA39D44a3e34Cd7;
    address public nodeDividendAddress;
    address public STAKING;

    mapping(address => bool) public _isPairs;
    mapping(address => bool) public isExcludedFromFees;
    mapping(address => bool) public isExcludedFromFeesVip;
    mapping(address => bool) public _blackList;
    mapping(address => uint256) public bookUsd;
    
    bool public _startTrading = false;
    uint256 public _minSwapLp = 5_000_000e18;

    uint256 public prfTax = 10; //10%

    uint256 public swapTokensAtAmount = 1e18;
    uint public _swapEveryTime = 30; //交易冷却时间
    uint private reserveAmount = 1e15;
    uint private _swapEveryMax = 20000e18; //最大交易金额 20000
    address public tokenRec;
    address public tokenGoiRec;
    uint256 public goiDestoryAmounts;
    
    constructor(address owner) Ownable(owner) ERC20("SQi", "SQi"){
        require(USDT < address(this),"Token small");

        TokenReceiver _tc = new TokenReceiver(address(this), USDT);
        tokenRec = address(_tc);        

        uniswapV2Router = IUniswapV2Router02(router);        
        _uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory()).createPair(address(this), USDT); 
        _isPairs[_uniswapV2Pair] = true;

        _approve(address(this), router, MAX);
        IERC20(USDT).approve(router, MAX);

        address tokenOwner = 0x485Dd55a6169B390A46Ac8ea778c40eB3bf43E67;

        isExcludedFromFeesVip[address(this)] = true;
        isExcludedFromFeesVip[owner] = true;
        isExcludedFromFeesVip[tokenOwner] = true;
        isExcludedFromFeesVip[tokenRec] = true;

        _twapInit();

        uint total = 21_000_000 * 1e18;        
        _mint(tokenOwner, total);
    }

    function setTokenAdd(uint256 category, address data) public onlyOwner {
        if (category == 1) {
            GOI = data;
            TokenReceiver _tc = new TokenReceiver(address(this), GOI);
            tokenGoiRec = address(_tc);
        }
        if (category == 2) {
            nodeDividendAddress = data;
            isExcludedFromFeesVip[nodeDividendAddress] = true;
        }
        if (category == 3) feeAddress = data;
        if (category == 4){
            STAKING = data;
            isExcludedFromFeesVip[STAKING] = true;
        } 
    }    

    function setConfig(uint256 category, uint256 data) external onlyOwner {
        if(category == 1) swapTokensAtAmount = data;
        if(category == 2) _minSwapLp = data;
        if(category == 3) prfTax = data;
        if(category == 5) reserveAmount = data;
        if(category == 6) _swapEveryMax = data;
    }
    
    function excludeFromFees(address account, bool excluded) public onlyOwner {
        isExcludedFromFees[account] = excluded;
    }
	
    function excludeMultipleAccountsFromFees(address[] calldata accounts, bool excluded) public onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            isExcludedFromFees[accounts[i]] = excluded;
        }
    }

    function excludeVipFromFees(address account, bool excluded) public onlyOwner {
        isExcludedFromFeesVip[account] = excluded;
    }

    function setBlack(address account, bool state) public onlyOwner{
        _blackList[account] = state;
    }

    function setMultipleBlackList(address[] calldata accounts, bool state) public onlyOwner{
        for(uint256 i = 0; i < accounts.length; i++) {
            _blackList[accounts[i]] = state;
        }
    }

    bool reserveEnable = true;
    function setReserveEnable(bool status) external  onlyOwner{
        reserveEnable = status;
    }

    event TranserFeeLog(uint256 amount,uint256 tax,uint256 prf);

    function _update(address from, address to, uint256 amount) internal override {
        if (
            IERC20(USDT).balanceOf(_uniswapV2Pair) >= _minSwapLp &&
            _startTrading == false
        ) {
            _startTrading = true;
        }  

        if(isExcludedFromFeesVip[to] || isExcludedFromFeesVip[from]){
            super._update(from, to, amount);
            return ;
        }

        _twapMaybeUpdate();

        if(isExcludedFromFees[to] || isExcludedFromFees[from]){
            super._update(from, to, amount);
            return ;
        }

        require(!_blackList[from] && !_blackList[to], "refuse address"); 

        if (!inSwap && 
            _isPairs[to]) 
        {
            uint256 nodeFee = balanceOf(nodeDividendAddress);
            if(nodeFee >= swapTokensAtAmount){        
                super._update(nodeDividendAddress, address(this), nodeFee);
                uint256 usdtAmount = swapTokenForUsdt(nodeFee, nodeDividendAddress);
                INodeDividend(nodeDividendAddress).dividend(usdtAmount);
            }
            if(goiDestoryAmounts >= swapTokensAtAmount){                
                swapTokenForGoi(goiDestoryAmounts, _destroyAddress);
                goiDestoryAmounts = 0;
            }            
        }

        bool isBuy;
        bool isSell;
        uint256 taxAmount;
        uint256 uValue;
        uint256 prfFee = 0;

        if(_isPairs[from]){//buy
            isBuy = true;
            if (!_startTrading) {
                revert("Not start trade");
            }            
            uint256 usdtAmount = getSwapValueUSDT(amount);

            if (usdtAmount > _swapEveryMax) revert("Exceeding the maximum limit");   

            taxAmount = takeFee(from, amount);
            //计算持仓成本
            _pnl_onBuy(to, amount - taxAmount);            
        }else if(_isPairs[to]){//sell
            
            isSell = true;                        
            taxAmount = takeFee(from, amount);

            uValue = _pnl_tokenToUsd(amount - taxAmount); 
            //获取收益 代币数量
            prfFee = _pnl_consumeCost(from, uValue);

            if (
                lpBurnEnabled &&
                block.timestamp >= lastLpBurnTime + lpBurnFrequency &&
                !inSwap
            ) {
                autoBurnLPTokens();
            }
        }

        emit TranserFeeLog(amount, taxAmount, prfFee);

        if ( prfFee > 0) {
            takePrfFee(from, prfFee);
            amount = amount - prfFee;
        }  
        
        if(isBuy || isSell) {
            _antiFlashloanGuard(from,to,isBuy,isSell);            
        }  

        amount = amount - taxAmount;

        if(reserveEnable){
            if(balanceOf(from) - amount < reserveAmount && amount > reserveAmount){
                amount = balanceOf(from) - reserveAmount;
            }
        }
        super._update(from, to, amount);          
    }  

    function takeFee(address from,uint256 amount) internal returns(uint256) {//总共1.79%
        uint256 fee = amount * 179 / 10000;
        super._update(from, feeAddress, fee * 20 / 100); //20%
        super._update(from, _destroyAddress, fee * 20 / 100); //20%
        goiDestoryAmounts = goiDestoryAmounts + fee * 20 / 100;
        super._update(from, address(this), fee * 20 / 100); //20%
        super._update(from, nodeDividendAddress, fee * 40 / 100); //40%
        return fee;
    }

    event PreFeeLog(uint256 total,uint256 prf,uint256 nft,uint256 level);

    function takePrfFee(address from,uint256 prfFee) internal  {//10%
        super._update(from, address(this), prfFee);
        super._update(address(this), feeAddress, prfFee * 20 / 100); //20%
        super._update(address(this), _destroyAddress, prfFee * 20 / 100); //20%
        goiDestoryAmounts = goiDestoryAmounts + prfFee * 40 / 100;
        super._update(address(this), nodeDividendAddress, prfFee * 20 / 100); //20%
    }

    bool public lpBurnEnabled = true;
    uint256 public lpBurnFrequency = 24 hours;//TODO 
    uint256 public lastLpBurnTime;
    uint256 public percentForLPBurn = 50; //万分比
    uint256 public minLastBurnAmount = 1e18;
    bool public lpBurnEnd = false;
    
    function setAutoLPBurnSettings(uint256 _frequencyInSeconds, uint256 _percent, uint256 _minLastBurnAmount, bool _Enabled) external onlyOwner {
        lpBurnFrequency = _frequencyInSeconds;
        percentForLPBurn = _percent;
        minLastBurnAmount = _minLastBurnAmount;
        lpBurnEnabled = _Enabled;
    }

    function autoBurnLPTokens() internal lockTheSwap returns (bool) {
        if(lpBurnEnd || (this.balanceOf(_uniswapV2Pair) <= minLastBurnAmount)){
            lpBurnEnd = true;
            return false;
        }
        lastLpBurnTime = block.timestamp;
        uint256 liquidityPairBalance = this.balanceOf(_uniswapV2Pair);
        uint256 amountToBurn = (liquidityPairBalance * percentForLPBurn) / 10000;
        if(liquidityPairBalance - amountToBurn < minLastBurnAmount){
            amountToBurn = liquidityPairBalance - minLastBurnAmount;
        }
        if (amountToBurn > 0) {            
            super._update(_uniswapV2Pair, _destroyAddress, amountToBurn);
            IUniswapV2Pair(_uniswapV2Pair).sync();
            _twapMaybeUpdate();
        }        
        return true;
    }

    function recycle(uint256 amount) external {
        require(STAKING == msg.sender, "cycle");
        uint256 maxBurn = super.balanceOf(_uniswapV2Pair) / 3;
        uint256 burn_amount = amount >= maxBurn ? maxBurn : amount;
        super._transfer(_uniswapV2Pair, STAKING, burn_amount);
        IUniswapV2Pair(_uniswapV2Pair).sync();
        _twapMaybeUpdate();
    }

    function getSwapValueUSDT(
        uint256 amount
    ) public view returns (uint256) {
        if (amount==0) return 0;
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = USDT;
        uint256[] memory price = uniswapV2Router.getAmountsOut(
            amount,
            path
        );
        return price[price.length-1];
    }

    function swapTokenForUsdt(
        uint256 tokenAmount,
        address recv
    ) private lockTheSwap returns(uint256) {
        uint256 before = IERC20(USDT).balanceOf(tokenRec);
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = USDT;
        
        uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            tokenRec,
            block.timestamp
        );
        uint256 _usdtOut = IERC20(USDT).balanceOf(tokenRec) - before;
        IERC20(USDT).transferFrom(tokenRec, recv, _usdtOut);
        return _usdtOut;
    }

    function swapUsdtForToken(
        uint256 usdtAmount,
        address recv
    ) private lockTheSwap returns(uint256) {
        uint256 before = this.balanceOf(tokenRec);
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = address(this);
        
        uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            usdtAmount,
            0,
            path,
            tokenRec,
            block.timestamp
        );
        uint256 _sqiOut = this.balanceOf(tokenRec) - before;
        super._update(tokenRec, recv, _sqiOut);
        return _sqiOut;
    }

    function swapTokenForGoi(
        uint256 tokenAmount,
        address recv
    ) private lockTheSwap returns(uint256) {
        uint256 before = IERC20(GOI).balanceOf(tokenGoiRec);
        address[] memory path = new address[](3);
        path[0] = address(this);
        path[1] = USDT;
        path[2] = GOI;
        
        uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            tokenGoiRec,
            block.timestamp
        );
        uint256 _goiOut = IERC20(GOI).balanceOf(tokenGoiRec) - before;
        IERC20(GOI).transferFrom(tokenGoiRec, recv, _goiOut);
        return _goiOut;
    }

    function withDrawalToken(address token, address _address, uint amount) external onlyOwner {

        IERC20(token).transfer(_address, amount);

    }   

    function _getReserves(address pair) public view returns (uint256 rOther, uint256 rThis, uint256 balanceOther){
        IUniswapV2Pair mainPair = IUniswapV2Pair(pair);
        (uint r0, uint256 r1,) = mainPair.getReserves();

        address tokenOther = mainPair.token0();
        if (tokenOther < address(this)) {
            rOther = r0;
            rThis = r1;
        } else {
            rOther = r1;
            rThis = r0;
        }

        balanceOther = IERC20(tokenOther).balanceOf(pair);
    }

    function _isRemoveLiquidity(address pair,uint256 amount) internal view returns (uint256 liquidity){
        (uint256 rOther, uint256 rThis, uint256 balanceOther) = _getReserves(pair);
        if (balanceOther < rOther) {
            liquidity = (amount * IUniswapV2Pair(pair).totalSupply()) /
            (balanceOf(pair)- amount);
        } else {
            uint256 amountOther;
            if (rOther > 0 && rThis > 0) {
                amountOther = rThis * rOther / (rThis-amount)- rOther;
                require(balanceOther >= amountOther + rOther);
            }
        }
    }

    function calLiquidity(
        address pair,
        uint256 balanceA,
        uint256 amount,
        uint256 r0,
        uint256 r1
    ) private view returns (uint256 liquidity, uint256 feeToLiquidity) {
        uint256 pairTotalSupply = IUniswapV2Pair(pair).totalSupply();
        address feeTo = IUniswapV2Factory(uniswapV2Router.factory()).feeTo();
        bool feeOn = feeTo != address(0);
        uint256 _kLast = IUniswapV2Pair(pair).kLast();
        if (feeOn) {
            if (_kLast != 0) {
                uint256 rootK = Math.sqrt(r0 * r1);
                uint256 rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint256 numerator = pairTotalSupply * (rootK - rootKLast) * 8;
                    uint256 denominator = rootK * 17 + rootKLast*8;
                    feeToLiquidity = numerator / denominator;
                    if (feeToLiquidity > 0) pairTotalSupply += feeToLiquidity;
                }
            }
        }
        uint256 amount0 = balanceA - r0;
        if (pairTotalSupply == 0) {
            if (amount0 > 0) {
                liquidity = Math.sqrt(amount0 * amount) - 1000;
            }
        } else {
            liquidity = Math.min(
                (amount0 * pairTotalSupply) / r0,
                (amount * pairTotalSupply) / r1
            );
        }
    }

    function _isAddLiquidity(address pair,uint256 amount) internal view returns (uint256 liquidity){
        (uint256 rOther, uint256 rThis, uint256 balanceOther) = _getReserves(pair);
        uint256 amountOther;
        if (rOther > 0 && rThis > 0) {
            amountOther = amount * rOther / rThis;
        }
        //isAddLP
        if (balanceOther >= rOther + amountOther) {
            (liquidity,) = calLiquidity(pair, balanceOther, amount, rOther, rThis);
        }
    }

    function isContract(address _address) public view returns (bool) {
        uint32 size;
        assembly {
            size := extcodesize(_address)
        }
        return (size > 24);
    }

    function V2Pair() external view returns (address){
        return _uniswapV2Pair;
    }

    function getReserveU() external view returns (uint112){
        uint256 bal = IERC20(USDT).balanceOf(_uniswapV2Pair);
        return uint112(bal);
    }
    // ================== TWAP: state ==================
    uint256 public  _price0CumulativeLast;
    uint256 public _price1CumulativeLast;
    uint32  public _blockTimestampLast;
    uint224 public _price0AverageUQ112x112; // price of token0 in token1
    uint224 public _price1AverageUQ112x112; // price of token1 in token0
    bool    public  _twapInitialized;

    // 配置：最小观测窗口、最大允许偏离（bps）
    uint32  public twapMinPeriod = 60;     // 60秒窗口（可owner改）
    uint16  public maxDeviationBps = 800;  // 8% 偏离护栏（可owner改）
    // 便捷缓存
    bool    public _isToken0;             // address(this) 是否是 pair 的 token0

    /// Preventing flash loan config
    mapping(address => uint32) public lastTradeBlock;
    mapping(address => uint32) public lastBuyBlock;
    uint32  public minBlocksBeforeSell = 2;   // 买入后至少 2 块后才能卖
    bool    public oneTradePerBlock = true;   // 每地址每块仅一次交易（买/卖/转）

    event PriceDeviationGuard(bool flag, uint256 spotOut, uint256 twapOut);

    // ================== TWAP: init ==================
    function _twapInit() internal {
        if (_twapInitialized) return;
        require(_uniswapV2Pair != address(0), "TWAP: pair not set");
        IUniswapV2Pair pair = IUniswapV2Pair(_uniswapV2Pair);

        _isToken0 = (pair.token0() == address(this)); // 确认本币在pair中的位置
        _price0CumulativeLast = pair.price0CumulativeLast();
        _price1CumulativeLast = pair.price1CumulativeLast();

        ( , , _blockTimestampLast) = pair.getReserves(); // 同步时间戳
        _twapInitialized = true;
    }

    // ================== TWAP: update (call cheap, only updates when window passed) ==================
    function _twapMaybeUpdate() internal {
        if (!_twapInitialized) _twapInit();

        IUniswapV2Pair pair = IUniswapV2Pair(_uniswapV2Pair);

        uint256 price0Cumulative = pair.price0CumulativeLast();
        uint256 price1Cumulative = pair.price1CumulativeLast();

        ( , , uint32 blockTimestamp) = pair.getReserves();

        uint32 timeElapsed = blockTimestamp - _blockTimestampLast; // 溢出在solidity 0.8受保护

        if (timeElapsed < twapMinPeriod) {
            // 窗口未到，保持现有平均价不变（关键点：防同交易/同块操纵）
            return;
        }

        unchecked {
            // 计算窗口平均价，单位为UQ112x112
            _price0AverageUQ112x112 = uint224((price0Cumulative - _price0CumulativeLast) / timeElapsed);
            _price1AverageUQ112x112 = uint224((price1Cumulative - _price1CumulativeLast) / timeElapsed);
        }

        _price0CumulativeLast = price0Cumulative;
        _price1CumulativeLast = price1Cumulative;
        _blockTimestampLast   = blockTimestamp;
    }

    // 将 “本币数量amountIn” 按TWAP折算为 “USDT数量amountOut”
    function _twapTokenToUsd(uint256 amountIn) internal returns (uint256 amountOut) {
        // 更新TWAP（仅在窗口到期才写入）
        _twapMaybeUpdate();

        // 1) 先尝试用 TWAP
        uint256 twapOut = 0;
        if (_price0AverageUQ112x112 != 0 && _price1AverageUQ112x112 != 0) {
            if (_isToken0) {
                twapOut = (uint256(_price0AverageUQ112x112) * amountIn) >> 112;
            } else {
                // FIX: 由 “除以 price1” 改为 “乘以 price1”
                twapOut = (uint256(_price1AverageUQ112x112) * amountIn) >> 112;
            }
        }

        // 2) 现价（回退或做护栏对比）
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = USDT;
        uint[] memory amounts = IUniswapV2Router02(router).getAmountsOut(amountIn, path);
        uint256 spotOut = amounts[1];

        // 3) 选择返回值：优先TWAP；TWAP未就绪则回退现价；启用偏离护栏
        if (twapOut != 0) {
            // 护栏：spot 与 twap 偏离过大时，坚持用 twap（不revert，保持业务连贯）
            if (_deviationTooHigh(spotOut, twapOut)) {
                emit PriceDeviationGuard(false, spotOut, twapOut);
            }
            return twapOut;
        } else {
            // 暖机期：TWAP 尚未就绪时回退现价
            return spotOut;
        }
    }

    // 将 “USDT数量amountIn” 按TWAP折算为 “本币数量amountOut”
    function _twapUsdToToken(uint256 amountIn) internal returns (uint256 amountOut) {
        // 更新TWAP（仅在窗口到期才写入）
        _twapMaybeUpdate();

        // 1) 先尝试用 TWAP
        uint256 twapOut = 0;
        if (_price0AverageUQ112x112 != 0 && _price1AverageUQ112x112 != 0) {
            // if (_isToken0) {
            //     // 本币=token0:  amountToken = amountUSDT / price0
            //     twapOut = (amountIn << 112) / uint256(_price0AverageUQ112x112);
            // } else {
            //     // 本币=token1:  amountToken = amountUSDT * price1
            //     twapOut = (uint256(_price1AverageUQ112x112) * amountIn) >> 112;
            // }

            if (_isToken0) {
                twapOut = (amountIn << 112) / uint256(_price0AverageUQ112x112);
            } else {
                // FIX: 由 “乘以 price1” 改为 “除以 price1”
                twapOut = (amountIn << 112) / uint256(_price1AverageUQ112x112);
            }
        }

        // 2) 现价（回退或做护栏对比）
        address[] memory path = new address[](2);
        path[0] = USDT; 
        path[1] = address(this);
        uint[] memory amounts = IUniswapV2Router02(router).getAmountsOut(amountIn, path);
        uint256 spotOut = amounts[1];

        // 3) 选择返回值：优先TWAP；TWAP未就绪则回退现价；启用偏离护栏
        if (twapOut != 0) {
            if (_deviationTooHigh(spotOut, twapOut)) {
                emit PriceDeviationGuard(true, spotOut, twapOut);
            }
            return twapOut;
        } else {
            // 暖机期：TWAP 尚未就绪时回退现价
            return spotOut;
        }
    }

    // ================== 可选：价格偏离护栏（简洁实现） ==================
    function _deviationTooHigh(uint256 spotOut, uint256 twapOut) internal view returns (bool) {
        if (spotOut == 0 || twapOut == 0) return false;
        uint256 diff = spotOut > twapOut ? (spotOut - twapOut) : (twapOut - spotOut);
        return diff * 10_000 / twapOut > maxDeviationBps; // bps比较
    }

    // ========== 内部工具：价格换算（基于路由报价，近似） ==========
    function _pnl_tokenToUsd(uint256 amountToken) internal returns (uint256 usd) {
        if (bOpenTwap && _twapInitialized) {
            usd = _twapTokenToUsd(amountToken);
            return usd;
        }

        // 第一次部署/未初始化窗口的早期阶段：回退到现价 + 偏离护栏
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = USDT; // 若你是Token/USDT对，改为USDT地址
        // ↑ 如果你已是 Token/USDT 直对，请把上面第二条路径改成 USDT 地址（你合约里应该已有 USDT 变量）

        uint[] memory amounts = IUniswapV2Router02(router).getAmountsOut(amountToken, path);
        usd = amounts[1];
    }    

    function _pnl_usdToToken(uint256 amountUsd) internal returns (uint256 token) {
        if (bOpenTwap && _twapInitialized) {
            token = _twapUsdToToken(amountUsd);
            return token;
        }

        // 早期回退
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = address(this);
        uint[] memory amounts = IUniswapV2Router02(router).getAmountsOut(amountUsd, path);
        token = amounts[1];
    }

    // ========== 买入：把等值USDT计入成本 ==========
    function _pnl_onBuy(address to, uint256 amountAfterFee) internal {
        if (amountAfterFee == 0) return;
        uint256 usd = _pnl_tokenToUsd(amountAfterFee);
        if (usd > 0) {
            bookUsd[to] += usd;
        }
    }    

    // [ADD pnl] 成本按比例扣减：基于“本次从卖家流出的代币 / 卖出前余额”
    function _pnl_consumeCost(address seller, uint256 out) internal returns (uint256 prfFee){
        if (bookUsd[seller] >= out) {
            bookUsd[seller] = bookUsd[seller] - out;
        } else if (bookUsd[seller] < out) {

            prfFee = _pnl_usdToToken((out - bookUsd[seller]) * prfTax / 100);

            bookUsd[seller] = 0;
        }
    }

    /// 同块限频 + 买后 N 块内禁止卖（防同交易闪电贷）
    function _antiFlashloanGuard(address from, address to, bool isBuy, bool isSell) internal {
        if (inSwap) return;
        if (!bAntiFlashloanGuard) return;

        address trader = isBuy ? to : from;  // 只对买方或卖方地址限频
        // 1) 同块限频（对 tx.origin 或对 from/to 做限制）
        if (oneTradePerBlock && !isExcludedFromFees[trader]) {
            require(lastTradeBlock[tx.origin] != block.number, "one trade per block");
            lastTradeBlock[tx.origin] = uint32(block.number);
        }

        // 2) 买后 N 块内禁止卖
        if (isSell && !isExcludedFromFees[from]) {
            require(block.number > lastBuyBlock[from] + minBlocksBeforeSell, "sell too soon after buy");
        }
        if (isBuy && !isExcludedFromFees[to]) {
            lastBuyBlock[to] = uint32(block.number);
        }
    }

    // 管理：可微调窗口与偏离阈值（不影响业务逻辑）
    function setTwapConfig(uint32 _minPeriod, uint16 _maxDevBps) external onlyOwner {
        require(_minPeriod >= 30 && _minPeriod <= 3600, "bad period");
        require(_maxDevBps <= 2_000, "too loose"); // 20% 上限
        twapMinPeriod = _minPeriod;
        maxDeviationBps = _maxDevBps;
    }

    bool private bOpenTwap = true;
    bool private bAntiFlashloanGuard = true;

    function setTwapConfig2(uint256 category,bool flag) external onlyOwner{
        if(category == 1) {bOpenTwap = flag;}
        if(category == 2) {bAntiFlashloanGuard = flag;}
        if(category == 3) {oneTradePerBlock = flag;}
    }

    bool private inSwap;
    modifier lockTheSwap() {
        inSwap = true;
        _;
        inSwap = false;
    }    
}