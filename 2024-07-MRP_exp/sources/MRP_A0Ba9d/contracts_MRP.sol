// SPDX-License-Identifier: UNLICENSED
// coder Mr Prices 518
pragma solidity ^0.8.0;

import {RaiseFunds} from "./RaiseFunds.sol";
import {IERC314} from "./interface/IERC314.sol";
import {IInvite} from "./interface/IInvite.sol";
import {ITrigger} from "./interface/ITrigger.sol";
import {IPledge} from "./interface/IPledge.sol";
import {I314Swap} from "./interface/I314Swap.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MRP is RaiseFunds, IERC314, I314Swap {

    bool public liquidityAdded;

    bool public tradingEnable;

    bool public withdrawRaiseFundsStatus;

    uint8 public officialFee = 5;

    uint8 public LevelDepth;

    address public liquidityProvider;

    address payable public officialAddress;

    address public pledgeAddress;

    IInvite public inviteAddress;

    address public deadAddress = address(0xdEaD);

    uint256 public blockToUnlockLiquidity;

    uint256 public tradingStartTime;

    uint256 public lastMinerRewards;

    uint256 public weeklyRankingRewards;

    uint256 public initEthAmount;

    uint256 public rewardGas;

    uint256 public levelAmount = 1 ether / 10;

    mapping(address => bool) public isTrigger;

    mapping(uint256 => address) public lastRewardFlag;

    mapping(uint256 => address) public weekRewardFlag;


    event Reward(
        address indexed account,
        address indexed parent,
        uint256 indexed amount
    );

    event LastMinerReward(
        address indexed account,
        uint256 indexed dayNum,
        uint256 indexed amount
    );
    event WeekMinerReward(
        address indexed account,
        uint256 indexed dayNum,
        uint256 indexed amount
    );

    constructor(
        address _officialAddress,
        address _pledgeAddress,
        address _inviteAddress
    ) RaiseFunds("Mint Raises Prices", "MRP")
    {
        liquidityProvider = _msgSender();
        blockToUnlockLiquidity = block.number + 3 days;
        tradingStartTime = 1716012000;
        setOfficialAddress(_officialAddress);
        setPledgeAddress(_pledgeAddress);
        setInviteAddress(_inviteAddress);
    }

    modifier onlyLiquidityProvider() {
        require(
            _msgSender() == liquidityProvider,
            "You are not the liquidity provider"
        );
        _;
    }

    function setPledgeAddress(address _pledgeAddress) public onlyLiquidityProvider
    {
        if (pledgeAddress != _pledgeAddress && _pledgeAddress.code.length > 0) {
            isTrigger[pledgeAddress] = false;
            pledgeAddress = _pledgeAddress;
            isTrigger[_pledgeAddress] = true;
        }
    }

    function setInviteAddress(address _inviteAddress) public onlyLiquidityProvider
    {
        if (address(inviteAddress) != _inviteAddress && _inviteAddress.code.length > 0) {
            inviteAddress = IInvite(_inviteAddress);
        }
    }

    function setOfficialAddress(address _officialAddress) public onlyLiquidityProvider
    {
        if (address(officialAddress) != _officialAddress) {
            officialAddress = payable(_officialAddress);
        }
    }

    function removeLiquidity() public override onlyLiquidityProvider {
        require(block.number > blockToUnlockLiquidity, "Liquidity locked");

        tradingEnable = false;

        payable(_msgSender()).transfer(address(this).balance);

        emit RemoveLiquidity(address(this).balance);
    }

    function extendLiquidityLock(
        uint256 _blockToUnlockLiquidity
    ) public override onlyLiquidityProvider {
        require(
            blockToUnlockLiquidity < _blockToUnlockLiquidity,
            "You can't shorten duration"
        );
        blockToUnlockLiquidity = _blockToUnlockLiquidity;
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

    function setTriggerAddress(address _triggerAddress, bool _isTrigger) public onlyLiquidityProvider {
        isTrigger[_triggerAddress] = _isTrigger;
    }

    function getReserves() public override view returns (uint256, uint256) {
        return (getContractEthAmount(), balanceOf(address(this)));
    }

    function _officialFeeHandle(uint256 value) internal returns (uint256)
    {
        uint256 officialFeeAmount = value * 5 / 100;
        if (officialFeeAmount > 0) {
            officialAddress.transfer(officialFeeAmount);
        }
        return officialFeeAmount;
    }

    function _buy() internal {
        require(tradingEnable, "Trading is not enabled");
        _dailyHandle();
        uint256 ethAmount = msg.value;
        require(ethAmount >= (1 ether / 10), "Minimum purchase amount is 0.1 ether");
        _addMiner(_msgSender(), ethAmount);
        uint256 _rewardAmount = ethAmount / 100;
        lastMinerRewards += _rewardAmount / 2;
        weeklyRankingRewards += _rewardAmount / 2;
        ethAmount -= _officialFeeHandle(ethAmount);
        ethAmount -= _rewardAmount;
        ethAmount -= _reward(_msgSender(), ethAmount);
        uint256 ethContractAmount = getContractEthAmount() - ethAmount;
        uint256 balanceOfThis = balanceOf(address(this));
        uint256 buyEthAmount = ethAmount * 4 / 10;
        uint256 buyAmount = buyEthAmount * balanceOfThis / ethContractAmount;
        uint256 rewardAmount = ethAmount * balanceOfThis / (ethContractAmount + ethAmount);
        emit Swap(_msgSender(), buyEthAmount, 0, 0, buyAmount);
        _mint(address(this), buyAmount / 2);
        buyEthAmount += (buyEthAmount / 2);
        buyAmount += (buyAmount / 2);
        emit Swap(_msgSender(), buyEthAmount, buyAmount, 0, 0);
        _feeHandle(rewardAmount);
    }

    function getContractEthAmount() public view returns (uint256)
    {
        return address(this).balance - lastMinerRewards - weeklyRankingRewards;
    }

    function balanceOf(address account) public override view returns (uint256)
    {
        if (block.timestamp < tradingStartTime) {
            return getRaiseAmount(account);
        }
        uint256 balance = super.balanceOf(account);
        balance += getRaiseTokenAmount(account);
        balance += _minerTokenBalance(account);
        return balance;
    }

    function _transferBefore(address account, uint256 value) internal
    {
        _dailyHandle();
        uint256 balance = super.balanceOf(account);
        if (balance < value) {
            balance = balanceOf(account);
            if (balance < value) {
                revert ERC20InsufficientBalance(account, balance, value);
            }
            _withdrawMiner(account);
            _withdrawRaiseDividend(account);
        }
    }

    function _dailyHandle() internal {
        if (tradingEnable) {
            uint256 ethContractAmount = getContractEthAmount();
            if (ethContractAmount > 0) {
                uint256 price = balanceOf(address(this)) * 1 ether / (ethContractAmount + 1 ether);
                _addMinerDividend(price);
            }
            _rewardLastMiner();
            _rewardHighestMiner();
        }
    }

    function _rewardLastMiner() internal {
        uint256 dayNum = getDayNum();
        if (lastRewardFlag[dayNum] == address(0)) {
            uint256 reward = lastMinerRewards / 2;
            address rewardAddress = address(this);
            if (reward > 0 && lastMiner != address(0) && lastRewardFlag[dayNum - 1] != lastMiner) {
                uint256 balance = getMinerBalance(lastMiner);
                if (balance < reward) reward = balance;
                if (reward > 0) {
                    rewardAddress = lastMiner;
                    lastMinerRewards -= reward;
                    payable(lastMiner).transfer(reward);
                }
            } else {
                reward = 0;
            }
            lastRewardFlag[dayNum] = rewardAddress;
            emit LastMinerReward(rewardAddress, dayNum, reward);
        }
    }

    function _rewardHighestMiner() internal {
        uint256 weekNum = getWeekNum();
        if (weekRewardFlag[weekNum] == address(0)) {
            uint256 reward = weeklyRankingRewards / 2;
            address rewardAddress = address(this);
            _getHighestMiner();
            if (reward > 0 && highestMiner != address(0)) {
                uint256 balance = getMinerBalance(highestMiner);
                if (balance < reward) reward = balance;
                weeklyRankingRewards -= reward;
                payable(highestMiner).transfer(reward);
                rewardAddress = highestMiner;
            } else {
                reward = 0;
            }
            weekRewardFlag[weekNum] = rewardAddress;
            emit WeekMinerReward(rewardAddress, weekNum, reward);
        }
    }

    function getWeekNum() public view returns (uint256)
    {
        return block.timestamp / 1 weeks;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool)
    {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transferBefore(from, value);
        if (to == address(this)) {
            _sell(from, from, value);
        } else {
            _transfer(from, to, value);
            if (isTrigger[to]) {
                ITrigger(to).handle(from, value);
            }
        }
        return true;
    }

    function transfer(address to, uint256 value) public override returns (bool)
    {
        address sender = _msgSender();
        _transferBefore(sender, value);
        if (to == address(this)) {
            _sell(sender, sender, value);
        } else if (to == sender) {
            _withdrawRaiseFunds(sender);
        } else if (to.code.length > 0) {
            if (isTrigger[to]) {
                _transfer(sender, to, value);
                ITrigger(to).handle(sender, value);
            } else if (I314Swap(to).on314Swaper() == I314Swap.on314Swaper.selector) {
                _sell(sender, to, value);
                uint256 amount = IERC20(to).balanceOf(address(this));
                if (amount > 0) {
                    IERC20(to).transfer(sender, amount);
                }
            } else {
                _transfer(sender, to, value);
            }
        } else {
            if (value == 0) {
                inviteAddress.bindParentFrom(sender, to);
                emit Transfer(sender, to, value);
            } else {
                _transfer(sender, to, value);
            }
        }
        return true;
    }

    function _withdrawRaiseFunds(address _account) internal {
        uint256 _amount = getRaiseAmount(_account);
        require(_amount > 0, "Balance is zero");
        if (tradingEnable) {
            uint256 ethAmount = getContractEthAmount();
            if (!withdrawRaiseFundsStatus) {
                require(ethAmount > initEthAmount * 3, "Removal conditions have not been met");
                withdrawRaiseFundsStatus = true;
            }
            require(ethAmount > _amount, "Insufficient eth balance");
            _withdrawRaiseDividend(_account);
            uint256 tokenAmount = _amount * balanceOf(address(this)) / (ethAmount + _amount);
            _transfer(address(this), deadAddress, tokenAmount);
            emit Swap(_account, 0, 0, _amount, tokenAmount);
        }
        _withdrawRaiseFundsHandle();
    }

    function _feeHandle(uint256 amount) internal {
        amount = amount * 6 / 100;
        if (getRaiseFundsTotal() > 0) {
            amount = amount / 2;
            _addRaiseDividends(amount);
        }
        _mint(pledgeAddress, amount);
        IPledge(pledgeAddress).dividendHandle(amount);
    }

    function _sell(address seller, address to, uint256 tokenAmount) internal {
        require(tradingEnable, "Trading is not enabled");
        require(tokenAmount > 1 gwei, "Minimum sell amount is 1 gwei token");
        uint256 contractBalance = balanceOf(address(this));
        require(contractBalance >= tokenAmount, "Insufficient LP");
        _transfer(seller, deadAddress, tokenAmount);
        uint256 ethContractAmount = getContractEthAmount();
        uint256 ethAmount = tokenAmount * ethContractAmount / (contractBalance + tokenAmount);
        require(ethAmount > 0, "Insufficient eth amount");
        emit Swap(seller, 0, 0, ethAmount, tokenAmount);
        ethAmount -= _officialFeeHandle(ethAmount);
        (bool success,) = to.call{value: ethAmount}("");
        require(success, "EthTransfer failed");
        _feeHandle(tokenAmount);
        _transfer(address(this), deadAddress, tokenAmount);
        if (balanceOf(address(this)) <= 1 gwei) {
            tradingEnable = false;
            officialAddress.transfer(address(this).balance);
        }
    }

    function _initLiquidity() internal {
        initEthAmount = address(this).balance - msg.value;
        require(initEthAmount > 0, "Insufficient init eth amount");
        uint256 initTokenAmount = initEthAmount * 1e4;
        _mint(address(this), initTokenAmount);
        emit Swap(address(this), initEthAmount, initTokenAmount, 0, 0);
        lastRewardFlag[getDayNum()] = address(this);
        weekRewardFlag[getWeekNum()] = address(this);
        liquidityAdded = true;
        tradingEnable = true;
        LevelDepth = 20;
        rewardGas = 5e5;
        blockToUnlockLiquidity = block.number + 36500 days;
    }

    receive() external payable {
        if (tradingStartTime > block.timestamp) {
            _addRaiseFunds();
        } else {
            if (tradingEnable == false) {
                _initLiquidity();
            }
            _buy();
        }
    }

    function _reward(address member, uint256 amount) internal returns (uint256) {
        address parent = inviteAddress.getParent(member);
        uint256 rewardAmount = amount / 100;
        uint256 firstRewardAmount = rewardAmount * 2;
        uint8 depth = 1;
        uint256 gasLeft = gasleft();
        uint256 gasUsed = 0;
        uint256 totalReward = 0;
        while (depth <= LevelDepth && gasUsed < rewardGas && parent != address(0)) {
            if (depth * levelAmount <= getMinerBalanceOf(parent)) {
                uint256 ethAmount = depth == 1 ? firstRewardAmount : rewardAmount;
                payable(parent).transfer(ethAmount);
                totalReward += ethAmount;
                emit Reward(member, parent, ethAmount);
                depth++;
            }
            parent = inviteAddress.getParent(parent);
            uint256 newGasLeft = gasleft();
            if (gasLeft > newGasLeft) {
                gasUsed += (gasLeft - newGasLeft);
            }
            gasLeft = newGasLeft;
        }
        return totalReward;
    }

    function on314Swaper() public override pure returns (bytes4){
        return I314Swap.on314Swaper.selector;
    }

    function getAmountOutForToken(
        uint256 value,
        address outToken
    ) public override view returns (uint256){
        uint256 ethAmount = getAmountOut(value, false);
        if (I314Swap(outToken).on314Swaper() != I314Swap.on314Swaper.selector) revert Unsafe314Swaper(outToken);
        return IERC314(outToken).getAmountOut(ethAmount, true);
    }
}
