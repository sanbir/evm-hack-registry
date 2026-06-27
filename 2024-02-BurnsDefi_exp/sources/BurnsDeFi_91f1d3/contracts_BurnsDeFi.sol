//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../interfaces/IUniswapV2.sol";

interface burnedFiAbi is IERC20 {
    function launch() external view returns (bool);

    function setLaunch(bool flag) external;
}

contract BurnsAirdrop is Context {
    using SafeMath for uint256;

    uint256 public totalDroped;
    uint256 public threshold;

    uint256 private constant _value = 0.002 ether;
    uint256 private constant _deployAmount = 40 ether;
    uint256 private constant _singleAmount = 100 ether;
    uint256 public _block;
    uint256 private _countBlock;
    burnedFiAbi public _burnedFi;
    mapping(address => uint256) _userCount;
    IUniswapV2Router02 public uniswapRouter;
    bool inits = false;

    event Droped(address indexed account, uint256 indexed total);

    constructor() {}

    function init(address burnedFiAddr, address routeAddr) public {
        require(!inits, "initsd");
        inits = true;
        _burnedFi = burnedFiAbi(burnedFiAddr);
        uniswapRouter = IUniswapV2Router02(routeAddr);
    }

    function _drop() internal {
        if (
            msg.value == _value &&
            !_burnedFi.launch() &&
            _msgSender() != address(this)
        ) {
            require(_msgSender() == tx.origin, "Only EOA");

            if (_countBlock < 20) {
                ++_countBlock;
                ++totalDroped;
                ++threshold;

                if (totalDroped == 1 || totalDroped % 300 == 0) {
                    _deployLiquidity();
                }

                require(
                    _burnedFi.balanceOf(address(this)) >= _singleAmount,
                    "Droped out"
                );
                _burnedFi.transfer(_msgSender(), _singleAmount);

                ++_userCount[_msgSender()];
                require(_userCount[_msgSender()] <= 100, "Limit 100 num!");

                emit Droped(_msgSender(), totalDroped);
            } else if (_block != block.number) {
                _block = block.number;
                _countBlock = 0;
            }
            if (totalDroped >= 150000) {
                _burnedFi.setLaunch(true);
                uint256 amount = payable(address(this)).balance;
                payable(address(_burnedFi)).transfer(amount);
            }
        }
    }

    function _deployLiquidity() internal {
        uint256 _amount = _deployAmount.mul(threshold);
        uint256 balance = _value.mul(threshold).div(2);
        uint256 amount = payable(address(this)).balance;
        if (amount >= balance) {
            addLiquidity(_amount, balance);
            threshold = 0;
        }
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // approve token transfer to cover all possible scenarios
        IERC20 token = IERC20(address(_burnedFi));
        token.approve(address(uniswapRouter), tokenAmount);
        // add the liquidity
        uniswapRouter.addLiquidityETH{value: ethAmount}(
            address(_burnedFi),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            address(0xdead),
            block.timestamp
        );
    }

    //to recieve ETH from uniswapV2Router when swaping
    receive() external payable {
        _drop();
    }
}

interface burnsRewardHold {
    function burnFeeRewards(address account, uint256 amount) external payable;
}

