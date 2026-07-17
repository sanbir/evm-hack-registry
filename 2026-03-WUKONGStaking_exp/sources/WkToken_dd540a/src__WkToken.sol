// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AbstractPriceStorage} from "./abstract/AbstractPriceStorage.sol";
import {INodeNFT} from "./interfaces/INodeNFT.sol";
import {Helper} from "./util/Helper.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IUniswapV2Factory} from "v2-core/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "v2-core/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Router02} from "v2-periphery/interfaces/IUniswapV2Router02.sol";

contract WkToken is ERC20, Ownable, AbstractPriceStorage, ReentrancyGuard {
    // 根据底池深度，自动开通买 例如：1000 BNB
    uint256 public BUY_THRESHOLD = 1000 ether;
    // 百分比底数
    uint256 public PERCENT_BASE = 10000;
    // 每日通缩比例
    uint256 public DAILY_DECREASE_RATE = 200;
    // 路由合约地址
    address public UNISWAP_ROUTER_ADDR;
    IUniswapV2Router02 public immutable uniswapV2Router;
    IUniswapV2Pair public immutable uniswapV2Pair;
    address public immutable UNISWAP_PAIR_ADDR;
    // 营销地址
    address public MARKET_ADDR;
    // address WETH
    address public WETH_ADDR;
    // usdt地址
    address public USDT_ADDR;

    // 中间转换地址
    Distributor public distributor;
    // 提现地址 也就是发放奖励的地址
    address public WITHDRAW_ADDR;
    // 管理员地址（用于开通购买功能）
    address public ADMIN_ADDR;
    // nft合约地址
    address public NFT_ADDR;
    // 兜底地址
    address public COVER_ADDR;
    // 购买开关
    bool public purchaseOpen = false;
    // 通缩开始时间
    uint256 public descreasedOpenTime;
    // 通缩记录
    mapping(uint256 => bool) public descreaseRecord;
    // 相关开关
    mapping(address => bool) public SWAP_V2_PAIRS;
    // 禁止名单
    mapping(address => bool) public BANNED_LIST;
    // 白名单
    mapping(address => bool) public WHITE_LIST;
    // 每个地址的成本
    mapping(address => uint256) public ADDRESS_COST;

    // 定义相关费用累加，因为只有卖出的时候才能兑换

    uint256 public totalMarketFee; // 市场费用

    uint256 public totalNFTDividend; // nft分红池

    uint256 public totalV7Dividend; // v7分红

    uint256 public totalV6Dividend; // v6分红

    uint256 public totalCoverAmount; // 沉淀

    // 兑换阈值
    uint256 public swapFundThreshold = 10000 ether;

    // 通缩间隔，默认1天
    uint256 public DECREASE_INTERVAL = 1 days;

    // 事件
    // 1: 分红池事件
    event DividendPool(address indexed to, uint256 tokenAmount, uint256 amount);
    // 2: 营销费用事件
    event MarketFee(address indexed to, uint256 tokenAmount, uint256 amount);
    // 3: V7分红事件
    event V7Dividend(address indexed to, uint256 tokenAmount, uint256 amount);
    // 4: V6分红事件
    event V6Dividend(address indexed to, uint256 tokenAmount, uint256 amount);
    // 5: 兜底事件
    event CoverAmount(address indexed to, uint256 tokenAmount, uint256 amount);
    // 6: NFT通缩事件
    event NFTDecrease(uint256 amount);
    // 7: 动态通缩事件
    event DynamicDecrease(uint256 amount);
    // 8: 静态通缩事件
    event StaticDecrease(uint256 amount);

    using SafeERC20 for IERC20;

    constructor(address _routerAddr, address _usdtAddr, address _withdrawAddr, address _nftAddr, address _marketAddr)
        ERC20("WUKONG", "WUKONG")
        Ownable(msg.sender)
    {
        UNISWAP_ROUTER_ADDR = _routerAddr;
        USDT_ADDR = _usdtAddr;
        WITHDRAW_ADDR = _withdrawAddr;
        NFT_ADDR = _nftAddr;
        MARKET_ADDR = _marketAddr;
        uniswapV2Router = IUniswapV2Router02(_routerAddr);
        WETH_ADDR = IUniswapV2Router02(_routerAddr).WETH();
        UNISWAP_PAIR_ADDR = IUniswapV2Factory(uniswapV2Router.factory()).createPair(address(this), WETH_ADDR);
        uniswapV2Pair = IUniswapV2Pair(UNISWAP_PAIR_ADDR);
        require(uniswapV2Pair.token0() == WETH_ADDR, "token0 must WETH!");
        distributor = new Distributor(WETH_ADDR);
        SWAP_V2_PAIRS[UNISWAP_PAIR_ADDR] = true;
        WHITE_LIST[UNISWAP_ROUTER_ADDR] = true;
        WHITE_LIST[address(this)] = true;
        WHITE_LIST[address(distributor)] = true;
        WHITE_LIST[msg.sender] = true;
        WHITE_LIST[NFT_ADDR] = true;
        _init(address(this), WETH_ADDR, UNISWAP_PAIR_ADDR);
        address usdtWethPair = IUniswapV2Factory(uniswapV2Router.factory()).getPair(USDT_ADDR, WETH_ADDR);
        _initUsdtPair(USDT_ADDR, usdtWethPair);
        // 设置管理员地址为部署者
        ADMIN_ADDR = msg.sender;
        _approve(address(this), UNISWAP_ROUTER_ADDR, type(uint256).max);
        _approve(address(this), NFT_ADDR, type(uint256).max);
        // 铸造2.1亿个代币
        // super._mint(msg.sender, 21000_0000 ether);
        super._update(address(0), msg.sender, 21000_0000 ether);
    }

    /**
     * @notice 接收 BNB，用于开通购买功能
     * @dev
     * - 管理员发送 0.00001 BNB 开通购买
     * - 其他金额直接拒绝
     */
    receive() external payable {
        // require(msg.sender == ADMIN_ADDR, "Only admin can open purchase");

        if (msg.sender == ADMIN_ADDR) {
            // 开通购买功能
            if (msg.value == 0.000001 ether) {
                purchaseOpen = true;
            }
            // 将 BNB 转回给发送者
            payable(ADMIN_ADDR).transfer(msg.value);
        }
    }

    // 重写_update
    /**
     * @notice 更新函数，实现税收和黑名单逻辑,
     * @dev 重写 ERC20 的 _update 函数，添加业务逻辑
     */
    function _update(address from, address to, uint256 amount) internal override {
        require(!BANNED_LIST[from], "BANNED_LIST");

        bool isBuy = SWAP_V2_PAIRS[from];
        bool isSell = SWAP_V2_PAIRS[to];
        if (isBuy || isSell) {
            _syncPrice();
        }

        (uint112 reserveWeth, uint112 reserveThis,) = uniswapV2Pair.getReserves();
        // 免税地址直接转账
        if (WHITE_LIST[from] || WHITE_LIST[to]) {
            super._update(from, to, amount);
            // 白名单转账才通缩
            if (!(isBuy || isSell)) {
                _processBurn(reserveThis);
            }
            return;
        }
        // 限制合约买入，除非是LP，要求地址不能开通智能用户
        // require(!Helper.isContract(to) || UNISWAP_PAIR_ADDR == to, "contract");
        if (isBuy) {
            require(purchaseOpen, "not open");
        }
        // 买税：3%，接收都是用户
        if (isBuy) {
            uint256 taxAmount = amount * 300 / PERCENT_BASE;
            super._update(from, address(this), taxAmount);
            totalMarketFee += taxAmount;
            uint256 amountWethBuy = Helper.getAmountIn(amount, reserveWeth, reserveThis);
            ADDRESS_COST[to] += amountWethBuy;
            super._update(from, to, amount - taxAmount);
        } else if (isSell) {
            swapFund();
            // 发送者是用户
            // 卖税：5% NFT分红池，3%营销地址，2%分V7
            uint256 nftAmount = amount * 500 / PERCENT_BASE;
            super._update(from, address(this), nftAmount);
            totalNFTDividend += nftAmount;
            uint256 maketAmount = amount * 300 / PERCENT_BASE;
            super._update(from, address(this), maketAmount);
            totalMarketFee += maketAmount;
            uint256 v7Amount = amount * 200 / PERCENT_BASE;
            super._update(from, address(this), v7Amount);
            totalV7Dividend += v7Amount;
            uint256 tranferfinal = amount - nftAmount - maketAmount - v7Amount;
            // 处理盈利税
            uint256 amountWethOut = Helper.getAmountOut(amount - maketAmount - v7Amount, reserveThis, reserveWeth);
            // 盈利金额
            uint256 profitAmount;
            if (ADDRESS_COST[from] >= amountWethOut) {
                ADDRESS_COST[from] -= amountWethOut;
            } else if (ADDRESS_COST[from] > 0 && amountWethOut > ADDRESS_COST[from]) {
                profitAmount = amountWethOut - ADDRESS_COST[from];
                ADDRESS_COST[from] = 0;
            } else {
                profitAmount = amountWethOut;
                ADDRESS_COST[from] = 0;
            }
            // 2%分V6，2%分V7，1%沉淀地址
            if (profitAmount > 0) {
                uint256 profitAmountWK = Helper.getAmountOut(profitAmount, reserveWeth, reserveThis);

                uint256 v6AmountProfit = profitAmountWK * 200 / PERCENT_BASE;
                totalV6Dividend += v6AmountProfit;
                super._update(from, address(this), v6AmountProfit);
                tranferfinal -= v6AmountProfit;

                uint256 v7AmountProfit = profitAmountWK * 200 / PERCENT_BASE;
                totalV7Dividend += v7AmountProfit;
                super._update(from, address(this), v7AmountProfit);
                tranferfinal -= v7AmountProfit;

                uint256 coverAmountProfit = profitAmountWK * 100 / PERCENT_BASE;
                totalCoverAmount += coverAmountProfit;
                super._update(from, address(this), coverAmountProfit);
                tranferfinal -= coverAmountProfit;
            }

            // 计算熔断机制
            // 如果价格下跌超过熔断阈值，则触发熔断,额外的10%到营销地址
            if (getPriceChange() + 2000 < 0) {
                uint256 marketAmount = amount * 1000 / PERCENT_BASE;
                super._update(from, MARKET_ADDR, marketAmount);
                tranferfinal -= marketAmount;
            }
            // todo 处理兑换并生成BNB给到对应地址
            super._update(from, to, tranferfinal);
        } else {
            super._update(from, to, amount);
        }
    }

    function swapFund() internal {
        uint256 totalFee = totalMarketFee + totalV7Dividend + totalV6Dividend + totalCoverAmount + totalNFTDividend;
        if (totalFee < swapFundThreshold) {
            return;
        }
        // 将代币余额兑换成ETH
        tokenToEthSwap(totalFee, address(distributor));
        uint256 swapAmount = payable(address(distributor)).balance;
        // 按比例
        if (totalMarketFee > 0) {
            uint256 _marketFee = totalMarketFee * swapAmount / totalFee;
            distributor.transfer(MARKET_ADDR, _marketFee);
            emit MarketFee(MARKET_ADDR, totalMarketFee, _marketFee);
            totalMarketFee = 0;
        }
        if (totalV7Dividend > 0) {
            uint256 _v7Dividend = totalV7Dividend * swapAmount / totalFee;
            distributor.transfer(WITHDRAW_ADDR, _v7Dividend);
            emit V7Dividend(WITHDRAW_ADDR, totalV7Dividend, _v7Dividend);
            totalV7Dividend = 0;
        }
        if (totalV6Dividend > 0) {
            uint256 _v6Dividend = totalV6Dividend * swapAmount / totalFee;
            distributor.transfer(WITHDRAW_ADDR, _v6Dividend);
            emit V6Dividend(WITHDRAW_ADDR, totalV6Dividend, _v6Dividend);
            totalV6Dividend = 0;
        }
        if (totalCoverAmount > 0) {
            uint256 _coverAmount = totalCoverAmount * swapAmount / totalFee;
            distributor.transfer(COVER_ADDR, _coverAmount);
            emit CoverAmount(COVER_ADDR, totalCoverAmount, _coverAmount);
            totalCoverAmount = 0;
        }
        if (totalNFTDividend > 0) {
            uint256 _nftDividend = totalNFTDividend * swapAmount / totalFee;
            distributor.transfer(address(this), _nftDividend); // 先转给自己
            INodeNFT(NFT_ADDR).addBNBDividend{value: _nftDividend}();
            emit DividendPool(NFT_ADDR, totalNFTDividend, _nftDividend);
            totalNFTDividend = 0;
        }
    }

    // 通缩分配2% 80%销毁，20% LP挖矿, 最小20%销毁，每天减少0.5 LP挖矿：5%进NFT池，20%动态，75%静态
    function _processBurn(uint112 reserveThis) internal {
        // 如果已经通缩过，则不执行
        if (reserveThis == 0 || descreasedOpenTime == 0 || descreasedOpenTime > block.timestamp) {
            return;
        }
        // 计算通缩间隔
        uint256 openDays = getBurnDays();
        if (openDays == 0 || descreaseRecord[openDays]) {
            return;
        }
        descreaseRecord[openDays] = true;
        uint256 burnRate = openDays < 120 ? 50 * (openDays - 1) : 6000;
        // 计算通缩比例
        uint256 burnAmount = reserveThis * (8000 - burnRate) * 200 / (PERCENT_BASE * PERCENT_BASE);
        // 执行销毁
        super._update(UNISWAP_PAIR_ADDR, address(0xdEaD), burnAmount);

        uint256 lpAmount = reserveThis * (2000 + burnRate) * 200 / (PERCENT_BASE * PERCENT_BASE);
        // 5% NFT通缩分红池
        uint256 nftAmount = lpAmount * 500 / PERCENT_BASE;
        super._update(UNISWAP_PAIR_ADDR, address(this), nftAmount);
        INodeNFT(NFT_ADDR).addDividend(address(this), nftAmount);
        emit NFTDecrease(nftAmount);
        // 20%动态通缩分红池,中心化分配
        uint256 dynamicAmount = lpAmount * 2000 / PERCENT_BASE;
        super._update(UNISWAP_PAIR_ADDR, WITHDRAW_ADDR, dynamicAmount);
        emit DynamicDecrease(dynamicAmount);
        // 75%静态通缩分红池,中心化分配
        uint256 staticAmount = lpAmount * 7500 / PERCENT_BASE;
        super._update(UNISWAP_PAIR_ADDR, WITHDRAW_ADDR, staticAmount);
        emit StaticDecrease(staticAmount);
        uniswapV2Pair.sync();
    }

    // 计算交易开放开数
    function getBurnDays() public view returns (uint256) {
        return (block.timestamp - descreasedOpenTime) / DECREASE_INTERVAL;
    }

    /**
     * @notice 用代币兑换 ETH
     */
    function tokenToEthSwap(uint256 amountIn, address recipient) internal {
        require(amountIn > 0, "Invalid input amount");
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WETH_ADDR;
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amountIn, 0, path, recipient, block.timestamp + 60
        );
    }

    // 参数配置如下
    function setBuyThreshold(uint256 _threshold) public onlyOwner {
        BUY_THRESHOLD = _threshold;
    }

    // 设置每日通缩比例
    function setDailyDecreaseRate(uint256 _rate) public onlyOwner {
        DAILY_DECREASE_RATE = _rate;
    }

    // 设置营销地址
    function setMarketAddr(address _addr) public onlyOwner {
        MARKET_ADDR = _addr;
    }

    // 设置管理员地址
    function setAdminAddr(address _addr) public onlyOwner {
        require(_addr != address(0), "Invalid admin address");
        ADMIN_ADDR = _addr;
    }

    // 开通购买功能
    function openPurchase() public onlyOwner {
        purchaseOpen = true;
    }

    // 关闭购买功能
    function closePurchase() public onlyOwner {
        purchaseOpen = false;
    }

    // 批量设置BANNED_LIST
    function setBannedList(address[] memory _list) public onlyOwner {
        for (uint256 i = 0; i < _list.length; i++) {
            BANNED_LIST[_list[i]] = true;
        }
    }

    // 批量移除BANNED_LIST
    function removeBannedList(address[] memory _list) public onlyOwner {
        for (uint256 i = 0; i < _list.length; i++) {
            BANNED_LIST[_list[i]] = false;
        }
    }

    // 批量设置白名单
    function setWhiteList(address[] memory _list) public onlyOwner {
        for (uint256 i = 0; i < _list.length; i++) {
            WHITE_LIST[_list[i]] = true;
        }
    }
    // 批量移除白名单

    function removeWhiteList(address[] memory _list) public onlyOwner {
        for (uint256 i = 0; i < _list.length; i++) {
            WHITE_LIST[_list[i]] = false;
        }
    }

    // 设置通缩间隔
    function setDecreaseInterval(uint256 _interval) public onlyOwner {
        DECREASE_INTERVAL = _interval;
    }

    // 设置开放时间 purchaseOpenTime
    function setPurchaseOpenTime(uint256 _time) public onlyOwner {
        descreasedOpenTime = _time;
    }

    // 设置NFT_ADDR
    function setNftAddr(address _addr) public onlyOwner {
        if (NFT_ADDR != address(0)) {
            WHITE_LIST[NFT_ADDR] = false;
        }
        NFT_ADDR = _addr;
        WHITE_LIST[NFT_ADDR] = true;
    }

    // 设置COVER_ADDR
    function setCoverAddr(address _addr) public onlyOwner {
        COVER_ADDR = _addr;
    }

    // 设置兑换阈值
    function setSwapFundThreshold(uint256 _threshold) public onlyOwner {
        swapFundThreshold = _threshold;
    }

    // 设置提现合约地址
    function setWithdrawAddr(address _addr) public onlyOwner {
        WITHDRAW_ADDR = _addr;
    }
}

// 代币兑换WETH会到这个地址
contract Distributor is Ownable {
    constructor(address _weth) Ownable(msg.sender) {
        IERC20(_weth).approve(msg.sender, type(uint256).max);
    }

    // 转出合约里所有的eth
    function transfer(address to, uint256 amount) external payable onlyOwner {
        // payable(to).transfer{gas: 3000}(amount);
        (bool success,) = payable(to).call{gas: 30000, value: amount}("");
        require(success, "Failed to transfer BNB");
    }
    // 增加receive方法
    receive() external payable {}
}
