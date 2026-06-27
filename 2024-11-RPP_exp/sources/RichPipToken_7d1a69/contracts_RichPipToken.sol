
/**
 *
 *  RPP Token
 *
 *  
 */
//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapV2Router02.sol";
import './interfaces/IWETH.sol';

contract RichPipToken is ERC20Burnable, Ownable {

    IUniswapV2Router02 public uniswapV2Router;
    address public uniswapV2Pair;

    address public mainAddress = address(0x55d398326f99059fF775485246999027B3197955);

    uint256 public transferFee = 6;
    uint256 public buyFee = 6;
    uint256 public sellFee = 12;

    uint256 public txBurnRate = 50; // 1/2

    uint256 private _commonDiv = 100;
    mapping(address => bool) _excludedFees;
    mapping(address => bool) _mintWhitelist;
    bool public swapIng;

    bool public initialPool = true;
    uint256 public totalMintAmount = 1000000000e18;// total mint amount

    uint256 public initialPrice = 1*10**14;// 0.0001
    uint256 public everyTimeBuyLimitAmount = 100000e18;// 100000
    uint256 public everyTimeSellLimitAmount = 100000e18; // 100000
    // uint256 public overFlowBurnAmount = 5000000e18;// overflow to burn
    uint256 private _lpBurnRate = 206;// times burn

    uint256 public totalDestroy;
    address public feeReciever;
    
    mapping(address => bool) public automatedMarketMakerPairs;

    bool public enableSwitch = true;
    bool public enableBurnLp = true;
    bool public enableMintWhitelist = true;

    uint256 private constant MAX = type(uint256).max;

    constructor() ERC20("RichPip Token", "RPP") {
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(
            0x10ED43C718714eb63d5aA57B78B54704E256024E //bsc network
            //0xD99D1c33F9fC3444f8101754aBC46c52416550D1 //test bsc network
        );
        uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory()).createPair(mainAddress, address(this));
        _excludedFees[msg.sender] = true;
        _excludedFees[address(this)] = true;
        _setAutomatedMarketMakerPair(address(uniswapV2Pair), true);
        uniswapV2Router = _uniswapV2Router;

        feeReciever = msg.sender;
    }

    bool public minting;

    modifier lockMint() {
        minting = true;
        _;
        minting = false;
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

    function setMintWhitelist(address account, bool _flag) external onlyOwner {
        _mintWhitelist[account] = _flag;
    } 

    function setEnableSwitch(bool _flag) external onlyOwner {
        enableSwitch = _flag;
    }
    function setEnableBurnLp(bool _flag) external onlyOwner {
        enableBurnLp = _flag;
    }

    function setEnableMintWhitelist(bool _flag) external onlyOwner {
        enableMintWhitelist = _flag;
    }

    function setTxBurnRate(uint256 _amount) external onlyOwner {
        txBurnRate = _amount;
    }

    function setEveryTimeTxLimitAmount(uint256 _buyAmt, uint256 _sellAmt) external onlyOwner {
        everyTimeBuyLimitAmount = _buyAmt;
        everyTimeSellLimitAmount = _sellAmt;
    }

    function setLpBurnRate(uint256 _rate) external onlyOwner {
        _lpBurnRate = _rate;
    }

    function setFee(uint256 _sf, uint256 _bf, uint256 _tf) external onlyOwner {
        buyFee = _sf;
        sellFee = _bf;
        transferFee = _tf;
    }

    function setInitialPool(bool _f) external onlyOwner {
        initialPool = _f;
    }

    function setFeeReciever(address _reciever) external onlyOwner {
        feeReciever = _reciever;
        _excludedFees[_reciever] = true;
    }

    function setMainAddress(address _mainAddress) external onlyOwner {
        mainAddress = _mainAddress;
        uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory()).getPair(_mainAddress, address(this));
        _setAutomatedMarketMakerPair(uniswapV2Pair, true);
    }

    function setMarketMakerPair(address _pair) external onlyOwner {
        _setAutomatedMarketMakerPair(_pair, true);
    }

    function _setAutomatedMarketMakerPair(address pair, bool value) private {
        automatedMarketMakerPairs[pair] = value;
        emit SetAutomatedMarketMakerPair(pair, value);
    }

    // burn token amount
    function _recordBurn(address _who, uint256 _amount) internal {
        super._burn(_who, _amount);
        totalDestroy += _amount;
    }

    function burn(uint256 amount) public virtual override {
        _recordBurn(_msgSender(), amount);
    }

    function burnFrom(address account, uint256 amount) public virtual override {
        super._spendAllowance(account, _msgSender(), amount);
        _recordBurn(account, amount);
    }

    error ErrUnableSwap();

    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out
    );

    function _burnLpsToken(uint256 amount) internal {
        uint256 liquidityPairBalance = balanceOf(uniswapV2Pair);
        uint256 amountToBurn = amount * _lpBurnRate / _commonDiv;
        if (amountToBurn > 0 && liquidityPairBalance > amountToBurn) {
            if (!swapIng && !minting) {
                autoLiquidityPairTokens(amountToBurn);
            }
        }
    }

    function _sell(address from, uint256 amount) internal {
        require(!swapIng, "Swapping");
        require(amount > 0, "Sell amount must large than zero");
        require(msg.sender == tx.origin, "Only external calls allowed");
        require(amount < everyTimeSellLimitAmount, "Exchange Overflow");

        super._transfer(from, address(this), amount);
        if (enableSwitch && !_excludedFees[from]) {
            uint256 _txFee;
            uint256 _burnFee;
            // sell
            unchecked {
                _txFee = amount * sellFee / _commonDiv;
                amount -= _txFee;
            }
            if (txBurnRate > 0) {
                _burnFee = _txFee * txBurnRate / _commonDiv;
                _txFee -= _burnFee;
            }
            if (_burnFee > 0) {
                _recordBurn(address(this), _burnFee);
            }
            if (_txFee > 0) {
                super._transfer(address(this), feeReciever, _txFee);
            }
        }

        uint256 _beforeBal = IERC20(mainAddress).balanceOf(from);
        _swapTokensForMain(amount, from);
        uint256 _afterBal = IERC20(mainAddress).balanceOf(from);
        uint256 _excuteAmount = _afterBal - _beforeBal;

        if (enableSwitch && enableBurnLp) {
            _burnLpsToken(amount);
        }

        address _token0 = IUniswapV2Pair(uniswapV2Pair).token0();
        if (_token0 == address(this)) {
            emit Swap(from, amount, 0, 0, _excuteAmount);
        } else {
            emit Swap(from, 0, amount, _excuteAmount,  0);
        }
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        if (to == address(this)) {
            _sell(from, amount);
        } else {
            _transfer(from, to, amount);
        }
        return true;
    }

    function transfer(address to, uint256 value) public virtual override returns (bool) {
        // sell or transfer
        if (to == address(this)) {
            _sell(_msgSender(), value);
        } else {
            _transfer(_msgSender(), to, value);
        }
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal virtual override {
        // enable mode
        if (enableSwitch && !_excludedFees[from] && !_excludedFees[to]) {
            uint256 _txFee;
            uint256 _burnFee;
            if (automatedMarketMakerPairs[to]) {
                require(amount < everyTimeSellLimitAmount, "Exchange Overflow");
                // sell
                unchecked {
                    _txFee = amount * sellFee / _commonDiv;
                    amount -= _txFee;
                }
                if (txBurnRate > 0) {
                    _burnFee = _txFee * txBurnRate / _commonDiv;
                    _txFee -= _burnFee;
                }
            } else if (automatedMarketMakerPairs[from]) {
                require(amount < everyTimeBuyLimitAmount, "Exchange Overflow");
                // buy
                unchecked {
                    _txFee = amount * buyFee / _commonDiv;
                    amount -= _txFee;
                }
            } else {
                // transfer
                unchecked {
                    _txFee = amount * transferFee / _commonDiv;
                    amount -= _txFee;
                }
            }
            if (_burnFee > 0) {
                _recordBurn(from, _burnFee);
            }
            if (_txFee > 0) {
                super._transfer(from, feeReciever, _txFee);
            }
            if (enableBurnLp && automatedMarketMakerPairs[to]) {
                // sell burn lp token
                _burnLpsToken(amount);
            }
        }
        super._transfer(from, to, amount);
    }

    event AutoNukeLP();

    function dexPrice(uint256 _amount) public view returns (uint256) {
        address[] memory _path = new address[](2);
        _path[0] = address(this);
        _path[1] = mainAddress;
        uint256[] memory amounts = uniswapV2Router.getAmountsOut(_amount, _path);
        return amounts[1];
    }

    function pairTokenAmt(uint256 _otherAmt) public view returns (uint256 _convertTokenBal) {
        address _token0 = IUniswapV2Pair(uniswapV2Pair).token0();
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(uniswapV2Pair).getReserves();
        uint256 tokenBal;
        uint256 otherBal;
        if (_token0 == address(this)) {
            tokenBal = reserve0;
            otherBal = reserve1;
        } else {
            tokenBal = reserve1;
            otherBal = reserve0;
        }
        if (_otherAmt > 0 && otherBal > 0 && tokenBal > 0) {
            _convertTokenBal = uniswapV2Router.quote(_otherAmt, otherBal, tokenBal);
        }
    }

    function mintPredictTokenNum(uint256 _mainAmt) public view returns (uint256 _tokenAmt) {
        if (initialPool == false) {
            _tokenAmt = _mainAmt * 1e18 / initialPrice;
        } else {
            _tokenAmt = pairTokenAmt(_mainAmt);
        }
    }

    uint256 public lastLpBurnTime;
    
    function autoLiquidityPairTokens(uint256 amountToBurn) internal lockTheSwap returns (bool) {
        lastLpBurnTime = block.timestamp;
        // pull tokens from pancakePair liquidity and move to dead address permanently
        _recordBurn(uniswapV2Pair, amountToBurn);
        //sync price since this is not in a swap transaction!
        IUniswapV2Pair pair = IUniswapV2Pair(uniswapV2Pair);
        pair.sync();
        emit AutoNukeLP();
        return true;
    }

    function _addLiquidity(uint256 _amount, uint256 tokenAmount, address _to) internal {
        IERC20(mainAddress).approve(address(uniswapV2Router), _amount);
        super._approve(address(this), address(uniswapV2Router), tokenAmount);
        uniswapV2Router.addLiquidity(
            mainAddress, 
            address(this), 
            _amount, 
            tokenAmount, 
            0, 
            0,
            _to,
            block.timestamp + 300);
    }

    function isMintable() public view returns (bool) {
        return totalSupply() < totalMintAmount;
    }


    function _swapTokensForMain(uint256 tokenAmount,address to) internal lockTheSwap {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = mainAddress;
        super._approve(address(this), address(uniswapV2Router), tokenAmount);
        uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            to,
            block.timestamp + 300
        );
    }

    function buildLpToken(uint256 _amount, address _to) internal lockMint {
        uint256 _buildLpAmt = mintPredictTokenNum(_amount);
        if (_buildLpAmt > 0) {
            super._mint(address(this), _buildLpAmt);
            _addLiquidity(_amount, _buildLpAmt, _to);
            IUniswapV2Pair(uniswapV2Pair).sync();
            emit AutoNukeLP();
            super._mint(_to, _buildLpAmt);

            if (initialPool == false) {
                initialPool = true;
            }
        }
    }

    function _mintTokenByOtherToken() internal {
        if (enableMintWhitelist) {
            require(_mintWhitelist[msg.sender], "Only Whitelist");
        } else {
            require(msg.sender == tx.origin, "Only EOA");
        }
        uint256 _balOfm = IERC20(mainAddress).balanceOf(msg.sender);
        require(_balOfm > 0, "Mint err amount");

        require(isMintable(), "Mint over");
        require(!minting, "Minting");
        require(!swapIng, "Swapping");

        IERC20(mainAddress).transferFrom(msg.sender, address(this), _balOfm);
        uint256 _total = IERC20(mainAddress).balanceOf(address(this));
        buildLpToken(_total, msg.sender);
    }

    receive() external payable {
        _mintTokenByOtherToken();
    }
}