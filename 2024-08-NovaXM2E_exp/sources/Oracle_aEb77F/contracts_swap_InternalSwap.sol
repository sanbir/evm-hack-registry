// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../token/NovaXERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../data/StructData.sol";

contract InternalSwap is Ownable {
    using SafeMath for uint256;
    uint256 private usdtAmount = 2432000;
    uint256 private tokenAmount = 1000000;
    address public currency;
    address public tokenAddress;
    uint8 private typeSwap = 0; //0: all, 1: usdt -> token only, 2: token -> usdt only

    address private _taxAddress = 0x490aAab021A3354AfcBA4A8DfB8cC3ffC24Beb32;
    uint256 private _taxSellFee = 0;
    uint256 private _taxBuyFee = 0;
    uint8 private limitDay = 1;
    uint256 private limitValue = 0;
    mapping(address => bool) private _addressSellHasTaxFee;
    mapping(address => bool) private _addressBuyHasTaxFee;
    mapping(address => bool) private _addressBuyExcludeTaxFee;
    mapping(address => bool) private _addressSellExcludeHasTaxFee;
    mapping(address => StructData.ListSwapData) addressBuyTokenData;
    mapping(address => StructData.ListSwapData) addressSellTokenData;
    bool private reentrancyGuardForBuying = false;
    bool private reentrancyGuardForSelling = false;

    event ChangeRate(uint256 _usdtAmount, uint256 _tokenAmount, uint256 _time);
    constructor(address _stableToken, address _tokenAddress) {
        currency = _stableToken;
        tokenAddress = _tokenAddress;
    }

    function getLimitDay() external view returns (uint8) {
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

    function setLimitDay(uint8 _limitDay) external onlyOwner {
        limitDay = _limitDay;
    }

    function setLimitValue(uint256 _valueToLimit) external onlyOwner {
        limitValue = _valueToLimit;
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

    function setTaxSellFeePercent(uint256 taxFeeBps) external onlyOwner {
        _taxSellFee = taxFeeBps;
    }

    function setTaxBuyFeePercent(uint256 taxFeeBps) external onlyOwner {
        _taxBuyFee = taxFeeBps;
    }

    function setTaxAddress(address taxAddress_) external onlyOwner {
        _taxAddress = taxAddress_;
    }

    function setAddressSellHasTaxFee(address account, bool hasFee) external onlyOwner {
        _addressSellHasTaxFee[account] = hasFee;
    }

    function isAddressSellHasTaxFee(address account) external view returns (bool) {
        return _addressSellHasTaxFee[account];
    }

    function setAddressBuyHasTaxFee(address account, bool hasFee) external onlyOwner {
        _addressBuyHasTaxFee[account] = hasFee;
    }

    function isAddressBuyHasTaxFee(address account) external view returns (bool) {
        return _addressBuyHasTaxFee[account];
    }

    function setAddressBuyExcludeTaxFee(address account, bool hasFee) external onlyOwner {
        _addressBuyExcludeTaxFee[account] = hasFee;
    }

    function setAddressSellExcludeTaxFee(address account, bool hasFee) external onlyOwner {
        _addressSellExcludeHasTaxFee[account] = hasFee;
    }

    function calculateSellTaxFee(uint256 _amount) private view returns (uint256) {
        return _amount.mul(_taxSellFee).div(10000);
    }

    function calculateBuyTaxFee(uint256 _amount) private view returns (uint256) {
        return _amount.mul(_taxBuyFee).div(10000);
    }

    function setPriceData(uint256 _usdtAmount, uint256 _tokenAmount) external onlyOwner {
        usdtAmount = _usdtAmount;
        tokenAmount = _tokenAmount;
        emit ChangeRate(_usdtAmount, _tokenAmount, block.timestamp);
    }

    function getTypeSwap() external view returns (uint8) {
        return typeSwap;
    }

    function setPriceType(uint8 _type) external onlyOwner {
        require(
           _type <= 2,
            "SWAP: INVALID TYPE SWAP (0, 1, 2)"
        );
        typeSwap = _type;
    }

    function updateBuyTokenData(address _wallet, uint256 _value, uint256 _time) internal {
        StructData.InfoSwapData memory item;
        item.timeSwap = _time;
        item.valueSwap = _value;
        addressBuyTokenData[_wallet].childList.push(item);
    }

    function updateSellTokenData(address _wallet, uint256 _value, uint256 _time) internal {
        StructData.InfoSwapData memory item;
        item.timeSwap = _time;
        item.valueSwap = _value;
        addressSellTokenData[_wallet].childList.push(item);
    }

    function checkCanSellToken(address _wallet, uint256 _value) internal view returns (bool) {
        if (limitValue == 0 || limitDay == 0) {
            return true;
        }
        StructData.InfoSwapData[] memory listSellToken = addressSellTokenData[_wallet].childList;
        bool canSell = true;
        uint256 today = block.timestamp;
        uint256 maxValue = limitValue * (10 ** NovaXERC20(tokenAddress).decimals());
        uint256 timeCheck = block.timestamp - limitDay * 24 * 60 * 60;
        uint256 totalSellValue;
        for (uint i = 0; i < listSellToken.length; i++) {
            uint256 timeBuy = listSellToken[i].timeSwap;
            uint256 valueSwap = listSellToken[i].valueSwap;
            if (timeBuy >= timeCheck && timeBuy <= today) {
                totalSellValue = totalSellValue + valueSwap;
            }
        }
        uint256 valueAfterSell = totalSellValue + _value;
        if (valueAfterSell > maxValue) {
            canSell = false;
        }
        return canSell;
    }

    function buyToken(uint256 _values) external {
        require(
            typeSwap == 1 || typeSwap == 0,
            "SWAP: CANNOT BUY TOKEN NOW"
        );
        require(_values > 0, "SWAP: INVALID VALUE");
        require(!reentrancyGuardForBuying, "SWAP: REENTRANCY DETECTED");
        reentrancyGuardForBuying = true;
        uint256 amountTokenDecimal = 0;
        uint256 amountBuyFee = 0;
        bool _isExcludeUserBuy = _addressBuyExcludeTaxFee[msg.sender];
        uint256 usdtValue = _values;
        if (tokenAmount > 0 && usdtAmount > 0) {
            amountTokenDecimal = (usdtValue * tokenAmount) / usdtAmount;
            if (_taxBuyFee != 0 && !_isExcludeUserBuy) {
                amountBuyFee = calculateBuyTaxFee(amountTokenDecimal);
                amountTokenDecimal = amountTokenDecimal - amountBuyFee;
            }
        }
        if (amountTokenDecimal != 0) {
            require(
                NovaXERC20(currency).balanceOf(msg.sender) >= usdtValue,
                "SWAP: NOT ENOUGH BALANCE CURRENCY TO BUY TOKEN"
            );
            require(
                NovaXERC20(currency).allowance(msg.sender, address(this)) >= usdtValue,
                "SWAP: MUST APPROVE FIRST"
            );
            require(
                NovaXERC20(currency).transferFrom(
                    msg.sender,
                    address(this),
                    usdtValue
                ),
                "SWAP: FAIL TO SWAP"
            );
            require(
                NovaXERC20(tokenAddress).transfer(
                    msg.sender,
                    amountTokenDecimal
                ),
                "SWAP: FAIL TO SWAP"
            );
            if (amountBuyFee != 0) {
                require(
                    NovaXERC20(tokenAddress).transfer(
                        _taxAddress,
                        amountBuyFee
                    ),
                    "SWAP: FAIL TO SWAP"
                );
            }
            updateBuyTokenData(msg.sender, amountTokenDecimal, block.timestamp);
        }
        reentrancyGuardForBuying = false;
    }

    function sellToken(uint256 _values) external {
        require(
            typeSwap == 2 || typeSwap == 0,
            "SWAP: CANNOT SELL TOKEN NOW"
        );
        require(_values > 0, "SWAP: INVALID VALUE");
        require(!reentrancyGuardForSelling, "SWAP: REENTRANCY DETECTED");
        reentrancyGuardForSelling = true;
        uint256 amountUsdtDecimal = 0;
        uint256 amountSellFee = 0;
        uint256 tokenValue = _values;
        bool checkUserCanSellToken = checkCanSellToken(msg.sender, tokenValue);
        require(checkUserCanSellToken, "SWAP: MAXIMUM SWAP TODAY");
        uint256 realTokenValue = tokenValue;
        bool _isExcludeUserBuy = _addressBuyExcludeTaxFee[msg.sender];
        if (_taxSellFee != 0 && !_isExcludeUserBuy) {
            amountSellFee = calculateSellTaxFee(tokenValue);
            realTokenValue = realTokenValue - amountSellFee;
        }
        if (tokenAmount > 0 && usdtAmount > 0) {
            amountUsdtDecimal = (realTokenValue * usdtAmount) / tokenAmount;
        }
        if (amountUsdtDecimal != 0) {
            require(
                NovaXERC20(tokenAddress).balanceOf(msg.sender) >= tokenValue,
                "SWAP: NOT ENOUGH BALANCE TOKEN TO SELL"
            );
            require(
                NovaXERC20(tokenAddress).allowance(msg.sender, address(this)) >= tokenValue,
                "SWAP: MUST APPROVE FIRST"
            );
            require(
                NovaXERC20(tokenAddress).transferFrom(
                    msg.sender,
                    address(this),
                    tokenValue
                ),
                "SWAP: FAIL TO SWAP"
            );
            if (amountSellFee != 0) {
                require(
                    NovaXERC20(tokenAddress).transfer(
                        _taxAddress,
                        amountSellFee
                    ),
                    "SWAP: FAIL TO SWAP"
                );
            }
            require(
                NovaXERC20(currency).transfer(
                    msg.sender,
                    amountUsdtDecimal
                ),
                "SWAP: FAIL TO SWAP"
            );
            updateSellTokenData(msg.sender, tokenValue, block.timestamp);
        }
        reentrancyGuardForSelling = false;
    }
    /**
        * @dev Recover lost bnb and send it to the contract owner
     */
    function recoverLostBNB() public onlyOwner {
        address payable recipient = payable(msg.sender);
        recipient.transfer(address(this).balance);
    }

    /**
        * @dev withdraw some token balance from contract to owner account
     */
    function withdrawTokenEmergency(address _token, uint256 _amount) public onlyOwner {
        require(_amount > 0, "INVALID AMOUNT");
        require(IERC20(_token).transfer(msg.sender, _amount), "CANNOT WITHDRAW TOKEN");
    }
}
