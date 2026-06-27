// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {ITokenDistributor} from "./interfaces/ITokenDistributor.sol";

contract EXgirl is Ownable, ERC20 {
    uint256 internal constant PRECISION = 1e18;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant SECONDS_PER_DAY = 86400;
    uint256 internal constant SECONDS_PER_HOUR = 3600;

    address internal immutable token0;
    address internal immutable router;
    address public immutable pair;
    address public immutable liquidityProvider;

    ITokenDistributor public tokenDistributor;
    
    uint256 public purchasedAmount;
    uint256 public dailyOpenPrice;

    struct TimeManagement {
        uint256 startTime;
        uint256 quotaTime;
        uint256 whitelistTime;
        uint256 nextBurnTime;
        uint256 nextOpenTime;
    }
    TimeManagement public timeManagement;  

    struct AdvantageInfo {
        uint256 rebalanceRatio;
        uint256 maxTransferRatio;
        uint256 quotaAmount;
        uint256 declinePercentage;
        uint256 rateMultiplier;
    }
    AdvantageInfo public advantageInfo;

    struct FeeInfo {
        uint256 transferFee;
        uint256 burnFee;
        address transferFeeReceiver;
    }
    FeeInfo public feeInfo;

    struct TxFeeInfo {
        uint96 feeRate;
        address feeReceiver;
    }
    TxFeeInfo[] internal _buyFeeInfos;
    TxFeeInfo[] internal _sellFeeInfos;

    mapping(address => bool) public isExcludedFromFee;

    error InvalidParameters();
    error InvalidInitialization();
    error NotStarted();
    error ExceededAmount();

    constructor(address token0_, address router_, address liquidityProvider_) Ownable(msg.sender) ERC20("EXgirl", "EXgirl") {
        token0 = token0_;
        router = router_;
        liquidityProvider = liquidityProvider_;
        address factory = IUniswapV2Router02(router_).factory();
        pair = IUniswapV2Factory(factory).createPair(token0_, address(this));

        isExcludedFromFee[msg.sender] = true;
        _mint(msg.sender, 21000000e18);
    }

    function startTrade(uint256 startTime) external onlyOwner {
        if (timeManagement.startTime != 0) {
            revert InvalidInitialization();
        }
        timeManagement.startTime = startTime;
        uint256 nextDay = startTime + SECONDS_PER_DAY;
        timeManagement.quotaTime = startTime + SECONDS_PER_DAY * 2;
        timeManagement.whitelistTime = startTime + SECONDS_PER_HOUR * 2;
        timeManagement.nextBurnTime = nextDay;
        timeManagement.nextOpenTime = nextDay;
        uint256 price = getPrice();
        dailyOpenPrice = price;
    }

    function setTokenDistributor(address payable newTokenDistributor) external onlyOwner {
        tokenDistributor = ITokenDistributor(newTokenDistributor);
    }

    function setAdvantageInfo(AdvantageInfo memory newAdvantageInfo) external onlyOwner {
        advantageInfo = newAdvantageInfo;
    }

    function setFeeInfo(FeeInfo memory newFeeInfo) external onlyOwner {
        feeInfo = newFeeInfo;
    }

    function getTxFeeInfos() external view returns (TxFeeInfo[] memory, TxFeeInfo[] memory) {
        return (_buyFeeInfos, _sellFeeInfos);
    }

    function setBuyFeesInfo(TxFeeInfo[] calldata newBuyFeeInfos) external onlyOwner {
        uint256 length = _buyFeeInfos.length;
        if (length == 0) {
            length = newBuyFeeInfos.length;
            for (uint256 i = 0; i < length; i++) {
                _buyFeeInfos.push(newBuyFeeInfos[i]);
            }
        } else {
            if (newBuyFeeInfos.length != length) {
                revert InvalidParameters();
            }
            for (uint256 i = 0; i < length; i++) {
                _buyFeeInfos[i] = newBuyFeeInfos[i];
            }
        }
    }

    function setSellFeeInfos(TxFeeInfo[] calldata newSellFeeInfos) external onlyOwner {
        uint256 length = _sellFeeInfos.length;
        if (length == 0) {
            length = newSellFeeInfos.length;
            for (uint256 i = 0; i < length; i++) {
                _sellFeeInfos.push(newSellFeeInfos[i]);
            }
        } else {
            if (newSellFeeInfos.length != length) {
                revert InvalidParameters();
            }
            for (uint256 i = 0; i < length; i++) {
                _sellFeeInfos[i] = newSellFeeInfos[i];
            }
        }
    }

    function setExcludedFromFee(address account, bool status) external onlyOwner {
        isExcludedFromFee[account] = status;
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        // Update the daily opening price.
        if (timeManagement.nextOpenTime != 0 && block.timestamp > timeManagement.nextOpenTime) {
            timeManagement.nextOpenTime += SECONDS_PER_DAY;
            dailyOpenPrice = getPrice();
        }

        if (from == liquidityProvider || to == liquidityProvider || from == address(tokenDistributor) || to == address(tokenDistributor)) {
            super._update(from, to, value);
            return;
        }

        // The maximum allowable amount for transfers.
        if (from != pair && !isExcludedFromFee[from]) {
            uint256 maxTransferAmount = _getMaximumTransferAmount(from);
            if (value > maxTransferAmount) {
                value = maxTransferAmount;
            }
        }

        // Trading has not yet begun, trading is prohibited.
        if (from == pair || to == pair) {
            if (timeManagement.startTime == 0 || block.timestamp < timeManagement.startTime) {
                revert NotStarted();
            }
            // sell
            if (to == pair && !isAddLiquidity()) {
                if (!isExcludedFromFee[from]) {
                    uint256 length = _sellFeeInfos.length;
                    uint256 tempVal = value;
                    uint256 rateMultiplier = PRECISION;
                    uint256 price = getPrice();
                    if (price * PRECISION <=  dailyOpenPrice * advantageInfo.declinePercentage) {
                        rateMultiplier = advantageInfo.rateMultiplier;
                    }
                    for (uint256 i = 0; i < length; i++) {
                        uint256 feeRate = _sellFeeInfos[i].feeRate * rateMultiplier / PRECISION;
                        uint256 fee = tempVal * feeRate / PRECISION;
                        value -= fee;
                        super._update(from, _sellFeeInfos[i].feeReceiver, fee);
                    }
                }

                // buy
            } else if (from == pair && !isRemoveLiquidity()) {
                if (block.timestamp < timeManagement.whitelistTime && !tokenDistributor.isWhitelist(to)) {
                    revert NotStarted();
                }
                if (block.timestamp < timeManagement.quotaTime) {
                    if (value > advantageInfo.quotaAmount) {
                        revert ExceededAmount();
                    }
                }
                (uint256 reserve0, , ) = IUniswapV2Pair(pair).getReserves();
                uint256 tokenBal = IERC20(token0).balanceOf(pair);
                uint256 purchaseAmount = tokenBal - reserve0;
                purchasedAmount += purchaseAmount;

                // transfer
            }
        } else {
            if (!isExcludedFromFee[from] && !isExcludedFromFee[to]) {
                uint256 fee = value * feeInfo.transferFee / PRECISION;
                value -= fee;
                super._update(from, feeInfo.transferFeeReceiver, fee);
            }
            
            _distribute();
        }
        
        super._update(from, to, value);
    }

    function _getMaximumTransferAmount(address account) internal view returns (uint256) {
        uint256 bal = balanceOf(account);
        return bal * advantageInfo.maxTransferRatio / PRECISION;
    }

    function getPrice() public view returns (uint256) {
        (uint256 reserve0, uint256 reserve1, ) = IUniswapV2Pair(pair).getReserves();
        return reserve0 * PRECISION / reserve1; 
    }

    function _distribute() internal {
        if (purchasedAmount <= 1) {
            return;
        }
        // Calculate the quantity of tokens to be sold.
        uint256 price = getPrice();
        uint256 pendingSaleAmount = purchasedAmount * advantageInfo.rebalanceRatio / PRECISION - 1;
        purchasedAmount = 1;
        uint256 amountIn = pendingSaleAmount * PRECISION / price;
        tokenDistributor.distributeA(amountIn);
    }

    function isAddLiquidity() internal view returns (bool) {
        (uint256 reserve0, , ) = IUniswapV2Pair(pair).getReserves();
        uint256 tokenBal = IERC20(token0).balanceOf(pair);
        if (tokenBal > reserve0) {
            return true;
        }
        return false;
    }

    function isRemoveLiquidity() internal view returns (bool) {
        (uint256 reserve0, , ) = IUniswapV2Pair(pair).getReserves();
        uint256 tokenBal = IERC20(token0).balanceOf(pair);
        if (tokenBal < reserve0) {
            return true;
        }
        return false;
    }

    function burnPool() external {
        if (block.timestamp > timeManagement.nextBurnTime) {
            timeManagement.nextBurnTime += SECONDS_PER_DAY;
            uint256 bal = balanceOf(pair);
            super._update(pair, DEAD, bal * feeInfo.burnFee / PRECISION);
            IUniswapV2Pair(pair).sync();
        }
    }

}