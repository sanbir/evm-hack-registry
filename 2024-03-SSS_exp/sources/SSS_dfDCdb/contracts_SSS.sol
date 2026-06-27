// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ERC20} from "./ERC20.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router02.sol";
import {IBlast, IBlastPoints} from "./interfaces/IBlast.sol";

interface IUniswapFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

contract SSS is Ownable, ERC20 {
    uint256 constant TOTAL_SUPPLY = 555_555_555_555_555 * 10**18; // 555.555 trillions

    uint256 constant DEX_SUPPLY         = TOTAL_SUPPLY*80/100; // 80%
    uint256 constant ECOSYSTEM_SUPPLY   = TOTAL_SUPPLY*5/100; // 5%
    uint256 constant BOOSTER_SUPPLY     = TOTAL_SUPPLY*5/100; // 5%
    uint256 constant AIRDROP_SUPPLY     = TOTAL_SUPPLY*5/100; // 5%
    uint256 constant DEV_SUPPLY         = TOTAL_SUPPLY*5/100; // 5%

    address public communityAddress;
    address public devTaxReceiverAddress;
    address public devTokenReceiverAddress;

    uint256 public buyTaxPercent = 2_00; // 2%
    uint256 public sellTaxPercent = 2_00; // 2%

    uint256 public devPercent = 20_00; // 0.4% = 20% of 2%
    uint256 public communityPercent = 80_00; // 1.6% = 80% of 2%

    uint256 public devTaxTokenAmountAvailable;
    uint256 public communityTaxTokenAmountAvailable;

    uint256 public devTokenAmountClaimable; // unlock from DEV_SUPPLY
    uint256 public devTokenAmountRemain = DEV_SUPPLY; // unlock from DEV_SUPPLY
    uint256 public tradeVolume = 0;

    // limit config
    bool public limitEnabled = true;
    uint256 public maxAmountPerTx = TOTAL_SUPPLY * 5/100_00; // 0.05% of total supply
    uint256 public maxAmountPerAccount = TOTAL_SUPPLY * 5/100_00; // 0.05% of total supply

    address public immutable uniswapV2Pair;
    IUniswapV2Router02 public immutable uniswapV2Router;
    IBlast public immutable blastGasModeContract;

    uint256 constant LIMIT_ROUND_DEC = 10**12; // 50.00000000001 should be treated as 50
    uint256 public immutable ANTI_BOT_DETECT_DURATION;
    uint256 public immutable ANTI_BOT_LOCK_DURATION;
    uint256 public startPoolTime;
    mapping(address => uint256) public botBuyTimes;

    mapping(address => bool) public liquidityPools;
    mapping(address => bool) public unlimiteds;
    mapping(address => bool) public excludeFromTaxes;


    event SetLiquidityPool(address pool, bool isPool);
    event SetUnlimited(address addr, bool isUnlimited);
    event SetExcludeFromTax(address account, bool exclude);
    event ClaimGasFee(address recipient, uint256 amount);

    constructor(
        address community,
        address devTaxReceiver,
        address devTokenReceiver,
        address routerAddress,
        address blastGasModeContractAddress,
        address blastPointAddress,
        address blastPointOperator,
        uint256 antiBotDetectDuration,
        uint256 antiBotLockDuration
    ) ERC20("SSS", "SSS") Ownable(msg.sender) {
        communityAddress = community;
        devTaxReceiverAddress = devTaxReceiver;
        devTokenReceiverAddress = devTokenReceiver;
        ANTI_BOT_DETECT_DURATION = antiBotDetectDuration;
        ANTI_BOT_LOCK_DURATION = antiBotLockDuration;

        _setExcludeFromTax(msg.sender, true);
        _setExcludeFromTax(address(this), true);
        _setExcludeFromTax(community, true);

        uniswapV2Router = IUniswapV2Router02(routerAddress);

        _mint(address(this), DEV_SUPPLY + DEX_SUPPLY);
        _mint(msg.sender, ECOSYSTEM_SUPPLY + BOOSTER_SUPPLY + AIRDROP_SUPPLY); // manually distribute to other addresses

        // create pair in advance without LP
        IUniswapFactory uniswapV2Factory = IUniswapFactory(uniswapV2Router.factory());
        uniswapV2Pair = uniswapV2Factory.createPair(address(this), uniswapV2Router.WETH());
        liquidityPools[uniswapV2Pair] = true;

        _setUnlimited(uniswapV2Pair, true);
        _setUnlimited(routerAddress, true);
        _setUnlimited(address(this),true);
        _setUnlimited(community, true);
        _setUnlimited(devTaxReceiver, true);
        _setUnlimited(devTokenReceiver, true);

        blastGasModeContract = IBlast(blastGasModeContractAddress);
        blastGasModeContract.configureClaimableGas();
        IBlastPoints(blastPointAddress).configurePointsOperator(blastPointOperator);

    }

    function _update(address from, address to, uint256 amount) internal override virtual {
        // don't check if it is minting or burning
        if (from == address(0) || to == address(0) || to == address(0xdead)) {
            super._update(from, to, amount);
            return;
        }

        _botCheck(from, to);
        uint256 fromBalanceBeforeTransfer = _preCheck(from, to, amount);

        uint256 amountAfterTax = amount - _taxApply(from, to, amount);
        uint256 toBalance = _postCheck(from, to, amountAfterTax);

        _balances[from] = fromBalanceBeforeTransfer - amount;
        _balances[to] = toBalance;

        _unlockTokenForDev(from, to, amount);

        emit Transfer(from, to, amountAfterTax);
    }

    // Buy too fast after init pool is bot
    function _botCheck(address from, address to) internal {
        uint256 initPoolTime = startPoolTime;
        if (initPoolTime == 0) return;

        // buy in 30s after init pool is bot
        if (block.timestamp - initPoolTime < ANTI_BOT_DETECT_DURATION
            && isLiquidityPool(from)
        ) {
            botBuyTimes[to] = block.timestamp;
            return;
        }

        // Lock bot
        if (botBuyTimes[from] > 0 && botBuyTimes[from] + ANTI_BOT_LOCK_DURATION > block.timestamp ) {
            revert ("Bot locked");
        }
    }

    function _preCheck(address from, address to, uint256 amount) internal view returns (uint256 fromBalance){
        fromBalance = _balances[from];
        // check sender balance
        if(fromBalance < amount) revert ERC20InsufficientBalance(from, fromBalance, amount);

        // check if buy or sell too much per tx
        if(limitIsInEffect() && maxAmountPerTx > 0 &&
            (
                (isLiquidityPool(from) && !isUnlimited(to)) || // buy
                (isLiquidityPool(to) && !isUnlimited(from))    // sell
            )
        ) {
            uint256 limit = maxAmountPerTx + LIMIT_ROUND_DEC; 
            require(amount < limit, "Max token per tx") ;
        }

    }

    function _postCheck(address from, address to, uint256 amount) internal view returns (uint256 toBalance){
        // check if buyer have too much token
        toBalance = _balances[to] + amount;
        if(limitIsInEffect() && maxAmountPerAccount > 0 &&
            ((isLiquidityPool(from) && !isUnlimited(to))) // buy
        ) {
            uint256 limit = maxAmountPerAccount + LIMIT_ROUND_DEC;
            require(toBalance < limit, "Max token per account") ; 
        }
    }

    function limitIsInEffect() internal view  returns (bool) {
        return limitEnabled;
    }
    function isUnlimited(address addr) internal view returns (bool) {
        return unlimiteds[addr];
    }

    function isLiquidityPool(address addr) internal view returns (bool) {
        return liquidityPools[addr];
    }

    function _addETHLiquidity(uint256 ethAmount, uint256 tokenAmount) internal {
        _approve(address(this), address(uniswapV2Router), tokenAmount);
        uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // accept any amount of ETH
            0, // accept any amount of token
            address(this),
            block.timestamp
        );
    }

    function _taxApply(address from, address to, uint256 amount) internal returns (uint256 taxAmount){
        // only apply tax if buy and sell
        uint256 taxPercent = 0;
        if(isLiquidityPool(from)) {
            taxPercent = buyTaxPercent;
        } else if(isLiquidityPool(to)) {
            taxPercent = sellTaxPercent;
        }
        if (
            taxPercent == 0
            || excludeFromTaxes[from] || excludeFromTaxes[to]
        ) {
            return 0;
        }

        taxAmount = amount * taxPercent / 100_00;
        if(taxAmount > 0) {
            _recordTax(taxAmount);
            _balances[address(this)] += taxAmount;
            emit Transfer(from, address(this), taxAmount);
        }
        return taxAmount;
    }

    function _recordTax(uint256 taxAmount) internal {
        uint256 communityTaxAmount = taxAmount * communityPercent / 100_00;
        uint256 devAmount = taxAmount - communityTaxAmount;
        devTaxTokenAmountAvailable += devAmount;
        communityTaxTokenAmountAvailable += communityTaxAmount;
    }

    function _unlockTokenForDev(address from, address to, uint256 amount) internal {
        if(!isLiquidityPool(from) && !isLiquidityPool(to)) {
            return;
        }
        if(startPoolTime == 0) {
            return;
        }

        tradeVolume += amount;
        uint256 devRemainToken = devTokenAmountRemain;
        if(devRemainToken == 0) {
            return;
        }

        // Target volume is 160 times of total supply
        uint256 targetVolume = 160*TOTAL_SUPPLY;
        uint256 unlockAmount = amount * DEV_SUPPLY / targetVolume;

        if(unlockAmount > devRemainToken) {
            unlockAmount = devRemainToken;
        }
        devTokenAmountClaimable += unlockAmount;
        devTokenAmountRemain = devRemainToken - unlockAmount;
    }

    function initPool(uint256 ethAmount, uint256 tokenAmount) onlyOwner external {
        require(startPoolTime == 0, "Pool already initialized");
        _addETHLiquidity(ethAmount, tokenAmount);
        startPoolTime = block.timestamp;
    }

    function addLiquidity(uint256 ethAmount, uint256 tokenAmount) onlyOwner external {
        require(startPoolTime > 0, "Pool not initialized");
        _addETHLiquidity(ethAmount, tokenAmount);
    }

    function claimCommunityTax() external returns (uint256 amount) {
        amount = communityTaxTokenAmountAvailable;
        require(amount > 0, "No community tax available");
        require(msg.sender == communityAddress, "Invalid sender");

        _transfer(address(this), msg.sender, amount);
        communityTaxTokenAmountAvailable = 0;
    }

    // Everyone can call this function to claim dev tax
    function claimDevTax() external returns (uint256 amount) {
        amount = devTaxTokenAmountAvailable;
        require(amount > 0, "No dev tax available");

        _transfer(address(this), devTaxReceiverAddress, amount);
        devTaxTokenAmountAvailable = 0;
    }

    function claimDevToken() external returns (uint256 amount) {
        amount = devTokenAmountClaimable;
        require(amount > 0, "No dev token available");

        _transfer(address(this), devTokenReceiverAddress, amount);
        devTokenAmountClaimable = 0;
    }
    function setExcludeFromTax(address account, bool exclude) external onlyOwner {
        _setExcludeFromTax(account, exclude);
    }
    function _setExcludeFromTax(address account, bool exclude) internal {
        excludeFromTaxes[account] = exclude;
    }

    function setCommunityAddress(address community) external onlyOwner {
        _setExcludeFromTax(communityAddress, false);
        _setUnlimited(communityAddress, false);

        communityAddress = community;

        _setExcludeFromTax(community, true);
        _setUnlimited(community, true);
    }

    function setDevAddress(address devTaxReceiver, address devTokenReceiver) external onlyOwner {
        _setExcludeFromTax(devTaxReceiverAddress, false);
        _setUnlimited(devTaxReceiverAddress, false);
        _setExcludeFromTax(devTokenReceiverAddress, false);
        _setUnlimited(devTokenReceiverAddress, false);

        devTaxReceiverAddress = devTaxReceiver;
        devTokenReceiverAddress = devTokenReceiver;

        _setExcludeFromTax(devTaxReceiver, true);
        _setExcludeFromTax(devTokenReceiver, true);
        _setUnlimited(devTaxReceiver, true);
        _setUnlimited(devTokenReceiver, true);
    }

    function setLiquidityPool(address pool, bool isPool) external onlyOwner {
        liquidityPools[pool] = isPool;
        emit SetLiquidityPool(pool, isPool);
    }

    function setUnlimited(address addr, bool _isUnlimited) external onlyOwner {
        _setUnlimited(addr, _isUnlimited);
    }

    function _setUnlimited(address addr, bool _isUnlimited) internal {
        unlimiteds[addr] = _isUnlimited;
        emit SetUnlimited(addr, _isUnlimited);
    }

    function changeTaxPercent(uint256 buyTax, uint256 sellTax, uint256 dev, uint256 community) external onlyOwner {
        if(buyTax > 5_00 || sellTax > 5_00) revert ("Too high tax");
        require(dev + community == 100_00, "Invalid percent");
        buyTaxPercent = buyTax;
        sellTaxPercent = sellTax;

        devPercent = dev;
        communityPercent = community;
    }

    function setLimitConfig(uint256 _maxAmountPerTx, uint256 _maxAmountPerAccount) external onlyOwner {
        maxAmountPerTx = _maxAmountPerTx;
        maxAmountPerAccount = _maxAmountPerAccount;
    }

    function setLimitEnabled(bool enabled) external onlyOwner {
        limitEnabled = enabled;
    }

    function rescueToken(address tokenAddress, address to, uint256 amount) external onlyOwner {
        if(tokenAddress == address(this)) {
            require(startPoolTime + 365 days < block.timestamp, "Cannot rescue this token");
        }

        SafeERC20.safeTransfer(ERC20(tokenAddress), to, amount);
    }

    function rescueETH(uint256 amount) external onlyOwner returns (bool success) {
        return payable(msg.sender).send(amount);
    }

    function claimGasFee(address recipient) external onlyOwner {
        uint256 amount = blastGasModeContract.claimMaxGas(address(this), recipient);
        emit ClaimGasFee(recipient, amount);
    }

    function configBlastPointsOperator(address blastPointAddress, address operator) external onlyOwner {
        IBlastPoints(blastPointAddress).configurePointsOperator(operator);
    }

    receive() external payable {}
}