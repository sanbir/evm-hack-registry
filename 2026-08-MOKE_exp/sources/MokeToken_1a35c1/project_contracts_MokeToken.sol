// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IMokeToken.sol";
import "./interfaces/IMokeLPDividend.sol";

interface IPancakePairT {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function mint(address to) external returns (uint256 liquidity);
    function sync() external;
}

interface IPancakeRouterT {
    function WETH() external pure returns (address);
    function factory() external pure returns (address);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path,
        address to, uint256 deadline
    ) external;
}

interface IPancakeFactoryT {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/**
 * @title SwapReceiver
 * @dev Swap relay contract — avoids triggering _update on swap output.
 *      Supports both ERC-20 tokens and native ETH/BNB.
 */
contract SwapReceiver {
    using SafeERC20 for IERC20;
    address public immutable owner;

    constructor() {
        owner = msg.sender;
    }

    function sweep(address token, address to) external {
        require(msg.sender == owner, "Not owner");
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(to, balance);
        }
    }

    function sweepETH(address to) external {
        require(msg.sender == owner, "Not owner");
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool sent,) = payable(to).call{value: balance}("");
            require(sent, "ETH transfer failed");
        }
    }

    receive() external payable {}
}

// PancakeSwap V2 Router (BSC Mainnet)
address constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

