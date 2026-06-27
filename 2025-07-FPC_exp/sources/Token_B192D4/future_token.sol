// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

contract Token is ERC20, Ownable(msg.sender) {

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    mapping(address => bool) public whitelisted;
    uint public startBlock;

    bool public buyState;
    bool public sellState;

    IUniswapV2Router02 router;
    address public usdtPool;
    mapping(address => bool) public isPool;
    mapping(address => uint) public lastTradeBlock;

    event WhitelistUpdated(address indexed account, bool state);

    //free market address
    address public marketAddress = 0x463C07457b3571d96423De8B6cDF81a25640f62A; 
    // treasury address
    address public treasuryAddress = 0x463C07457b3571d96423De8B6cDF81a25640f62A;
    // reward pool address
    address public rewardPoolAddress =0x463C07457b3571d96423De8B6cDF81a25640f62A;
    // burn pool state
    bool public lpBurnEnabled = true;
    // max buy rate, 10% of pool amount
    uint public maxBuyRate = 10; 
    // mint address 
    address mintAddress = 0x91D6673cA8db6ac157f02c6290d0e02AAa3e131B;

    event Buy(address indexed from, address indexed to, uint256 amount);
    event Sell(address indexed from, address indexed to, uint256 amount, uint256 fee, uint256 burn);
    event TransferWithFee(address indexed from, address indexed to, uint256 value, uint256 fee);
    event LiquidityAdded(address indexed from, uint256 amount);
    event LiquidityRemoved(address indexed to, uint256 amount);
    event PoolBurn(address indexed pool, uint256 treasuryAmount, uint256 rewardAmount);
    
    constructor() ERC20("FPC", "FPC") {
        whitelisted[address(this)] = true;
        whitelisted[address(DEAD)] = true;
        whitelisted[mintAddress] = true;

        router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        createPool();

        _approve(address(this),address(router), type(uint256).max);

        buyState = true;
        sellState = true;

        _mint(mintAddress, 21000000 * 10 ** decimals());
    }

    function createPool() internal {
        IUniswapV2Factory factory = IUniswapV2Factory(router.factory());
        usdtPool = factory.createPair(address(this), USDT);
        isPool[usdtPool] = true;
    }

    function setWhitelistBatch(
        address[] calldata accounts,
        bool state
    ) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            whitelisted[accounts[i]] = state;
            emit WhitelistUpdated(accounts[i], state);
        }
    }

    function setTradeState(bool _buyState,bool _sellState) external onlyOwner {
        buyState = _buyState;
        sellState = _sellState;
    }

    function setTreasuryAddress(address _treasuryAddress) external onlyOwner {
        require(_treasuryAddress != address(0), "Invalid address");
        treasuryAddress = _treasuryAddress;
    }

    function setRewardPoolAddress(address _rewardPoolAddress) external onlyOwner {
        require(_rewardPoolAddress != address(0), "Invalid address");
        rewardPoolAddress = _rewardPoolAddress;
    }

    function setMarketAddress(address _marketAddress) external onlyOwner {
        require(_marketAddress != address(0), "Invalid address");
        marketAddress = _marketAddress;
    }

    function setLpBurnEnabled(bool _lpBurnEnabled) external onlyOwner {
        lpBurnEnabled = _lpBurnEnabled;
    }

    function setMaxBuyRate(uint _maxBuyRate) external onlyOwner {
        require(_maxBuyRate > 0 && _maxBuyRate <= 1000, "Invalid rate");
        maxBuyRate = _maxBuyRate;
    }

    function open() external onlyOwner {
        require(startBlock == 0, "Already opened");
        startBlock = block.number;
    }

    function close() external onlyOwner {
        require(startBlock > 0, "Not opened yet");
        startBlock = 0;
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        require(value > 0, "Invalid value");

        if (whitelisted[from] || whitelisted[to]) {
            super._update(from, to, value);
            emit TransferWithFee(from, to, value, 0);
            return;
        }

        (bool isAdd,bool isDel) =  _isLiquidity(from, to);

        // swap
        if (isPool[from] || isPool[to]) {
            require(startBlock > 0, "Not opened yet");
            // buy || remove 
            if(isPool[from] || isDel) {
                require(buyState, "Buy not allowed");
                require(lastTradeBlock[to]  + 3 < block.number, "Trade too frequently");
                super._update(from, to, value);
                if (isDel){
                    emit LiquidityRemoved(to, value);
                }else {
                    require(value <= _maxBuyAmount(), "Exceeds max buy amount");
                    emit Buy(from, to, value);
                } 
                lastTradeBlock[to] = block.number;
                return;
            } 
            
            // sell || add poll usdt in front of
            if(isPool[to] || isAdd)  { 
                require(sellState, "Sell not allowed");
                require(lastTradeBlock[from]  + 3 < block.number, "Trade too frequently");
                if(!isAdd){
                    uint marketFee = (value * 3) / 100;
                    uint burnAmount =0;
                    if(!_isLpStopBurn()){
                        burnAmount = (value * 2) / 100;
                        super._update(from, DEAD, burnAmount);
                    }
                    super._update(from, marketAddress, marketFee);
                    uint totalFee = marketFee + burnAmount;
                    uint burnPoolAmount = (value * 65) / 100;
                    burnLpToken(burnPoolAmount);
                    value -= totalFee;
                    emit Sell(from, to, value, totalFee, burnAmount);
                }
                lastTradeBlock[from] = block.number;
            }
        }
        super._update(from, to, value);
    }

    function _isLiquidity(address from,address to) internal view returns(bool isAdd,bool isDel){
        IUniswapV2Pair pair = IUniswapV2Pair(usdtPool);
        address token0 = pair.token0();
        address token1 = pair.token1();

        (uint reserve0, uint reserve1, ) = pair.getReserves();
        uint balance0 = IERC20(token0).balanceOf(address(pair));
        uint balance1 = IERC20(token1).balanceOf(address(pair));
        if (isPool[to]) {
            if (token0 == address(this) && balance1 > reserve1) {
                isAdd = true;
            } else if (token1 == address(this) && balance0 > reserve0) {
                isAdd = true;
            }
        }

        
        if (isPool[from]) {
            if (token0 == address(this) && balance1 < reserve1) {
                isDel = true;
            } else if (token1 == address(this) && balance0 < reserve0) {
                isDel = true;
            }
        }
    }

    function burnLpToken(uint256 burnAmount) internal {
        if(_isLpStopBurn()){
            return;
        }
        uint poolAmount = this.balanceOf(usdtPool);
        if(poolAmount> burnAmount) {
            uint256 treasuryAmount = (burnAmount * 10) / 65;
            super._update(usdtPool, treasuryAddress, treasuryAmount);
            uint256 rewardAmount = (burnAmount * 55) / 65;
            super._update(usdtPool, rewardPoolAddress, rewardAmount);
            IUniswapV2Pair(usdtPool).sync();
            emit PoolBurn(usdtPool, treasuryAmount, rewardAmount);
        }
    }

    function isContract(address account) internal view returns (bool) {
        uint32 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }

    function _maxBuyAmount() internal view returns (uint256) {
        uint poolAmount = this.balanceOf(usdtPool);
        return poolAmount * maxBuyRate / 1000;
    }

    function _isLpStopBurn() internal view returns (bool) {
        if (!lpBurnEnabled) return true;
        uint zeroAddrAmount = super.balanceOf(address(DEAD));
        uint surplusAmount = super.totalSupply() - zeroAddrAmount;
        if(surplusAmount < 210_0000 ether) {
            return true;
        }
        return false;
    }
     

}