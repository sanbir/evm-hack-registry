// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IMarketplaceSmall {
    function getNftSaleValueForAccountInUsdDecimal(address _wallet) external view returns (uint256);
}

contract InternalSwap is Ownable {
    uint256 public constant SECONDS_PER_DAY = 86400;

    uint256 private usdtAmount = 1000000;
    uint256 private tokenAmount = 223914;
    address public currency;
    address public tokenAddress;
    address public marketContract;
    uint8 private typeSwap = 2; //0: all, 1: usdt -> token only, 2: token -> usdt only
    bool public onlyBuyerCanSwap = true;

    uint256 private limitDay = 1;
    uint256 private limitValue = 150;
    uint256 private _taxSellFee = 500;
    uint256 private _taxBuyFee = 500;
    address private _taxAddress = 0x490aAab021A3354AfcBA4A8DfB8cC3ffC24Beb32;

    mapping(address => bool) private _addressBuyExcludeTaxFee;
    mapping(address => bool) private _addressSellExcludeHasTaxFee;
    mapping(address => bool) public swapWhiteList;

    // wallet -> date buy -> total amount
    mapping(address => mapping(uint256 => uint256)) private _sellAmounts;

    address private contractOwner;
    uint256 private unlocked = 1;

    event ChangeRate(uint256 _usdtAmount, uint256 _tokenAmount, uint256 _time);

    constructor(address _stableToken, address _tokenAddress) {
        currency = _stableToken;
        tokenAddress = _tokenAddress;
        contractOwner = _msgSender();
    }

    modifier checkOwner() {
        require(owner() == _msgSender() || contractOwner == _msgSender(), "SWAP: CALLER IS NOT THE OWNER");
        _;
    }

    modifier canSwap() {
        require(!onlyBuyerCanSwap || swapWhiteList[msg.sender] || isBuyer(msg.sender), "SWAP: CALLER CAN NOT SWAP");
        _;
    }

    modifier lock() {
        require(unlocked == 1, "SWAP: LOCKED");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    function isBuyer(address _wallet) public view returns (bool) {
        require(marketContract != address(0), "SWAP: MARKETPLACE CONTRACT IS ZERO ADDRESS");
        return IMarketplaceSmall(marketContract).getNftSaleValueForAccountInUsdDecimal(_wallet) > 0;
    }

    function getLimitDay() external view returns (uint256) {
        return limitDay;
    }

    function getUsdtAmount() external view returns (uint256) {
        return usdtAmount;
    }

    function getTokenAmount() external view returns (uint256) {
        return tokenAmount;
    }

    function getLimitValue() external view returns (uint256) {
        return limitValue;
    }

    function getTaxSellFee() external view returns (uint256) {
        return _taxSellFee;
    }

    function getTaxBuyFee() external view returns (uint256) {
        return _taxBuyFee;
    }

    function getTaxAddress() external view returns (address) {
        return _taxAddress;
    }

    function getTypeSwap() external view returns (uint8) {
        return typeSwap;
    }

    function setCurrency(address _currency) external checkOwner {
        currency = _currency;
    }

    function setTokenAddress(address _tokenAddress) external checkOwner {
        tokenAddress = _tokenAddress;
    }

    function setMarketContract(address _marketContract) external checkOwner {
        marketContract = _marketContract;
    }

    function setLimitDay(uint256 _limitDay) external checkOwner {
        limitDay = _limitDay;
    }

    function setLimitValue(uint256 _limitValue) external checkOwner {
        limitValue = _limitValue;
    }

    function setOnlyBuyerCanSwap(bool _onlyBuyerCanSwap) external checkOwner {
        onlyBuyerCanSwap = _onlyBuyerCanSwap;
    }

    function setSwapWhiteList(address _walletAddress, bool _isSwapWhiteList) external checkOwner {
        swapWhiteList[_walletAddress] = _isSwapWhiteList;
    }

    function setTaxSellFeePercent(uint256 taxFeeBps) external checkOwner {
        _taxSellFee = taxFeeBps;
    }

    function setTaxBuyFeePercent(uint256 taxFeeBps) external checkOwner {
        _taxBuyFee = taxFeeBps;
    }

    function setTaxAddress(address taxAddress) external checkOwner {
        _taxAddress = taxAddress;
    }

    function setAddressBuyExcludeTaxFee(address account, bool excludeFee) external checkOwner {
        _addressBuyExcludeTaxFee[account] = excludeFee;
    }

    function setAddressSellExcludeTaxFee(address account, bool excludeFee) external checkOwner {
        _addressSellExcludeHasTaxFee[account] = excludeFee;
    }

    function setPriceData(uint256 _usdtAmount, uint256 _tokenAmount) external checkOwner {
        require(_usdtAmount > 0 && _tokenAmount > 0, "SWAP: INVALID DATA");
        usdtAmount = _usdtAmount;
        tokenAmount = _tokenAmount;
        emit ChangeRate(_usdtAmount, _tokenAmount, block.timestamp);
    }

    function setPriceType(uint8 _type) external checkOwner {
        require(_type <= 2, "SWAP: INVALID TYPE SWAP (0, 1, 2)");
        typeSwap = _type;
    }

    function checkCanSellToken(address _wallet, uint256 _tokenValue) internal view returns (bool) {
        if (limitValue == 0 || limitDay == 0) {
            return true;
        }

        uint256 currentDate = block.timestamp / (limitDay * SECONDS_PER_DAY);
        uint256 valueAfterSell = _sellAmounts[_wallet][currentDate] + _tokenValue;
        uint256 maxValue = (limitValue * (10 ** ERC20(tokenAddress).decimals()) * tokenAmount) / usdtAmount;

        if (valueAfterSell > maxValue) {
            return false;
        }

        return true;
    }

    function buyToken(uint256 _usdtValue) external lock canSwap {
        require(typeSwap == 1 || typeSwap == 0, "SWAP: CANNOT BUY TOKEN NOW");
        require(_usdtValue > 0, "SWAP: INVALID VALUE");

        uint256 buyFee = 0;
        uint256 amountTokenDecimal = (_usdtValue * tokenAmount) / usdtAmount;
        if (_taxBuyFee != 0 && !_addressBuyExcludeTaxFee[msg.sender]) {
            buyFee = (amountTokenDecimal * _taxBuyFee) / 10000;
            amountTokenDecimal = amountTokenDecimal - buyFee;
        }

        if (amountTokenDecimal != 0) {
            require(ERC20(currency).balanceOf(msg.sender) >= _usdtValue, "SWAP: NOT ENOUGH BALANCE CURRENCY TO BUY");
            require(ERC20(currency).allowance(msg.sender, address(this)) >= _usdtValue, "SWAP: MUST APPROVE FIRST");
            require(ERC20(currency).transferFrom(msg.sender, address(this), _usdtValue), "SWAP: FAIL TO SWAP");

            require(ERC20(tokenAddress).transfer(msg.sender, amountTokenDecimal), "SWAP: FAIL TO SWAP");
            if (buyFee != 0) {
                require(ERC20(tokenAddress).transfer(_taxAddress, buyFee), "SWAP: FAIL TO SWAP");
            }
        }
    }

    function sellToken(uint256 _tokenValue) external lock canSwap {
        require(typeSwap == 2 || typeSwap == 0, "SWAP: CANNOT SELL TOKEN NOW");
        require(_tokenValue > 0, "SWAP: INVALID VALUE");
        require(checkCanSellToken(msg.sender, _tokenValue), "SWAP: MAXIMUM SWAP TODAY");

        uint256 sellFee = 0;
        if (_taxSellFee != 0 && !_addressSellExcludeHasTaxFee[msg.sender]) {
            sellFee = (_tokenValue * _taxSellFee) / 10000;
        }
        uint256 amountUsdtDecimal = ((_tokenValue - sellFee) * usdtAmount) / tokenAmount;

        if (amountUsdtDecimal != 0) {
            require(ERC20(tokenAddress).balanceOf(msg.sender) >= _tokenValue, "SWAP: NOT ENOUGH BALANCE TOKEN TO SELL");
            require(ERC20(tokenAddress).allowance(msg.sender, address(this)) >= _tokenValue, "SWAP: MUST APPROVE FIRST");
            require(ERC20(tokenAddress).transferFrom(msg.sender, address(this), _tokenValue), "SWAP: FAIL TO SWAP");
            require(ERC20(currency).transfer(msg.sender, amountUsdtDecimal), "SWAP: FAIL TO SWAP");

            if (sellFee != 0) {
                require(ERC20(tokenAddress).transfer(_taxAddress, sellFee), "SWAP: FAIL TO SWAP");
            }

            if (limitDay > 0) {
                uint256 currentDate = block.timestamp / (limitDay * SECONDS_PER_DAY);
                _sellAmounts[msg.sender][currentDate] = _sellAmounts[msg.sender][currentDate] + _tokenValue;
            }
        }
    }

    function setContractOwner(address _newContractOwner) external checkOwner {
        contractOwner = _newContractOwner;
    }

    function recoverBNB(uint256 _amount) public checkOwner {
        require(_amount > 0, "INVALID AMOUNT");
        address payable recipient = payable(msg.sender);
        recipient.transfer(_amount);
    }

    function withdrawTokenEmergency(address _token, uint256 _amount) public checkOwner {
        require(_amount > 0, "INVALID AMOUNT");
        require(IERC20(_token).transfer(msg.sender, _amount), "CANNOT WITHDRAW TOKEN");
    }
}
