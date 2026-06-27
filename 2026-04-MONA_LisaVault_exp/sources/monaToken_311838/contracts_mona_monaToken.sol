// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPancakeFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IPancakePair {
    function sync() external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
}

interface IPancakeRouter02 {
    function factory() external pure returns (address);
}

interface ImonaNodes {
    function addDividend(uint256 amount) external;
}

interface IburnAddressInterface {
    function sell(uint256 amount) external;
    function burn() external;
}

contract monaToken is ERC20, Ownable {
    address constant _ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant _USDT = 0x55d398326f99059fF775485246999027B3197955;

    uint256 constant PROFIT_NODE_RATE = 300;      
    uint256 constant PROFIT_CONSENSUS_RATE = 400; 
    uint256 constant PROFIT_ECOLOGY_RATE = 400;   
    uint256 constant PROFIT_LP_RATE = 400;       
    uint256 constant PROFIT_BURN_RATE = 300;      
    uint256 constant PROFIT_TOTAL_RATE = 1800; 

    uint256 public constant burnThreshold = 13000000 * 10 ** 18;

    uint256 public constant burnLimit = 18000000 * 10 ** 18;

    mapping(address => bool) public isExcludedFromTransfer;

    mapping(address => bool) public isBlacklisted;
    
    address public lpPairAddress;
    address public joinAddress;
    address public burnAddress;
    
    bool public isOpenTrade;

    mapping(address => uint40) public lastTradeTime;
    uint40 public constant COOLDOWN_TIME = 1 minutes;

    mapping(address => uint256) public userUsdtSpent;

    address public monaNodesAddress;
    address public consensusUniversityAddress;
    address public ecologyAddress;
    address public lpRewardAddress;

    event ExcludedFromTransfer(address indexed wallet, bool indexed excluded);
    event Blacklisted(address indexed wallet, bool indexed blacklisted);
    event extracTransfer(address indexed from, address indexed to, uint256 amount);

    constructor() ERC20("MONA", "MONA") Ownable(msg.sender) {
        isExcludedFromTransfer[msg.sender] = true;
        uint256 totalSupply = 21000000 * 10 ** decimals();
        _mint(msg.sender, totalSupply);

        _approve(address(this), _ROUTER, type(uint256).max);
        IERC20(_USDT).approve(_ROUTER, type(uint256).max);

        IPancakeFactory factory = IPancakeFactory(IPancakeRouter02(_ROUTER).factory());
        lpPairAddress = factory.createPair(address(this), _USDT);
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function setExcludedFromTransfer(address _wallet, bool _isExcluded) external onlyOwner {
        isExcludedFromTransfer[_wallet] = _isExcluded;
        emit ExcludedFromTransfer(_wallet, _isExcluded);
    }

    function setBlacklisted(address _wallet, bool _isBlacklisted) external onlyOwner {
        isBlacklisted[_wallet] = _isBlacklisted;
        emit Blacklisted(_wallet, _isBlacklisted);
    }

    function setMonaNodesAddress(address _newWallet) external onlyOwner {
        require(_newWallet != address(0), "monaNodes");
        monaNodesAddress = _newWallet;
    }

    function setConsensusUniversityAddress(address _newWallet) external onlyOwner {
        require(_newWallet != address(0), "consensusUniversity");
        consensusUniversityAddress = _newWallet;
    }

    function setEcologyAddress(address _newWallet) external onlyOwner {
        require(_newWallet != address(0), "ecology");
        ecologyAddress = _newWallet;
    }

    function setLpRewardAddress(address _newWallet) external onlyOwner {
        require(_newWallet != address(0), "lpReward");
        lpRewardAddress = _newWallet;
    }

    function setJoinAddress(address _newWallet) external onlyOwner {
        require(_newWallet != address(0), "join");
        joinAddress = _newWallet;
        isExcludedFromTransfer[joinAddress] = true;
    }

    function setBurnAddress(address _newWallet) external onlyOwner {
        require(_newWallet != address(0), "burn");
        burnAddress = _newWallet;
    }

    function openTrade() external onlyOwner {
        require(!isOpenTrade, "openTrade");
        isOpenTrade = true;
    }
    
    function closeTrade() external onlyOwner {
        require(isOpenTrade, "closeTrade");
        isOpenTrade = false;
    }

    function _update(address from, address to, uint256 amount) internal override {

        require(!isBlacklisted[from] && !isBlacklisted[to], "Blacklisted");
        if (isExcludedFromTransfer[from] || isExcludedFromTransfer[to]) {
            super._update(from, to, amount);
            return;
        }
        
        if (from == lpPairAddress) {
            _handleBuy(from, to, amount);
        } else if (to == lpPairAddress) {
            _handleSell(from, to, amount);
        }else {
            super._update(from, to, amount);
            IburnAddressInterface(burnAddress).burn();
        }
    }

    function _handleBuy(address from, address to, uint256 amount) private {
        require(isOpenTrade, "Not open");
        uint256 currentBurned = balanceOf(address(0xdead));
        require(currentBurned >= burnThreshold, "Not enough burned");
        (uint256 monaReserve, uint256 usdtReserve, ) = _getPairReserves();
        require(amount <= monaReserve / 33, "Amount exceeds limit");
        uint256 amountUBuy = getAmountIn(amount, usdtReserve, monaReserve);
        userUsdtSpent[to] += amountUBuy;
        require(monaNodesAddress != address(0), "monaNodes");
        uint256 nodeFee = amount * 100 / 10000;
        super._update(from, monaNodesAddress, nodeFee);
        ImonaNodes(monaNodesAddress).addDividend(nodeFee);
        require(consensusUniversityAddress != address(0), "consensusUniversity");
        uint256 consensusFee = amount * 100 / 10000;
        super._update(from, consensusUniversityAddress, consensusFee);
        uint256 burnFee = amount * 100 / 10000;
        uint256 remainingBurn = _calculateBurn(currentBurned, burnFee);
        if(remainingBurn > 0) {
            super._update(from, address(0xdead), remainingBurn);
        }
        
        uint256 fee = nodeFee + consensusFee + remainingBurn;
        super._update(from, to, amount - fee);
        _updateLastTradeTime(to);
    }

    function _handleSell(address from, address to, uint256 amount) private {
        require(isOpenTrade, "Not open");
        require(block.timestamp - lastTradeTime[from] >= COOLDOWN_TIME, "Cooldown");

        uint256 currentBurned = balanceOf(address(0xdead));

        require(monaNodesAddress != address(0), "monaNodes");
        uint256 nodeFee = amount * 200 / 10000;
        super._update(from, monaNodesAddress, nodeFee);
        ImonaNodes(monaNodesAddress).addDividend(nodeFee);
        require(ecologyAddress != address(0), "ecology");
        uint256 ecologyFee = amount * 200 / 10000;
        super._update(from, ecologyAddress, ecologyFee);
        uint256 burnFee = amount * 200 / 10000;
        uint256 remainingBurn = _calculateBurn(currentBurned, burnFee);
        if(remainingBurn > 0) {
            super._update(from, address(0xdead), remainingBurn);
        }
        uint256 remainingMona = amount - nodeFee - ecologyFee - remainingBurn;
        (uint256 monaReserve, uint256 usdtReserve, ) = _getPairReserves();
        uint256 amountUSDT = getAmountOut(remainingMona, monaReserve, usdtReserve);
        uint256 monaDeduction = _handleProfitDeduction(from, amountUSDT, monaReserve, usdtReserve);
        uint256 monaTransfer = remainingMona - monaDeduction;
        super._update(from, to, monaTransfer);
        _updateLastTradeTime(from);
        IburnAddressInterface(burnAddress).sell(monaTransfer);
    }

    function _updateLastTradeTime(address _add) private {
        lastTradeTime[_add] = uint40(block.timestamp);
    }

    function _calculateBurn(uint256 burned, uint256 burnFee) internal pure returns (uint256) {
        if (burned >= burnLimit) return 0;

        uint256 remaining = burnLimit - burned;

        if (burnFee <= remaining) {
            return burnFee;
        }

        return remaining;
    }

    function _distributeProfitFees(
        address seller,
        uint256 nodeFee,
        uint256 consensusFee,
        uint256 ecologyFee,
        uint256 lpFee,
        uint256 burnFee
    ) internal {
        if (nodeFee > 0) {
            super._update(seller, monaNodesAddress, nodeFee);
            ImonaNodes(monaNodesAddress).addDividend(nodeFee);
        }
        if (consensusFee > 0) {
            super._update(seller, consensusUniversityAddress, consensusFee);
        }
        if (ecologyFee > 0) {
            super._update(seller, ecologyAddress, ecologyFee);
        }
        if (lpFee > 0) {
            super._update(seller, lpRewardAddress, lpFee);
        }
        if (burnFee > 0) {
            super._update(seller, address(0xdead), burnFee);
        }
    }

    function _handleProfitDeduction(
        address seller,
        uint256 sellAmountUSDT,
        uint256 monaReserve,
        uint256 usdtReserve
    ) internal returns (uint256) {
        if (userUsdtSpent[seller] >= sellAmountUSDT) {
            userUsdtSpent[seller] -= sellAmountUSDT;
            return 0;
        }

        uint256 profitUSDT = sellAmountUSDT - userUsdtSpent[seller];
        userUsdtSpent[seller] = 0;
        
        uint256 totalFeeMONA = getAmountOut(profitUSDT * PROFIT_TOTAL_RATE / 10000, usdtReserve, monaReserve);
        
        uint256[5] memory fees;
        fees[0] = totalFeeMONA * PROFIT_NODE_RATE / PROFIT_TOTAL_RATE;      // 节点
        fees[1] = totalFeeMONA * PROFIT_CONSENSUS_RATE / PROFIT_TOTAL_RATE; // 共识
        fees[2] = totalFeeMONA * PROFIT_ECOLOGY_RATE / PROFIT_TOTAL_RATE;   // 生态
        fees[3] = totalFeeMONA * PROFIT_LP_RATE / PROFIT_TOTAL_RATE;        // LP
        fees[4] = totalFeeMONA * PROFIT_BURN_RATE / PROFIT_TOTAL_RATE;      // 销毁

        uint256 currentBurned = balanceOf(address(0xdead));
        if (currentBurned + fees[4] > burnLimit) {
            fees[4] = currentBurned < burnLimit ? burnLimit - currentBurned : 0;
        }

        _distributeProfitFees(seller, fees[0], fees[1], fees[2], fees[3], fees[4]);

        return fees[0] + fees[1] + fees[2] + fees[3] + fees[4];
    }

    function burnsellMona(uint256 amount) external {
        require(amount > 0, "Must be greater than 0");
        require(msg.sender == burnAddress || msg.sender == joinAddress, "Only burnAddress or joinAddress");
        uint256 currentBurned = balanceOf(address(0xdead));
        if(currentBurned >= burnLimit) {
            return;
        }
        super._update(lpPairAddress, address(0xdead), amount);

        IPancakePair(lpPairAddress).sync();
        emit extracTransfer(lpPairAddress, address(0xdead), amount);
    }


    function extractMona(uint256 amount) external {
        require(amount > 0, "Must be greater than 0");
        require(msg.sender == joinAddress, "Only join");
    
        super._update(lpPairAddress, joinAddress, amount);

        IPancakePair(lpPairAddress).sync();
        emit extracTransfer(lpPairAddress, joinAddress, amount);
    }

    function _getPairReserves()
        internal
        view
        returns (
            uint256 monaReserve,
            uint256 usdtReserve,
            uint32 blockTimestampLast
        )
    {
        require(lpPairAddress != address(0), "Pair not created");
        (uint112 r0, uint112 r1, uint32 ts) = IPancakePair(lpPairAddress)
            .getReserves();
        address token0 = IPancakePair(lpPairAddress).token0();
        (monaReserve, usdtReserve) = (token0 == address(this))
            ? (uint256(r0), uint256(r1))
            : (uint256(r1), uint256(r0));
        blockTimestampLast = ts;
    }

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut 
    ) internal pure returns (uint256 amountOut) {
        uint256 amountInWithFee = amountIn * 9975;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 10000) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function getAmountIn(
        uint256 amountOut, 
        uint256 reserveIn, 
        uint256 reserveOut 
    ) internal pure returns (uint256 amountIn) { 
        uint256 numerator = reserveIn * amountOut * 10000;
        uint256 denominator = (reserveOut - amountOut) * 9975;
        amountIn = (numerator + denominator - 1) / denominator;
    }

}