contract MokeToken is ERC20, Ownable, IMokeToken {
    using SafeERC20 for IERC20;

    uint256 public constant TOTAL_SUPPLY = 210_000_000 * 1e18;
    uint256 public constant RECEIVER_SUPPLY = 10_000_000 * 1e18;
    uint256 public constant RESERVE_SUPPLY = 200_000_000 * 1e18;
    uint256 public constant BASIS_POINTS = 10000;

    uint256 public lpDivRate = 200;
    uint256 public nftDivRate = 200;
    uint256 public marketingRate = 100;

    bool public tradingEnabled;
    address public marketingWallet;

    address public lpDividendPool;
    address public nftDividendPool;

    IPancakeRouterT public router;
    address public pancakePair;
    SwapReceiver public swapReceiver;

    mapping(address => bool) public isWhitelisted;
    mapping(address => bool) public isExcludedFromTax;
    mapping(address => bool) public isMarketPair;

    // --- Tax accumulation (TokenA pattern) ---
    uint256 public accumulatedLpTax;
    uint256 public accumulatedNftTax;
    uint256 public accumulatedMarketingTax;
    uint256 public swapThreshold = 10000 * 1e18;
    uint256 public maxSwapAmount = 100000 * 1e18;
    uint256 public swapSlippageBps = 1500;

    uint256 public pendingLpBNB;
    uint256 public pendingNftBNB;
    uint256 public pendingMarketingBNB;

    // --- Released MOKE restriction ---
    mapping(address => uint256) public releasedMokeBalance;
    address public releaseContract;
    mapping(address => bool) public isReleasedMokeHandler;
    mapping(address => bool) public canManageReleasedBalance;

    // --- LP Removal Burn Detection ---
    address public weth;
    bool public isWethToken0;
    bool public lpRemovalBurnEnabled;

    // --- X/MOKE Reserve Pool ---
    address public xMokePair;
    address public tokenXContract;

    bool private inSwap;

    event TradingEnabled(uint256 timestamp);
    event ReleaseContractSet(address indexed release);
    event ReleasedBalanceAdded(address indexed user, uint256 amount);
    event ReleasedBalanceReduced(address indexed user, uint256 amount);
    event TaxRateUpdated(uint256 lpRate, uint256 nftRate, uint256 marketingRate_);
    event MarketPairUpdated(address indexed pair, bool status);
    event MarketingWalletSet(address indexed wallet);
    event WhitelistSet(address indexed account, bool status);
    event ExcludedFromTaxSet(address indexed account, bool status);
    event LPDividendPoolSet(address indexed pool);
    event NFTDividendPoolSet(address indexed pool);
    event TaxCollected(address indexed from, address indexed to, uint256 lpAmount, uint256 nftAmount, uint256 marketingAmount);
    event TaxSwapped(uint256 tokensSwapped, uint256 bnbReceived);
    event TaxDistributed(uint256 lpBNB, uint256 nftBNB, uint256 marketingBNB);
    event EmergencyWithdraw(address indexed token, uint256 amount, address indexed to);
    event SwapThresholdUpdated(uint256 threshold);
    event MaxSwapAmountUpdated(uint256 maxAmount);
    event RouterSet(address indexed router_);
    event LPRemovalBurn(address indexed originalTo, uint256 amount);
    event ReleasedMokeHandlerSet(address indexed handler, bool status);
    event XMokePairSet(address indexed pair);
    event LPRemovalBurnToggled(bool enabled);
    event CanManageReleasedBalanceSet(address indexed addr, bool status);
    event ReservePoolSetup(address indexed pair, address indexed tokenX, uint256 mokeAmount, uint256 tokenXAmount);

    modifier swapping() {
        inSwap = true;
        _;
        inSwap = false;
    }

    constructor(
        address _marketingWallet,
        address _tokenReceiver
    ) ERC20("Moke", "MOKE") Ownable(msg.sender) {
        require(_marketingWallet != address(0), "Invalid marketing wallet");
        require(_tokenReceiver != address(0), "Invalid token receiver");
        marketingWallet = _marketingWallet;
        router = IPancakeRouterT(PANCAKE_ROUTER);
        weth = router.WETH();

        swapReceiver = new SwapReceiver();

        address factory = router.factory();
        address _pair = IPancakeFactoryT(factory).getPair(address(this), weth);
        if (_pair == address(0)) {
            _pair = IPancakeFactoryT(factory).createPair(address(this), weth);
        }
        pancakePair = _pair;
        isMarketPair[_pair] = true;
        isWethToken0 = IPancakePairT(_pair).token0() == weth;

        isExcludedFromTax[msg.sender] = true;
        isExcludedFromTax[address(this)] = true;
        isExcludedFromTax[address(swapReceiver)] = true;
        isExcludedFromTax[_marketingWallet] = true;
        isExcludedFromTax[_tokenReceiver] = true;

        isWhitelisted[msg.sender] = true;
        isWhitelisted[address(this)] = true;
        isWhitelisted[address(swapReceiver)] = true;
        isWhitelisted[_tokenReceiver] = true;

        _mint(_tokenReceiver, RECEIVER_SUPPLY);
        _mint(address(this), RESERVE_SUPPLY);
    }

    // ============ Admin Functions ============

    function enableTrading() external override onlyOwner {
        require(!tradingEnabled, "Already enabled");
        tradingEnabled = true;
        emit TradingEnabled(block.timestamp);
    }

    function isTradingEnabled() external view override returns (bool) {
        return tradingEnabled;
    }

    function setMarketPair(address _pair, bool _status) external override onlyOwner {
        require(_pair != address(0), "Invalid pair");
        isMarketPair[_pair] = _status;
        emit MarketPairUpdated(_pair, _status);
    }

    function setMarketingWallet(address _wallet) external override onlyOwner {
        require(_wallet != address(0), "Invalid wallet");
        isExcludedFromTax[marketingWallet] = false;
        marketingWallet = _wallet;
        isExcludedFromTax[_wallet] = true;
        emit MarketingWalletSet(_wallet);
    }

    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "Invalid router");
        router = IPancakeRouterT(_router);
        weth = router.WETH();
        emit RouterSet(_router);
    }

    function setLPDividendPool(address _pool) external onlyOwner {
        lpDividendPool = _pool;
        if (_pool != address(0)) {
            isExcludedFromTax[_pool] = true;
            isWhitelisted[_pool] = true;
        }
        emit LPDividendPoolSet(_pool);
    }

    function setNFTDividendPool(address _pool) external onlyOwner {
        nftDividendPool = _pool;
        if (_pool != address(0)) {
            isExcludedFromTax[_pool] = true;
            isWhitelisted[_pool] = true;
        }
        emit NFTDividendPoolSet(_pool);
    }

    function setTaxRate(uint256 _lpRate, uint256 _nftRate, uint256 _marketingRate) external override onlyOwner {
        require(_lpRate + _nftRate + _marketingRate <= 1000, "Tax too high");
        lpDivRate = _lpRate;
        nftDivRate = _nftRate;
        marketingRate = _marketingRate;
        emit TaxRateUpdated(_lpRate, _nftRate, _marketingRate);
    }

    function setWhitelist(address account, bool status) external override onlyOwner {
        isWhitelisted[account] = status;
        emit WhitelistSet(account, status);
    }

    function setExcludedFromTax(address account, bool status) external onlyOwner {
        isExcludedFromTax[account] = status;
        emit ExcludedFromTaxSet(account, status);
    }

    function batchSetExcludedFromTax(address[] calldata accounts, bool status) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            isExcludedFromTax[accounts[i]] = status;
        }
    }

    function batchSetWhitelist(address[] calldata accounts, bool status) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            isWhitelisted[accounts[i]] = status;
        }
    }

    function setSwapThreshold(uint256 _threshold) external onlyOwner {
        swapThreshold = _threshold;
        emit SwapThresholdUpdated(_threshold);
    }

    function setMaxSwapAmount(uint256 _maxAmount) external onlyOwner {
        maxSwapAmount = _maxAmount;
        emit MaxSwapAmountUpdated(_maxAmount);
    }

    function setSwapSlippageBps(uint256 _bps) external onlyOwner {
        require(_bps <= 3000, "Max 30%");
        swapSlippageBps = _bps;
    }

    function setPancakePair(address _pair) external onlyOwner {
        require(_pair != address(0), "Invalid pair");
        pancakePair = _pair;
        isWethToken0 = IPancakePairT(_pair).token0() == weth;
    }

    function setReleaseContract(address _release) external onlyOwner {
        releaseContract = _release;
        emit ReleaseContractSet(_release);
    }

    function setReleasedMokeHandler(address handler, bool status) external onlyOwner {
        require(handler != address(0), "Invalid handler");
        isReleasedMokeHandler[handler] = status;
        emit ReleasedMokeHandlerSet(handler, status);
    }

    function setCanManageReleasedBalance(address addr, bool status) external onlyOwner {
        require(addr != address(0), "Invalid address");
        canManageReleasedBalance[addr] = status;
        emit CanManageReleasedBalanceSet(addr, status);
    }

    function setXMokePair(address _pair) external onlyOwner {
        xMokePair = _pair;
        emit XMokePairSet(_pair);
    }

    function setLPRemovalBurn(bool _enabled) external onlyOwner {
        if (_enabled) {
            require(weth != address(0), "WETH not set");
            require(pancakePair != address(0), "Pair not set");
        }
        lpRemovalBurnEnabled = _enabled;
        emit LPRemovalBurnToggled(_enabled);
    }

    /**
     * @dev One-time setup: seeds the X/MOKE reserve pool and permanently locks LP.
     *      Prerequisite: deployer must approve this contract for their full TokenX balance.
     */
    function setupReservePool(address _tokenX) external onlyOwner {
        require(tokenXContract == address(0), "Already setup");
        require(_tokenX != address(0), "Invalid TokenX");
        require(balanceOf(address(this)) >= RESERVE_SUPPLY, "Insufficient MOKE reserve");

        address factory = router.factory();
        address _pair = IPancakeFactoryT(factory).getPair(_tokenX, address(this));
        if (_pair == address(0)) {
            _pair = IPancakeFactoryT(factory).createPair(_tokenX, address(this));
        }

        uint256 xAmount = IERC20(_tokenX).balanceOf(msg.sender);
        require(xAmount > 0, "No TokenX balance");

        IERC20(_tokenX).safeTransferFrom(msg.sender, _pair, xAmount);
        super._update(address(this), _pair, RESERVE_SUPPLY);

        IPancakePairT(_pair).mint(address(0xdead));

        tokenXContract = _tokenX;
        xMokePair = _pair;

        emit ReservePoolSetup(_pair, _tokenX, RESERVE_SUPPLY, xAmount);
        emit XMokePairSet(_pair);
    }

    function addReleasedBalance(address user, uint256 amount) external override {
        require(
            msg.sender == releaseContract || canManageReleasedBalance[msg.sender],
            "Not authorized"
        );
        releasedMokeBalance[user] += amount;
        emit ReleasedBalanceAdded(user, amount);
    }

    function releaseFromPair(address to, uint256 amount) external {
        require(msg.sender == releaseContract, "Only release contract");
        require(xMokePair != address(0), "X/MOKE pair not set");
        super._update(xMokePair, to, amount);
    }

    function setReleasedBalance(address user, uint256 amount) external onlyOwner {
        releasedMokeBalance[user] = amount;
    }

    function clearReleasedBalance(address user) external onlyOwner {
        releasedMokeBalance[user] = 0;
    }

    // ============ Core: _update ============

    function _update(address from, address to, uint256 amount) internal override {
        // Step 1: Mint / Burn — passthrough
        if (from == address(0) || to == address(0)) {
            super._update(from, to, amount);
            return;
        }

        // Step 2: Zero amount
        if (amount == 0) {
            super._update(from, to, 0);
            return;
        }

        // Step 3: Internal swap / self-transfer
        if (inSwap || from == address(this) || to == address(this)) {
            super._update(from, to, amount);
            return;
        }

        // Step 4: Released MOKE restriction — BEFORE exempt (#2 fix)
        // Released MOKE can only go to isReleasedMokeHandler (#3 fix)
        if (releasedMokeBalance[from] > 0) {
            uint256 bal = balanceOf(from);
            uint256 released = releasedMokeBalance[from];
            uint256 freeBalance = bal > released ? bal - released : 0;

            if (isReleasedMokeHandler[to] || isWhitelisted[to]) {
                if (amount > freeBalance) {
                    uint256 releasedUsed = amount - freeBalance;
                    releasedMokeBalance[from] -= releasedUsed;
                    emit ReleasedBalanceReduced(from, releasedUsed);
                }
            } else {
                require(amount <= freeBalance, "Released MOKE: handler only");
            }
        }

        // Step 5: Tax exempt — passthrough
        bool exempt = isExcludedFromTax[from] || isExcludedFromTax[to];
        if (exempt) {
            super._update(from, to, amount);
            return;
        }

        // Step 6: LP removal burn detection (#5)
        // Only for main MOKE/WBNB pair. Handles both token orderings.
        if (from == pancakePair && lpRemovalBurnEnabled) {
            uint256 wethBal = IERC20(weth).balanceOf(pancakePair);
            (uint112 r0, uint112 r1,) = IPancakePairT(pancakePair).getReserves();
            uint256 wethReserve = isWethToken0 ? uint256(r0) : uint256(r1);
            uint256 mokeReserve = isWethToken0 ? uint256(r1) : uint256(r0);

            uint256 maxMokeFromBuy = 0;
            if (wethBal > wethReserve && mokeReserve > 0 && wethReserve > 0) {
                maxMokeFromBuy = (wethBal - wethReserve) * mokeReserve / wethReserve;
            }

            if (amount > maxMokeFromBuy) {
                super._update(from, address(0xdead), amount);
                emit LPRemovalBurn(to, amount);
                return;
            }
        }

        // Step 7: Market pair detection — trading check & tax
        bool isPairInvolved = _isMarketPair(from) || _isMarketPair(to);

        if (isPairInvolved && lpDividendPool != address(0)) {
            _syncLPDividend(from, to);
        }

        if (!tradingEnabled && isPairInvolved) {
            if (_isMarketPair(from)) {
                require(isWhitelisted[to], "Trading not enabled");
            }
            if (_isMarketPair(to)) {
                require(isWhitelisted[from], "Trading not enabled");
            }
        }

        if (isPairInvolved) {
            if (_isMarketPair(to)) {
                _processTaxes();
            }

            uint256 totalTaxRate = lpDivRate + nftDivRate + marketingRate;
            uint256 taxAmount = amount * totalTaxRate / BASIS_POINTS;

            if (taxAmount > 0) {
                uint256 lpAmount = amount * lpDivRate / BASIS_POINTS;
                uint256 nftAmount = amount * nftDivRate / BASIS_POINTS;
                uint256 mktAmount = taxAmount - lpAmount - nftAmount;

                super._update(from, address(this), taxAmount);

                accumulatedLpTax += lpAmount;
                accumulatedNftTax += nftAmount;
                accumulatedMarketingTax += mktAmount;

                emit TaxCollected(from, to, lpAmount, nftAmount, mktAmount);
                amount -= taxAmount;
            }
        }

        super._update(from, to, amount);
    }

    // ============ Market Pair Detection (Multi-DEX) ============

    function _isMarketPair(address target) internal view returns (bool) {
        if (isMarketPair[target]) return true;
        if (target.code.length == 0) return false;

        try IPancakePairT(target).token0() returns (address t0) {
            if (t0 == address(0)) return false;
            try IPancakePairT(target).token1() returns (address t1) {
                if (t1 == address(0)) return false;
                return (t0 == address(this) || t1 == address(this));
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }

    // ============ LP Dividend Sync (try/catch — never blocks transfers) ============

    function _syncLPDividend(address from, address to) internal {
        if (!_isMarketPair(from)) {
            try IMokeLPDividend(lpDividendPool).syncUserLP(from) {} catch {}
        }
        if (!_isMarketPair(to)) {
            try IMokeLPDividend(lpDividendPool).syncUserLP(to) {} catch {}
        }
    }

    // ============ Tax Processing (via SwapReceiver relay) ============

    function _processTaxes() internal {
        uint256 totalTax = accumulatedLpTax + accumulatedNftTax + accumulatedMarketingTax;
        if (totalTax < swapThreshold) return;
        if (address(router) == address(0)) return;

        uint256 lpToProcess = accumulatedLpTax;
        uint256 nftToProcess = accumulatedNftTax;
        uint256 mktToProcess = accumulatedMarketingTax;

        if (totalTax > maxSwapAmount) {
            uint256 ratio = maxSwapAmount * 1e18 / totalTax;
            lpToProcess = accumulatedLpTax * ratio / 1e18;
            nftToProcess = accumulatedNftTax * ratio / 1e18;
            mktToProcess = maxSwapAmount - lpToProcess - nftToProcess;
        }

        uint256 tokensToSwap = lpToProcess + nftToProcess + mktToProcess;
        if (tokensToSwap == 0) return;

        accumulatedLpTax -= lpToProcess;
        accumulatedNftTax -= nftToProcess;
        accumulatedMarketingTax -= mktToProcess;

        uint256 bnbReceived = _swapTokensForBNB(tokensToSwap);
        if (bnbReceived == 0) {
            accumulatedLpTax += lpToProcess;
            accumulatedNftTax += nftToProcess;
            accumulatedMarketingTax += mktToProcess;
            return;
        }

        emit TaxSwapped(tokensToSwap, bnbReceived);

        uint256 lpBNB = bnbReceived * lpToProcess / tokensToSwap;
        uint256 nftBNB = bnbReceived * nftToProcess / tokensToSwap;
        uint256 mktBNB = bnbReceived - lpBNB - nftBNB;

        _distributeTaxBNB(lpBNB, nftBNB, mktBNB);
    }

    /**
     * @dev Swap MOKE -> BNB via SwapReceiver relay.
     *      Router sends ETH to SwapReceiver, then we sweep it back.
     */
    function _swapTokensForBNB(uint256 tokenAmount) internal swapping returns (uint256) {
        if (tokenAmount == 0) return 0;

        _approve(address(this), address(router), tokenAmount);

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        address receiver = address(swapReceiver);
        uint256 receiverBalBefore = receiver.balance;
        uint256 minOut = _getSwapMinOutput(tokenAmount);

        try router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount, minOut, path, receiver, block.timestamp + 300
        ) {
            uint256 bnbReceived = receiver.balance - receiverBalBefore;
            if (bnbReceived > 0) {
                swapReceiver.sweepETH(address(this));
            }
            return bnbReceived;
        } catch {
            return 0;
        }
    }

    function _getSwapMinOutput(uint256 tokenAmount) internal view returns (uint256) {
        if (pancakePair == address(0)) return 0;

        try IPancakePairT(pancakePair).getReserves() returns (uint112 r0, uint112 r1, uint32) {
            address t0 = IPancakePairT(pancakePair).token0();
            uint256 reserveToken;
            uint256 reserveBNB;
            if (t0 == address(this)) { reserveToken = r0; reserveBNB = r1; }
            else { reserveToken = r1; reserveBNB = r0; }
            if (reserveToken == 0 || reserveBNB == 0) return 0;

            uint256 amountInWithFee = tokenAmount * 997;
            uint256 expectedOut = amountInWithFee * reserveBNB / (reserveToken * 1000 + amountInWithFee);
            return expectedOut * (BASIS_POINTS - swapSlippageBps) / BASIS_POINTS;
        } catch {
            return 0;
        }
    }

    function _distributeTaxBNB(uint256 lpBNB, uint256 nftBNB, uint256 mktBNB) internal {
        if (lpBNB > 0 && lpDividendPool != address(0)) {
            (bool sent,) = payable(lpDividendPool).call{value: lpBNB}("");
            if (!sent) { pendingLpBNB += lpBNB; }
        } else if (lpBNB > 0) {
            pendingLpBNB += lpBNB;
        }

        if (nftBNB > 0 && nftDividendPool != address(0)) {
            (bool sent,) = payable(nftDividendPool).call{value: nftBNB}("");
            if (!sent) { pendingNftBNB += nftBNB; }
        } else if (nftBNB > 0) {
            pendingNftBNB += nftBNB;
        }

        if (mktBNB > 0) {
            (bool sent,) = payable(marketingWallet).call{value: mktBNB}("");
            if (!sent) { pendingMarketingBNB += mktBNB; }
        }

        emit TaxDistributed(lpBNB, nftBNB, mktBNB);
    }

    function processTaxesManually() external {
        require(msg.sender == tx.origin, "Only EOA");
        require(!inSwap, "Already swapping");
        _processTaxes();
    }

    function retryDistributePending() external {
        require(msg.sender == tx.origin, "Only EOA");

        uint256 _lpBNB = pendingLpBNB;
        uint256 _nftBNB = pendingNftBNB;
        uint256 _mktBNB = pendingMarketingBNB;

        if (_lpBNB > 0 && lpDividendPool != address(0)) {
            (bool sent,) = payable(lpDividendPool).call{value: _lpBNB}("");
            if (sent) { pendingLpBNB = 0; }
        }
        if (_nftBNB > 0 && nftDividendPool != address(0)) {
            (bool sent,) = payable(nftDividendPool).call{value: _nftBNB}("");
            if (sent) { pendingNftBNB = 0; }
        }
        if (_mktBNB > 0) {
            (bool sent,) = payable(marketingWallet).call{value: _mktBNB}("");
            if (sent) { pendingMarketingBNB = 0; }
        }
    }

    // ============ Query Functions ============

    function getAccumulatedTaxes() external view returns (uint256 lp, uint256 nft, uint256 marketing) {
        return (accumulatedLpTax, accumulatedNftTax, accumulatedMarketingTax);
    }

    function getPendingBNB() external view returns (uint256 lp, uint256 nft, uint256 marketing) {
        return (pendingLpBNB, pendingNftBNB, pendingMarketingBNB);
    }

    // ============ Emergency ============

    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            (bool sent,) = payable(owner()).call{value: amount}("");
            require(sent, "BNB transfer failed");
        } else {
            IERC20(token).safeTransfer(owner(), amount);
        }
        emit EmergencyWithdraw(token, amount, owner());
    }

    receive() external payable {}
}
