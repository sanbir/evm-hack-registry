// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ITrigger} from "./interface/ITrigger.sol";
import {IERC314} from "./interface/IERC314.sol";
import {Math} from "./library/Helper.sol";
import {IERC20Receiver} from "./interface/IERC20Receiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract WMRP is ERC20, ITrigger, IERC314, Ownable {

    address public mrpContract;

    uint256 public LPTotalSupply;

    uint256 public ETHLPReward;

    uint256 public addLiquidityEffectiveTime = 20 minutes;

    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;

    uint256 public MRPPrice;

    uint256 public tradingStartTime;

    address public offLPTriggerAddress = address(0xdead);

    uint256 public addLPMinMRPAmount = 100 ether;

    uint256 public buyFee = 7;

    uint256 public sellFee = 3;

    uint256 public newestDividends;

    address public liquidityProvider;

    uint256 public blockToUnlockLiquidity;

    struct LPAccount {
        bool isAddLiquidity;
        uint256 endTime;
        uint256 liquidity;
        uint256 dividends;
        uint256 claimETH;
    }

    mapping(address account => LPAccount) public lpAccount;


    error OnlyMRPContract();

    error OnlyLiquidityProviderError();

    error InsufficientLiquidity();

    error InsufficientAmount();

    error InsufficientLiquidityBurned();

    error EthTransferFailed();

    event Deposit(address indexed account, uint256 amount);

    event Withdrawal(address indexed account, uint256 amount);

    event MintLP(address indexed account, uint256 liquidity);

    event BurnLP(address indexed account, uint256 liquidity);

    event OpenLiquidityTrigger(address indexed account, uint256 indexed endtime);

    event OffLiquidityTrigger(address indexed account);

    event ClaimDividends(address indexed account, uint256 indexed ethAmount, uint256 indexed dividends);

    event DividendsUpdate(
        uint256 indexed dividends,
        uint256 indexed newestDividends
    );


    constructor(address _mrpContract) ERC20("Wrapped MRP", "WMRP") Ownable(_msgSender()) {
        blockToUnlockLiquidity = block.number + 36500 days;
        liquidityProvider = _msgSender();
        setMRPContract(_mrpContract);
    }

    modifier onlyMRPContract() {
        if (_msgSender() != mrpContract) revert OnlyMRPContract();
        _;
    }

    modifier onlyLiquidityProvider() {
        if (_msgSender() != liquidityProvider) revert OnlyLiquidityProviderError();
        _;
    }

    function setMRPPriceAndStartTime(uint256 price, uint256 time) public onlyLiquidityProvider {
        if (LPTotalSupply == 0) {
            MRPPrice = price;
            tradingStartTime = time;
        }
    }

    function handle(address account, uint256 amount) public override onlyMRPContract returns (bool){
        if(amount == 0){
            _openLiquidityTrigger(account);
        }else{
            _deposit(account, amount);
            if(!getAddLiquidityTrigger(account) && tradingStartTime <= block.timestamp){
                _sell(account,amount);
            }
        }
        return true;
    }

    function setMRPContract(address mrpContract_) public onlyOwner {
        mrpContract = mrpContract_;
    }

    function _deposit(address account, uint256 amount) internal {
        emit Deposit(account, amount);
        _mint(account, amount);
    }

    function _withdraw(address account, uint256 amount) internal {
        _burn(account, amount);
        emit Withdrawal(account, amount);
        IERC20(mrpContract).transfer(account, amount);
    }

    function _buy() internal {
        require(LPTotalSupply > 0 , "No Liquidity");
        uint256 ethAmount = msg.value;
        require(ethAmount >= (1 ether / 10), "Minimum purchase amount is 0.1 ether");
        uint256 buyFeeAmount = ethAmount * buyFee / 100;
        uint256 buyETHAmount = ethAmount - buyFeeAmount;
        ETHLPReward += buyFeeAmount;
        uint256 ethContractAmount = getContractEthAmount();
        uint256 balanceOfThis = balanceOf(address(this));
        uint256 buyAmount = buyETHAmount * balanceOfThis / ethContractAmount;
        emit Swap(_msgSender(), buyETHAmount, 0, 0, buyAmount);
        _addDividends(buyFeeAmount);
        _transfer(address(this), _msgSender(), buyAmount);
        _withdraw(_msgSender(),buyAmount);
    }

    function _sell(address account,uint256 sellMRPAmount) internal {
        require(sellMRPAmount >= 1 ether, "Minimum purchase amount is 1 ether");
        require(tradingStartTime <= block.timestamp,"Trading Unopened");
        _transfer(account, address(this), sellMRPAmount);
        uint256 ethContractAmount = getContractEthAmount();
        uint256 balanceOfThis = balanceOf(address(this));
        uint256 ethAmount = sellMRPAmount * ethContractAmount / balanceOfThis;
        emit Swap(account, 0, sellMRPAmount, ethAmount, 0);
        uint256 sellFeeAmount = ethAmount * sellFee / 100;
        ETHLPReward += sellFeeAmount;
        _addDividends(sellFeeAmount);
        _safeEthTransfer(account, ethAmount - sellFeeAmount);
    }

    function _addLiquidity() internal {
        address account = _msgSender();
        uint256 payEth = msg.value;
        uint256 payMRP = balanceOf(account);
        uint256 amountETH = payEth;
        uint256 amountMRP = 0;
        if (LPTotalSupply == 0) {
            amountMRP = payEth * MRPPrice / 1e4;
            if (payMRP < amountMRP) {
                amountETH = payMRP * 1e4 / MRPPrice;
                amountMRP = payMRP;
            }
        } else {
//            amountETH = _getLPAmount(payMRP, false);
            amountMRP = _getLPAmount(payEth, true);
            if (payMRP < amountMRP) {
                amountETH = _getLPAmount(payMRP, false);
                amountMRP = payMRP;
            }
        }
        if (amountETH == 0 || amountMRP < addLPMinMRPAmount) revert InsufficientAmount();
        _transfer(account, address(this), amountMRP);
        if (amountETH < payEth) {
            uint256 backEth = payEth - amountETH;
            _safeEthTransfer(account, backEth);
        }
        if(amountMRP < payMRP){
            _withdraw(account, payMRP - amountMRP);
        }
        (uint256 ethAmount, uint256 tokenAmount) = getReserves();
        ethAmount -= amountETH;
        tokenAmount -= amountMRP;
        uint256 liquidity = 0;
        if (LPTotalSupply == 0) {
            liquidity = Math.sqrt(amountETH * amountMRP) - MINIMUM_LIQUIDITY;
        } else {
            liquidity = Math.min(amountETH * LPTotalSupply / ethAmount, amountMRP * LPTotalSupply / tokenAmount);
        }
        if (liquidity == 0) revert InsufficientLiquidity();
        _mintLP(account, liquidity);
        emit Swap(_msgSender(), amountETH, amountMRP, 0, 0);
    }

    function _removeLiquidity(address account) internal {
        uint256 liquidity = LPBalanceOf(account);
        (uint256 ethAmount, uint256 tokenAmount) = getReserves();
        uint256 amountETH = liquidity * ethAmount / LPTotalSupply;
        uint256 amountMRP = liquidity * tokenAmount / LPTotalSupply;
        if (amountETH == 0 || amountMRP == 0) revert InsufficientLiquidityBurned();
        _burnLP(account);
        _safeEthTransfer(account, amountETH);
        _transfer(address(this), account, amountMRP);
        _withdraw(account, amountMRP);
        if (LPTotalSupply == 0) {
            ETHLPReward = 0;
            uint256 eth = address(this).balance;
            if (eth > 0) {
                _safeEthTransfer(liquidityProvider, eth);
            }
        }
    }

    function removeLiquidity() public override {
        require(false, "Not Support");
    }

    function extendLiquidityLock(uint256 _blockToUnlockLiquidity) public {
        require(blockToUnlockLiquidity < _blockToUnlockLiquidity, "You can't shorten duration");
        blockToUnlockLiquidity = _blockToUnlockLiquidity;
    }

    function _safeEthTransfer(address to, uint256 ethAmount) internal {
        (bool success,) = to.call{value: ethAmount}("");
        if (!success) revert EthTransferFailed();
    }

    function LPBalanceOf(address account) public view returns (uint256) {
        return lpAccount[account].liquidity;
    }

    function _mintLP(address account, uint256 liquidity) internal {
        lpAccount[account].liquidity += liquidity;
        LPTotalSupply += liquidity;
        emit MintLP(account, liquidity);
    }

    function _burnLP(address account) internal {
        uint256 liquidity = lpAccount[account].liquidity;
        lpAccount[account].liquidity = 0;
        LPTotalSupply -= liquidity;
        emit BurnLP(account, liquidity);
    }

    function transfer(address to, uint256 value) public override returns (bool){
        address sender = _msgSender();
        _beforeTransfer(sender, to, value);
        if (to == address(this)) {
            if (value == 0) {
                _openLiquidityTrigger(sender);
            } else {
                _sell(sender,value);
            }
        } else if (to == offLPTriggerAddress) {
            _offAddLiquidityTrigger(sender);
        } else if (to == _msgSender()) {
            if (value == 0) {
                _removeLiquidity(sender);
            } else {
                _withdraw(sender, value);
            }
        } else {
            _transfer(sender, to, value);
            if (to.code.length > 0) {
                try IERC20Receiver(to).onTokenBridged(sender, value){}catch{}
            }
        }
        return true;
    }

    function _accountHandle(address account) internal{
        if(account.code.length == 0){
            _claimDividends(account);
            _offAddLiquidityTrigger(account);
        }
    }

    function _beforeTransfer(address from, address to, uint256 value) internal {
        _accountHandle(from);
        if(from != to){
            _accountHandle(to);
        }
    }

    function _openLiquidityTrigger(address account) internal
    {
        lpAccount[account].isAddLiquidity = true;
        lpAccount[account].endTime = block.timestamp + addLiquidityEffectiveTime;
        emit OpenLiquidityTrigger(account, lpAccount[account].endTime);
    }

    function _offAddLiquidityTrigger(address account) internal {
        if (lpAccount[account].isAddLiquidity) {
            lpAccount[account].isAddLiquidity = false;
            lpAccount[account].endTime = 0;
            emit OffLiquidityTrigger(account);
        }
    }

    function getAddLiquidityTrigger(address account) public view returns (bool) {
        bool isAddLiquidity = lpAccount[account].isAddLiquidity;
        if (lpAccount[account].endTime > block.timestamp && isAddLiquidity) return true;
        return false;
    }

    function getAmountOut(uint256 value, bool buy_) public override view returns (uint256 amount) {
        if (value == 0) {
            return value;
        }
        (uint256 ethAmount, uint256 tokenAmount) = getReserves();
        if (buy_) {
            amount = (value * tokenAmount) / (ethAmount + value);
        } else {
            amount = (value * ethAmount) / (tokenAmount + value);
        }
    }

    function _getLPAmount(uint256 value, bool isEth) internal view returns (uint256 amount) {
        (uint256 ethAmount, uint256 tokenAmount) = getReserves();
        ethAmount -= msg.value;
        if (isEth) {
            amount = value * tokenAmount / ethAmount;
        } else {
            amount = value * ethAmount / tokenAmount;
        }
    }

    function getLPAmount(uint256 value, bool isEth) public view returns (uint256 amount) {
        (uint256 ethAmount, uint256 tokenAmount) = getReserves();
        if (isEth) {
            amount = value * tokenAmount / ethAmount;
        } else {
            amount = value * ethAmount / tokenAmount;
        }
    }

    function getReserves() public override view returns (uint256 ethAmount, uint256 tokenAmount) {
        return (getContractEthAmount(), balanceOf(address(this)));
    }

    function getContractEthAmount() public view returns (uint256) {
        return address(this).balance - ETHLPReward;
    }

    receive() external payable {
        if (tradingStartTime >= block.timestamp || getAddLiquidityTrigger(_msgSender())) {
            _addLiquidity();
        } else {
            _buy();
        }
        _offAddLiquidityTrigger(_msgSender());
    }

    function _addDividends(uint256 amount) internal {
        if (amount <= 0) revert InsufficientAmount();
        uint256 dividendsAmount = amount * 1 ether / LPTotalSupply;
        newestDividends += dividendsAmount;
        emit DividendsUpdate(dividendsAmount, newestDividends);
    }

    function dividendsAccountBalanceOfETH(address account) public view returns (uint256) {
        uint256 liquidity = lpAccount[account].liquidity;
        if (liquidity == 0) return 0;
        uint256 accountDividends = newestDividends - lpAccount[account].dividends;
        return liquidity * accountDividends / 1 ether;
    }

    function _claimDividends(address account) internal {
        uint256 accountETHDividends = dividendsAccountBalanceOfETH(account);
        if (accountETHDividends > 0) {
            lpAccount[account].claimETH += accountETHDividends;
            lpAccount[account].dividends = newestDividends;
            emit ClaimDividends(account, accountETHDividends, newestDividends);
            _safeEthTransfer(account, accountETHDividends);
            ETHLPReward -= accountETHDividends;
        }
    }

}
