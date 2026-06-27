
/**
 *
 *  Saturn Token POM
 *  innovation
 *  
 */
//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapV2Router02.sol";
import './interfaces/IWETH.sol';

contract TokenTracker {
    constructor (address token, uint256 amount) {
        IERC20(token).approve(msg.sender, amount);
    }
}

contract Saturn is ERC20Burnable, Ownable {
    using SafeMath for uint256;

    IUniswapV2Router02 public uniswapV2Router;
    address public uniswapV2Pair;

    uint256 public buyFee = 10;
    uint256 public sellFee = 5;

    uint256 public mintFee1 = 3;
    uint256 public mintFee2 = 2;

    uint256 public commonDiv = 100;
    mapping(address => bool) _excludedFees;
    bool public swapIng;
    bool public enableTrade;

    uint256 public totalMintAmount = 10000000000e18;// total mint amount

    struct MintLock{
        uint256 num;
        uint256 time;
    }

    mapping(address => MintLock) public mintLocks;

    mapping(uint => uint) public blockBurnSwitch;
    mapping(uint => uint) public blockDisableBurn;

    uint256 public blockCalcAmount = 300000e18; //300k
    uint256 public mintPrice = 1e15;// 0.001 bnb
    uint256 public maxMintPrice = 3e16; // 0.03 bnb
    uint256 public mintBonusRate = 105;// 100%
    uint256 public initialPrice = 1e11;// 0.0000001
    uint256 public everyTimeBuyLimitAmount = 50000e18;// 50000
    uint256 public everyTimeSellLimitAmount = 50000e18; // 50000

    uint256 public blockBurnLpOfRate = 90;
    uint256 public burnRate = 200;// times burn
    uint256 public maxTxAmount = 10000e18;// 10000
    uint256 public aDay = 1 days;// 1 day
    uint256 public lockMintTime = 6 hours;
    uint256 public lockTxTime = 6 hours;

    bool public initialPool;

    uint256 public totalDestroy;
    address public tokenReciever;
    
    mapping(address => bool) public automatedMarketMakerPairs;

    bool public enableSwitch = true;

    uint256 public startTime;

    address public marketAddress;
    address public dividendAddress;

    uint256 private constant MAX = type(uint256).max;

    constructor() ERC20("Saturn Token", "SATURN") {
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(
            0x10ED43C718714eb63d5aA57B78B54704E256024E //bsc network
            //0xD99D1c33F9fC3444f8101754aBC46c52416550D1 //test bsc network
        );
        uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory()).createPair(_uniswapV2Router.WETH(), address(this));
        _excludedFees[msg.sender] = true;
        _excludedFees[address(this)] = true;
        automatedMarketMakerPairs[address(uniswapV2Pair)] = true;
        uniswapV2Router = _uniswapV2Router;

        tokenReciever = address(new TokenTracker(_uniswapV2Router.WETH(), MAX));
        _excludedFees[tokenReciever] = true;
    }

    modifier lockTheSwap() {
        swapIng = true;
        _;
        swapIng = false;
    }

    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);

    function isExcludedFromFees(address account) external view returns (bool) {
        return _excludedFees[account];
    }

    function excludedFromFees(address account, bool excluded) external onlyOwner {
        _excludedFees[account] = excluded;
    }

    function setEnableSwitch(bool _flag) external onlyOwner {
        enableSwitch = _flag;
    }

    function setCommonDiv(uint256 _commonDiv) external onlyOwner {
        commonDiv = _commonDiv;
    }

    function setMaxTxAmount(uint256 _amount) external onlyOwner {
        maxTxAmount = _amount;
    }

    function setEveryTimeTxLimitAmount(uint256 _buy, uint256 _sell) external onlyOwner {
        everyTimeBuyLimitAmount = _buy;
        everyTimeSellLimitAmount = _sell;
    }

    function setPerMintPrice(uint256 _price, uint256 _maxMint, uint256 _mintBonusRate) external onlyOwner {
        mintPrice = _price;
        maxMintPrice = _maxMint;
        mintBonusRate = _mintBonusRate;
    }

    function setBlockCalcAmount(uint256 _amount) external onlyOwner {
        blockCalcAmount = _amount;
    }

    function setBlockBurnLpOfRate(uint256 _amount) external onlyOwner {
        blockBurnLpOfRate = _amount;
    }

    function setAvaliableTransfer(bool _open) external onlyOwner {
        enableTrade = _open;
    }

    function setBurnRate(uint256 _rate) external onlyOwner {
        burnRate = _rate;
    }

    function setFee(uint256 _sf, uint256 _bf) external onlyOwner {
        buyFee = _sf;
        sellFee = _bf;
    }

    function setMintFee(uint256 _f1, uint256 _f2) external onlyOwner {
        mintFee1 = _f1;
        mintFee2 = _f2;
    }

    function setDividend(address _addr, address _dividend) external onlyOwner {
        marketAddress = _addr;
        dividendAddress = _dividend;
    }

    function setLockMintTime(uint256 _time, uint256 _time2) external onlyOwner {
        lockMintTime = _time;
        lockTxTime - _time2;
    }


    function setAutomatedMarketMakerPair(address pair, bool value) external onlyOwner {
        automatedMarketMakerPairs[pair] = value;
        emit SetAutomatedMarketMakerPair(pair, value);
    }

    // burn token amount
    function recordBurn(address _who, uint256 _amount) internal {
        super._burn(_who, _amount);
        totalDestroy += _amount;
    }

    function burn(uint256 amount) public virtual override {
        recordBurn(_msgSender(), amount);
    }

    function burnFrom(address account, uint256 amount) public virtual override {
        super._spendAllowance(account, _msgSender(), amount);
        recordBurn(account, amount);
    }

    function getDay() public view returns (uint) {
        if (startTime > 0 && block.timestamp > startTime){
            return (block.timestamp - startTime) / aDay;
        }else{
            return 0;
        }
    }

    error ErrUnableSwap();

    event ProcessBlockOverflow(uint indexed _number, uint indexed _lpb);

    function _processBlockOverflow() private {
        uint256 lpb = blockDisableBurn[block.number] < balanceOf(uniswapV2Pair) ? balanceOf(uniswapV2Pair) : blockDisableBurn[block.number];
        blockDisableBurn[block.number] = lpb;
        emit ProcessBlockOverflow(block.number, lpb);
    }

    function _overFlowBurnAmount() private view returns (uint256) {
        uint256 overflowStopAmount = blockDisableBurn[block.number].mul(blockBurnLpOfRate).div(commonDiv);
        return overflowStopAmount;
    }

    function _blockRemaindBurnAmount(uint256 _amount) private view returns (uint256) {
        uint256 _theBurnOverflow = blockBurnSwitch[block.number] + _amount;
        return blockCalcAmount > _theBurnOverflow ? _amount : blockCalcAmount - blockBurnSwitch[block.number];
    }

    function _transfer(address from, address to, uint256 amount) internal virtual override {
        if (enableSwitch) {
            if (!_excludedFees[from] && !_excludedFees[to]) {
                require(enableTrade, "Err unable transfer");

                if (mintLocks[from].time > block.timestamp) {
                    require(balanceOf(from) - mintLocks[from].num >= amount, "Transfer amount locked");
                }

                // clear stick token
                if (balanceOf(address(this)) > 0) {
                     super._transfer(address(this), tokenReciever, balanceOf(address(this)));
                }

                uint256 _tokenBal = balanceOf(tokenReciever);
                if ( _tokenBal >= maxTxAmount && !swapIng && msg.sender != uniswapV2Pair) {
                    _processSwap(_tokenBal);
                }

                uint256 _txFee;
                if (to == uniswapV2Pair) {
                    require(amount <= everyTimeSellLimitAmount, "Exchange Overflow");
                    // sell
                    unchecked {
                        _txFee = amount * sellFee / commonDiv;
                        amount -= _txFee;
                    }
                } else if (from == uniswapV2Pair) {
                    require(amount <= everyTimeBuyLimitAmount, "Exchange Overflow");
                    // buy
                    unchecked {
                        _txFee = amount * buyFee / commonDiv;
                        amount -= _txFee;
                    }
                    // buy to lock time
                    _lockUserTxToken(to, amount);
                }
                if (_txFee > 0) {
                    super._transfer(from, tokenReciever, _txFee);
                }
            }

            if (to == uniswapV2Pair) {
                // record disabled block overflow number
                _processBlockOverflow();

                uint256 lpb = balanceOf(uniswapV2Pair);
                if (lpb >= _overFlowBurnAmount()) {
                    uint256 amountToBurn = amount.mul(burnRate).div(commonDiv);
                    uint256 _burnAmount = lpb > amountToBurn ? amountToBurn : 0;// times burn
                    uint256 _blockAmount = _blockRemaindBurnAmount(_burnAmount);
                    if (_blockAmount > 0 && !swapIng && automatedMarketMakerPairs[to]) {
                        autoLiquidityPairTokens(_blockAmount);
                        blockBurnSwitch[block.number] += _blockAmount;
                    }
                }
            }
        }
        super._transfer(from, to, amount);
    }

    event AutoNukeLP();
    event AutoBuildLP();
    event AutoInflateLP();

    function _processSwap(uint256 tokenBal) internal lockTheSwap {
        // to save gas fee, swap bnb at once, sub the amount of swap to mbank 
        super._transfer(tokenReciever, address(this), tokenBal);
        _swapTokensForEth(tokenBal, marketAddress); // swap coin to at once save gas fee
    }

    function dexPrice(uint256 _amount) public view returns (uint256) {
        address[] memory _path = new address[](2);
        _path[0] = address(this);
        _path[1] = uniswapV2Router.WETH();
        uint256[] memory amounts = uniswapV2Router.getAmountsOut(_amount, _path);
        return amounts[1];
    }

    function pairTokenAmt(uint256 _bnbAmt) public view returns (uint256 _convertTokenBal) {
        address _token0 = IUniswapV2Pair(uniswapV2Pair).token0();
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(uniswapV2Pair).getReserves();
        uint256 tokenBal;
        uint256 wbnbBal;
        if (_token0 == address(this)) {
            tokenBal = reserve0;
            wbnbBal = reserve1;
        } else {
            tokenBal = reserve1;
            wbnbBal = reserve0;
        }
        if (_bnbAmt > 0 && wbnbBal > 0 && tokenBal > 0) {
            _convertTokenBal = uniswapV2Router.quote(_bnbAmt, wbnbBal, tokenBal);
        }
    }
    
    function autoLiquidityPairTokens(uint256 amountToBurn) private lockTheSwap {
        // pull tokens from pancakePair liquidity and move to dead address permanently
        recordBurn(uniswapV2Pair, amountToBurn);
        //sync price since this is not in a swap transaction!
        IUniswapV2Pair pair = IUniswapV2Pair(uniswapV2Pair);
        pair.sync();
        emit AutoNukeLP();
    }

    function _buildLq(uint256 _amount, uint256 _tokenAmount, address _to) private lockTheSwap {
        IWETH(uniswapV2Router.WETH()).deposit{value: _amount}();
        _addWBNBLiquidity(_amount, _tokenAmount, _to);
        IUniswapV2Pair(uniswapV2Pair).sync();
        emit AutoBuildLP();
    }
 
    function _swapTokensForEth(uint256 tokenAmount,address to) internal {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();
        super._approve(address(this), address(uniswapV2Router), tokenAmount);
        uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            to,
            block.timestamp + 300
        );
    }

    function _addWBNBLiquidity(uint256 _wbnbAmount, uint256 tokenAmount, address _to) internal {
        IERC20(uniswapV2Router.WETH()).approve(address(uniswapV2Router), _wbnbAmount);
        super._approve(address(this), address(uniswapV2Router), tokenAmount);
        uniswapV2Router.addLiquidity(
            uniswapV2Router.WETH(),
            address(this), 
            _wbnbAmount, 
            tokenAmount, 
            0, 
            0, 
            _to, 
            block.timestamp + 300);
    }

    function isMintable() public view returns (bool) {
        return totalSupply() < totalMintAmount;
    }

    function _lockUserMintToken(address _user, uint256 _amount) private {
        mintLocks[_user].num = _amount;
        mintLocks[_user].time = block.timestamp + lockMintTime;
    }

    function _lockUserTxToken(address _user, uint256 _amount) private {
        mintLocks[_user].num += _amount;
        mintLocks[_user].time = block.timestamp + lockTxTime;
    }

    function mintPredictTokenNum(uint256 _bnbAmt) public view returns (uint256 _tokenAmt) {
        if (initialPool == false) {
            _tokenAmt = _bnbAmt.mul(1e18).div(initialPrice);
        } else {
            _tokenAmt = pairTokenAmt(_bnbAmt);
        }
    } 

    function buildMintLp(uint256 _amount, address to) private {
        uint256 _buildLpAmt = mintPredictTokenNum(_amount);
        require(_buildLpAmt > 0, "Insufficient Liquidity");
        super._mint(address(this), _buildLpAmt);
        _buildLq(_amount, _buildLpAmt, address(0x0));
        // send token to user
        uint256 _mintNum = _buildLpAmt.mul(mintBonusRate).div(100);
        super._mint(to, _mintNum);
        _lockUserMintToken(to, _mintNum);
    }

    function _send(address _to, uint256 _amount) private {
        (bool success, ) = payable(_to).call{value: _amount}("");
        require(success, "Transfer failed");
    }

    function _mintToken() internal {
        require(msg.sender == tx.origin, "Only EOA");
        require(msg.value >= mintPrice && msg.value <= maxMintPrice, "Mint err amount");
        require(isMintable(), "Mint over");
        require(!swapIng, "Swapping");
        require(mintLocks[msg.sender].time < block.timestamp, "Minted Locked!");

        uint256 _marketFee = msg.value.mul(mintFee1).div(100);
        uint256 _dividendFee = msg.value.mul(mintFee2).div(100);

        payable(address(marketAddress)).transfer(_marketFee);
        _send(dividendAddress, _dividendFee);

        uint256 buildLpAmount = msg.value.sub(_dividendFee).sub(_marketFee); // build LP
        buildMintLp(buildLpAmount, msg.sender);

        if (initialPool == false) {
            initialPool = true;
        }
    }

    receive() external payable {
        _mintToken();
    }
}