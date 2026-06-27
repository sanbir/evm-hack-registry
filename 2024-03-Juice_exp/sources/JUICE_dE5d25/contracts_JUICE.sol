pragma solidity ^0.8.9;

// SPDX-License-Identifier: MIT

//website: juicebot.app

//twitter: https://twitter.com/juicebotapp

//tg: https://t.me/JuiceBotApp

import "./ERC20.sol";
import "./Ownable.sol";


contract JUICE is ERC20, Ownable {
    
    uint256 constant private startingSupply = 10_000_000;
    uint256 constant private _tTotal = startingSupply * 10 **18;
    constructor(address _router) ERC20("JUICE", "JUICE") {
        _mint(msg.sender, _tTotal);

        uniswapRouter = IUniswapV2Router02(_router); 

        isExcludedFromFee[address(this)] = true;
        isExcludedFromFee[msg.sender] = true;
    }

    function enableTrading() public onlyOwner {
        require(!isTradingEnabled, "JUICE: Trading is alredy enabled");
        require(pairsList.length > 0, "JUICE: Please add all the pairs first");
        isTradingEnabled = true;
        contractSwapEnabled = true;
        emit ContractSwapEnabledUpdated(true);
    }

    function excludeOrInclude(address user, bool value) public onlyOwner {
        require(isExcludedFromFee[user] != value, "JUICE: Already set as same value");
        isExcludedFromFee[user] = value;
    }

    function addOrRemovePairs(address pair, bool value) public onlyOwner {
        require(isPair[pair] != value, "JUICE: Already set as same value");
        isPair[pair] = value;
        pairsList.push(pair);
        if (lpPair == address(0)) {
            lpPair = pair;
        }
    }

    function setSwapSettings(uint256 thresholdPercent, uint256 thresholdDivisor, uint256 amountPercent, uint256 amountDivisor) external onlyOwner {
        swapThreshold = (_tTotal * thresholdPercent) / thresholdDivisor;
        swapAmount = (_tTotal * amountPercent) / amountDivisor;
        require(swapThreshold <= swapAmount, "Threshold cannot be above amount.");
        require(swapAmount <= (balanceOf(lpPair) * 20) / 1000, "Cannot be above 2% of current PI.");
        require(swapAmount >= _tTotal / 10_000_000, "Cannot be lower than 0.00001% of total supply.");
        require(swapThreshold >= _tTotal / 10_000_000, "Cannot be lower than 0.00001% of total supply.");
    }

    function setPriceImpactSwapAmount(uint256 priceImpactSwapPercent) external onlyOwner {
        require(priceImpactSwapPercent <= 100, "Cannot set above 1%.");
        piSwapPercent = priceImpactSwapPercent;
    }

    function setContractSwapEnabled(bool swapEnabled, bool priceImpactSwapEnabled) external onlyOwner {
        contractSwapEnabled = swapEnabled;
        piContractSwapsEnabled = priceImpactSwapEnabled;
        emit ContractSwapEnabledUpdated(swapEnabled);
    }

    function updateDevelopmentAddress(address payable development) public onlyOwner {
        require(_taxWallets.development != development, "JUICE: Already set as same address");
        _taxWallets.development = payable(development);
    }

    function updateFees(uint256 transfer, uint256 buy, uint256 sell) public onlyOwner {
        transferFee = transfer;
        buyFee = buy;
        sellFee = sell;
    }

    function transferEther() public onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
    
    // function to allow admin to transfer *any* ERC20 tokens from this contract..
    function transferAnyERC20Tokens(address tokenAddress, address recipient, uint256 amount) public onlyOwner {
        require(amount > 0, "JUICE: amount must be greater than 0");
        require(recipient != address(0), "JUICE: recipient is the zero address");
        IERC20(tokenAddress).transfer(recipient, amount);
    }

    receive() external payable { }
}