contract BurnsDeFi is ERC20, Ownable {
    using SafeMath for uint256;
    IUniswapV2Router02 public uniswapRouter;
    address public uniswapPair;
    uint256 public burnFee = 2;
    uint256 public taxFee = 10;
    burnsRewardHold public burnsHolder;
    mapping(address => bool) _excludedFees;
    uint256 public minBalanceSwapToken = 210 * 10 ** 18;
    bool swapIng;
    BurnsAirdrop public airdropAddr;
    // store addresses that a automatic market maker pairs. Any transfer *to* these addresses
    // could be subject to a maximum transfer amount
    mapping(address => bool) public automatedMarketMakerPairs;

    uint256 public lpBurnFrequency = 3600 seconds;
    uint256 public lastLpBurnTime;
    uint256 public percentForLPBurn = 50; // 25 = .25%

    bool public launch = false;
    bool public lpBurnEnabled = true;

    event AutoNukeLP();
    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);

    constructor() ERC20("BurnsDeFi", "Burns") {
        uniswapRouter = IUniswapV2Router02(
            0x10ED43C718714eb63d5aA57B78B54704E256024E
        );
        uniswapPair = IUniswapV2Factory(uniswapRouter.factory()).createPair(
            address(this),
            uniswapRouter.WETH()
        );
        BurnsAirdrop _airdrop = new BurnsAirdrop();
        _airdrop.init(address(this), address(uniswapRouter));
        _excludedFees[_msgSender()] = true;
        _excludedFees[address(this)] = true;
        _excludedFees[address(_airdrop)] = true;
        airdropAddr = _airdrop;

        _setAutomatedMarketMakerPair(uniswapPair, true);

        _approve(_msgSender(), address(uniswapRouter), ~uint256(0));
        _approve(address(this), address(uniswapRouter), ~uint256(0));
        _approve(address(_airdrop), address(uniswapRouter), ~uint256(0));
        _mint(address(_airdrop), 21000000 * 10 ** 18);
    }

    function setburnsHolder(address _addr) external onlyOwner {
        burnsHolder = burnsRewardHold(_addr);
        _excludedFees[_addr] = true;
    }

    function setminBalanceSwapToken(
        uint256 _minBalanceSwapToken
    ) external onlyOwner {
        minBalanceSwapToken = _minBalanceSwapToken;
    }

    function isExcludedFromFees(address account) external view returns (bool) {
        return _excludedFees[account];
    }

    function setAutoLPBurnSettings(
        uint256 _frequencyInSeconds,
        uint256 _percent,
        bool _Enabled
    ) external onlyOwner {
        lpBurnFrequency = _frequencyInSeconds;
        percentForLPBurn = _percent;
        lpBurnEnabled = _Enabled;
    }

    function excludedFromFees(
        address account,
        bool excluded
    ) external onlyOwner {
        _excludedFees[account] = excluded;
    }

    function setAutomatedMarketMakerPair(
        address pair,
        bool value
    ) public onlyOwner {
        require(
            pair != uniswapPair,
            "The pair cannot be removed from automatedMarketMakerPairs"
        );
        _setAutomatedMarketMakerPair(pair, value);
    }

    function _setAutomatedMarketMakerPair(address pair, bool value) private {
        automatedMarketMakerPairs[pair] = value;
        emit SetAutomatedMarketMakerPair(pair, value);
    }

    function setLaunch(bool flag) public {
        require(address(airdropAddr) == msg.sender, "only AirDrop");
        launch = flag;
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        if (!_excludedFees[from] && !_excludedFees[to]) {
            require(launch, "unlaunch");
            uint256 fees;

            if (burnFee > 0) {
                //燃烧代币 0.2%
                uint256 _burnFees = amount.mul(burnFee).div(1000);
                super._transfer(from, address(0xdead), _burnFees);
                fees += _burnFees;
            }

            if (taxFee > 0) {
                //跟砸代币 1%
                uint256 _marketingFee = amount.mul(taxFee).div(1000);
                super._transfer(from, address(this), _marketingFee);
                fees += _marketingFee;
            }

            if (to == uniswapPair) {
                uint256 contractBalance = balanceOf(address(this));
                if (!swapIng && contractBalance > minBalanceSwapToken) {
                    swapIng = true;
                    if (
                        automatedMarketMakerPairs[to] &&
                        lpBurnEnabled &&
                        block.timestamp >= lastLpBurnTime + lpBurnFrequency &&
                        !_excludedFees[from]
                    ) {
                        autoBurnLiquidityPairTokens();
                    }

                    swapTokensForEth(contractBalance);
                    swapIng = false;
                }
            }

            if (fees > 0) {
                amount -= fees;
            }
        }
        super._transfer(from, to, amount);
    }

    function swapTokensForEth(uint256 tokenAmount) private {
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapRouter.WETH();
        _approve(address(this), address(uniswapRouter), tokenAmount);
        // make the swap
        uniswapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    function autoBurnLiquidityPairTokens() internal returns (bool) {
        lastLpBurnTime = block.timestamp;
        // get balance of liquidity pair
        uint256 liquidityPairBalance = balanceOf(uniswapPair);
        // calculate amount to burn
        uint256 amountToBurn = liquidityPairBalance.mul(percentForLPBurn).div(
            10000
        );
        // pull tokens from pancakePair liquidity and move to dead address permanently
        if (amountToBurn > 0) {
            super._transfer(uniswapPair, address(0xdead), amountToBurn);
        }
        //sync price since this is not in a swap transaction!
        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        pair.sync();
        emit AutoNukeLP();
        return true;
    }

    function appendLiquidity() private {}

    function burnToholder(
        address to,
        uint256 amount,
        uint256 balance
    ) external {
        require(msg.sender == address(burnsHolder), "only burns");
        require(launch, "unlaunch");
        uint256 _amount = balanceOf(to);
        require(_amount >= amount, "not enough");
        super._transfer(to, address(burnsHolder), amount);
        uint256 _balance = payable(address(this)).balance;
        require(_balance >= balance, "Droped out");
        payable(address(burnsHolder)).transfer(balance);
    }

    receive() external payable {
        //to recieve ETH from uniswapV2Router when swaping
    }
}
