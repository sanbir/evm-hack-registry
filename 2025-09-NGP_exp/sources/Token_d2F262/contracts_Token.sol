// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "./TokenAccessControl.sol";

contract Token is ERC20, TokenAccessControl {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    mapping(address => bool) public whitelisted;
    bool public buyState = false;
    bool public sellState = false;

    IUniswapV2Router02 router;
    address public mainPair;

    // buy limit related variables
    mapping(address => uint256) public buyCount; // buy count in 24 hours
    mapping(address => uint256) public lastBuyTime; // last buy time
    mapping(address => uint256) public lastTransferTime; // last transfer time
    uint256 public maxBuyPerDay = 3; // max buy count in 24 hours
    uint256 public transferCooldown = 30 minutes; // transfer cooldown after buy

    uint256 public constant RATIO_PRECISION = 100 * 1e3;
    uint256 public marketFeeRate = 3 * 1e3; // market fee rate, 3%
    uint256 public burnFeeRate = 2 * 1e3; // burn fee rate, 2%
    uint256 public treasuryRate = 10 * 1e3; // treasury fee rate, 10%
    uint256 public rewardRate = 60 * 1e3; // reward fee rate, 60%

    // USDT
    address public usdtAddress;
    //free market address
    address public marketAddress;
    // treasury address
    address public treasuryAddress;
    // reward pool address
    address public rewardPoolAddress;
    // burn pool state
    bool public lpBurnEnabled = true;
    // max buy amount in usdt
    uint public maxBuyAmountInUsdt;
    // mint address
    address mintAddress;

    event SystemTransfer(
        address indexed from,
        address indexed to,
        uint256 value
    );
    event FlowIntoPool(
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 fee,
        uint256 burn,
        uint256 treasury,
        uint256 reward
    );
    event FlowOutPool(address indexed from, address indexed to, uint256 amount);

    constructor(
        address _usdtAddress,
        address _marketAddress,
        address _treasuryAddress,
        address _rewardPoolAddress,
        address _routerAddress,
        address _mintAddress
    ) ERC20("NGP", "NGP") {
        usdtAddress = _usdtAddress;
        marketAddress = _marketAddress;
        treasuryAddress = _treasuryAddress;
        rewardPoolAddress = _rewardPoolAddress;
        mintAddress = _mintAddress;

        whitelisted[address(this)] = true;
        whitelisted[address(DEAD)] = true;
        whitelisted[mintAddress] = true;

        router = IUniswapV2Router02(_routerAddress);
        _createPool();

        maxBuyAmountInUsdt = 10_000 * 10 ** decimals();
        _mint(mintAddress, 1_000_000_000 * 10 ** decimals());
    }

    function _createPool() internal {
        IUniswapV2Factory factory = IUniswapV2Factory(router.factory());
        mainPair = factory.createPair(address(this), usdtAddress);
    }

    function setWhitelistBatch(
        address[] calldata accounts,
        bool state
    ) external onlyMinter {
        for (uint256 i = 0; i < accounts.length; i++) {
            whitelisted[accounts[i]] = state;
        }
    }

    function setTradeState(
        bool _buyState,
        bool _sellState
    ) external onlyMinter {
        buyState = _buyState;
        sellState = _sellState;
    }

    function setTreasuryAddress(address _treasuryAddress) external onlyMinter {
        require(_treasuryAddress != address(0), "Invalid address");
        treasuryAddress = _treasuryAddress;
    }

    function setRewardPoolAddress(
        address _rewardPoolAddress
    ) external onlyMinter {
        require(_rewardPoolAddress != address(0), "Invalid address");
        rewardPoolAddress = _rewardPoolAddress;
    }

    function setMarketAddress(address _marketAddress) external onlyMinter {
        require(_marketAddress != address(0), "Invalid address");
        marketAddress = _marketAddress;
    }

    function setLpBurnEnabled(bool _lpBurnEnabled) external onlyMinter {
        lpBurnEnabled = _lpBurnEnabled;
    }

    function setMaxBuyAmountInUsdt(
        uint _maxBuyAmountInUsdt
    ) external onlyMinter {
        require(_maxBuyAmountInUsdt > 0, "Invalid amount");
        maxBuyAmountInUsdt = _maxBuyAmountInUsdt;
    }

    function setMaxBuyPerDay(uint256 _maxBuyPerDay) external onlyMinter {
        require(_maxBuyPerDay > 0, "Invalid max buy per day");
        maxBuyPerDay = _maxBuyPerDay;
    }

    function setTransferCooldown(
        uint256 _transferCooldown
    ) external onlyMinter {
        transferCooldown = _transferCooldown;
    }

    function setFeeRates(
        uint256 _marketFeeRate,
        uint256 _burnFeeRate,
        uint256 _treasuryRate,
        uint256 _rewardRate
    ) external onlyMinter {
        require(
            _marketFeeRate + _burnFeeRate + _treasuryRate + _rewardRate <
                RATIO_PRECISION,
            "Total fee rate cannot exceed 100%"
        );
        require(_marketFeeRate > 0, "Market fee rate cannot be 0");
        require(_burnFeeRate > 0, "Burn fee rate cannot be 0");
        require(_treasuryRate > 0, "Treasury rate cannot be 0");
        require(_rewardRate > 0, "Reward rate cannot be 0");

        marketFeeRate = _marketFeeRate;
        burnFeeRate = _burnFeeRate;
        treasuryRate = _treasuryRate;
        rewardRate = _rewardRate;
    }

    function _checkAndUpdateBuyCount(address buyer) internal {
        uint256 currentTime = block.timestamp;
        uint256 lastBuy = lastBuyTime[buyer];

        // if last buy time is more than 24 hours, reset buy count
        if (currentTime >= lastBuy + 24 hours) {
            buyCount[buyer] = 1;
        } else {
            // check if exceed max buy count in 24 hours
            require(buyCount[buyer] < maxBuyPerDay, "Exceeds daily buy limit");
            buyCount[buyer]++;
        }

        lastBuyTime[buyer] = currentTime;
        lastTransferTime[buyer] = currentTime; // record buy time, for transfer cooldown
    }

    function _checkTransferCooldown(address from) internal view {
        if (lastTransferTime[from] > 0) {
            require(
                block.timestamp >= lastTransferTime[from] + transferCooldown,
                "Transfer cooldown active"
            );
        }
    }

    function getBuyInfo(
        address account
    )
        external
        view
        returns (
            uint256 currentBuyCount,
            uint256 timeUntilReset,
            uint256 timeUntilTransfer
        )
    {
        currentBuyCount = buyCount[account];
        uint256 lastBuy = lastBuyTime[account];

        if (lastBuy > 0) {
            if (block.timestamp >= lastBuy + 24 hours) {
                timeUntilReset = 0; // already can reset
            } else {
                timeUntilReset = lastBuy + 24 hours - block.timestamp;
            }
        }

        uint256 lastTransfer = lastTransferTime[account];
        if (lastTransfer > 0) {
            if (block.timestamp >= lastTransfer + transferCooldown) {
                timeUntilTransfer = 0; // already can transfer
            } else {
                timeUntilTransfer =
                    lastTransfer +
                    transferCooldown -
                    block.timestamp;
            }
        }
    }

    function resetBuyRecord(address account) external onlyMinter {
        buyCount[account] = 0;
        lastBuyTime[account] = 0;
        lastTransferTime[account] = 0;
    }

    function resetBuyRecordBatch(
        address[] calldata accounts
    ) external onlyMinter {
        for (uint256 i = 0; i < accounts.length; i++) {
            buyCount[accounts[i]] = 0;
            lastBuyTime[accounts[i]] = 0;
            lastTransferTime[accounts[i]] = 0;
        }
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        require(value > 0, "Invalid value");

        if (whitelisted[from] || whitelisted[to]) {
            super._update(from, to, value);
            emit SystemTransfer(from, to, value);
            return;
        }

        // buy or remove liquidity
        if (from == mainPair) {
            require(buyState, "Buy not allowed");
            require(
                ((value * getPrice()) / 1e18) <= maxBuyAmountInUsdt,
                "Exceeds max buy amount"
            );
            // check and update buy limit
            _checkAndUpdateBuyCount(to);
            emit FlowOutPool(from, to, value);
            super._update(from, to, value);
            return;
        }

        // sell or add liquidity
        if (to == mainPair) {
            require(sellState, "Sell not allowed");
            // check transfer cooldown
            _checkTransferCooldown(from);

            uint256 marketFee = (value * marketFeeRate) / RATIO_PRECISION;
            uint256 burnAmount = (value * burnFeeRate) / RATIO_PRECISION;
            if (!isLpStopBurn()) {
                super._update(from, DEAD, burnAmount);
            } else {
                super._update(from, marketAddress, burnAmount);
            }
            super._update(from, marketAddress, marketFee);
            uint256 totalFee = marketFee + burnAmount;
            uint256 treasuryAmount = (value * treasuryRate) / RATIO_PRECISION;
            uint256 rewardAmount = (value * rewardRate) / RATIO_PRECISION;
            uint256 burnPoolAmount = treasuryAmount + rewardAmount;
            uint poolAmount = this.balanceOf(mainPair);
            if (poolAmount > burnPoolAmount) {
                // treasury pool
                super._update(mainPair, treasuryAddress, treasuryAmount);
                // reward pool
                super._update(mainPair, rewardPoolAddress, rewardAmount);
                IUniswapV2Pair(mainPair).sync();
            }
            value = value - totalFee;
            emit FlowIntoPool(
                from,
                to,
                value,
                marketFee,
                burnAmount,
                treasuryAmount,
                rewardAmount
            );
        }

        // check transfer cooldown
        if (from != mainPair && to != mainPair) {
            _checkTransferCooldown(from);
        }

        super._update(from, to, value);
    }

    function isLpStopBurn() public view returns (bool) {
        if (!lpBurnEnabled) return true;
        uint zeroAddrAmount = super.balanceOf(address(DEAD));
        uint surplusAmount = super.totalSupply() - zeroAddrAmount;
        if (surplusAmount < 10_000_000 * 10 ** decimals()) {
            return true;
        }
        return false;
    }

    function getTokenPrice()
        external
        view
        returns (uint256 price, uint256 tokenReserve, uint256 usdtReserve)
    {
        IUniswapV2Pair pair = IUniswapV2Pair(mainPair);
        (uint reserve0, uint reserve1, ) = pair.getReserves();

        address token0 = pair.token0();

        if (token0 == address(this)) {
            tokenReserve = reserve0;
            usdtReserve = reserve1;
            if (tokenReserve > 0) {
                price = (usdtReserve * 1e18) / tokenReserve;
            }
        } else {
            tokenReserve = reserve1;
            usdtReserve = reserve0;
            if (tokenReserve > 0) {
                price = (usdtReserve * 1e18) / tokenReserve;
            }
        }
    }

    function getPrice() public view returns (uint256 price) {
        (price, , ) = this.getTokenPrice();
    }
}
