//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";

import "../interfaces/nana/IFeeHandler.sol";
import "../interfaces/ITokenAFeeHandler.sol";
import "../interfaces/IOracle.sol";
import "../libraries/TransferHelper.sol";
import "../BkWeList.sol";
//import "hardhat/console.sol";

contract BananaSwapToken is ITokenAFeeHandler, BkWeList, OwnableUpgradeable {
    using EnumerableSet for EnumerableSet.UintSet;
    using SafeMathUpgradeable for uint;

    string private _name;
    string private _symbol;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowed;
    uint256 private _totalSupply;

    mapping(address => bool) public isManager;
    mapping(ActionType => TradingOperationConfig) private configMaps;

    uint16 public base;
    uint16 public transferPercent;
    uint16 public sellPercent;

    LiquidityLockConfig private liquidityLockConfig;

    IOracle public oracle;
    // inflation
    uint256 public spy;
    uint256 public step;
    uint256 public inflationPattern; // 0 default normal token, 1 inflation token
    uint256 public extraSupply;
    uint256 public inflationRewardEndTime;
    uint256 public minInflationAmount;
    uint256 public reduceThreshold;
    bool public bInInflation;
    mapping(address => bool) public inflationRewardBlacklist;
    mapping(address => uint256) public lastUpdateTime;
    InsuredConfig[] public insuredConfigs;

    event InflationMint(address indexed account, uint256 extraAmount);
    event FeeDeduct(address user,address token,uint256 feeAmount, ActionType actionType, FeeType rewardType );

    modifier onlyManager() {
        require(isManager[_msgSender()], "Not manager");
        _;
    }

    function initialize(string memory name_, string memory symbol_, uint[] memory percentages, address[] memory addrs, uint256 total) public initializer {
        __Ownable_init();
        _name = name_;
        _symbol = symbol_;
        base = 10000;
        isManager[_msgSender()] = true;

        spy = (uint256)(208 * (10**14)) / 1 days;
        step = 15 minutes;
        inflationPattern = 0;
        inflationRewardEndTime = block.timestamp.add(365 days);

        //Add a destroyed configuration by default for check the
        FeeConfig memory feeConfig = FeeConfig(0, false, address(0x000000000000000000000000000000000000dEaD));
        ActionType actionType = ActionType.Sell;
        FeeType feeType = FeeType.destroyRatio;
        configMaps[actionType].rewardTypeSet.add(uint(feeType));
        configMaps[actionType].handleConfig[uint(feeType)] = feeConfig;

        //allocate
        require(percentages.length == addrs.length, "input neq addrs");
        require(total>0,"input ls zero");
        for (uint256 i = 0; i < percentages.length; i++) {
            uint amount = (percentages[i] * total) / 10000;
            _balances[addrs[i]] += amount;
            _totalSupply = _totalSupply.add(amount);
            emit Transfer(address(0), addrs[i], amount);
        }
    }

    function setOracle(IOracle _oracle) public onlyManager {
        oracle = _oracle;
    }

    function setReduceThreshold(uint _reduceThreshold) public onlyManager {
        reduceThreshold = _reduceThreshold;
    }

    function getReduceThreshold() external view override returns (uint) {
        return reduceThreshold;
    }

    function getBase() external view override returns (uint256) {
        return base;
    }

    function setTransferPercent(uint16 _transferPercent) public onlyManager {
        transferPercent = _transferPercent;
    }

    function setSellPercent(uint16 _sellPercent) public onlyManager {
        sellPercent = _sellPercent;
    }

    function addInsuredConfig(InsuredConfig memory insuredConfig) external onlyManager {
        insuredConfigs.push(insuredConfig);
    }

    function removeInsuredConfig(uint256 index) external onlyManager {
        require(index < insuredConfigs.length, "I");
        insuredConfigs[index] = insuredConfigs[insuredConfigs.length - 1];
        insuredConfigs.pop();
    }

    // Find the corresponding slippage rate based on the oracle price change rate.
    function getInsuredConfigRatio() external view returns(uint256 ratio) {
        if (address(oracle) == address(0)) {
            return 0;
        }
        uint256 priceChangeRatio = oracle.getPriceChangeRatio();
        if (priceChangeRatio > 0) {
            for (uint256 index = 0; index < insuredConfigs.length; index++) {
                InsuredConfig memory config = insuredConfigs[index];
                if (
                    priceChangeRatio >= config.start &&
                    priceChangeRatio < config.end
                ) {
                    ratio = config.ratio;
                    return ratio;
                }
            }
        }
    }

    function setFeeConfig(ActionType _actionType,FeeType _feeType,FeeConfig memory _config,bool opt) external override onlyManager {
        if (opt) {
            configMaps[_actionType].rewardTypeSet.add(uint(_feeType));
            configMaps[_actionType].totalFeeRatio = configMaps[_actionType].totalFeeRatio+_config.feeRatio;
            configMaps[_actionType].handleConfig[uint(_feeType)] = _config;
        } else {
            configMaps[_actionType].rewardTypeSet.remove(uint(_feeType));
            configMaps[_actionType].totalFeeRatio = configMaps[_actionType].totalFeeRatio-_config.feeRatio;
            delete configMaps[_actionType].handleConfig[uint(_feeType)];
        }
    }

    function getFeeConfig(ActionType _actionType, FeeType _feeType) external view override returns(FeeConfig memory feeConfig) {
        return configMaps[_actionType].handleConfig[uint(_feeType)];
    }

    // decut the config fee and transfer to handle fee addree which config.
    // prameter from
    function distributeFee(ActionType actionType, uint feeAmount, address from, address user) internal {
        // console.log("from is:",from);
        // console.log("_balances[from],feeAmount is:",_balances[from],feeAmount);
        _balances[from] = _balances[from].sub(feeAmount);
        TradingOperationConfig storage operatingConfig = configMaps[actionType];
        uint len = operatingConfig.rewardTypeSet.length();
        uint256 totalFeeRatio = operatingConfig.totalFeeRatio;
        for (uint index = 0; index < len; index++) {
            uint feeType = operatingConfig.rewardTypeSet.at(index);
            FeeConfig storage feeConfig = operatingConfig.handleConfig[feeType];
            uint256 feeRatio = feeConfig.feeRatio;

            //If it is a reflow casting pool, the number of amounts will change due to the impact on the fluidity. is processed last.
            if (feeType == uint(ITokenAFeeHandler.FeeType.reflowRatio) 
                || feeType == uint(ITokenAFeeHandler.FeeType.repurchaseDestroy)) {
                uint amountOfAFee = (feeRatio * feeAmount) / totalFeeRatio;
                
                _balances[address(feeConfig.feeHandler)] += amountOfAFee;
                emit FeeDeduct(user,address(this),amountOfAFee, actionType, FeeType(feeType));
                emit Transfer(from, feeConfig.feeHandler, amountOfAFee);
                // this.transferFrom(address(this), feeConfig.feeHandler, amountOfAFee);
                continue;
            }

            // If it is a sell operation and a destroy operation. 
            // Then it is necessary to judge whether the insured mechanism is effective. 
            // If it is effective, the rate of destruction needs to be increased.
            if (
                feeType == uint(ITokenAFeeHandler.FeeType.destroyRatio) &&
                actionType == ITokenAFeeHandler.ActionType.Sell
            ) {
                uint insuredRatio = this.getInsuredConfigRatio();
                if (insuredRatio > 0) {
                    feeRatio += insuredRatio;
                    totalFeeRatio += insuredRatio;
                }
            }
            if (feeRatio > 0) {
                uint amountOfAFee = (feeRatio * feeAmount) / totalFeeRatio;
                // super._transfer(address(this), feeConfig.feeHandler, amountOfAFee);
                _balances[address(feeConfig.feeHandler)] += amountOfAFee;
                emit FeeDeduct(user,address(this),amountOfAFee, actionType, FeeType(feeType));
                emit Transfer(from, feeConfig.feeHandler, amountOfAFee);
                if (feeConfig.needHandle) {
                    IFeeHandler(feeConfig.feeHandler).handleFee( address(this), amountOfAFee );
                }
            }
        }
    }

    // reflow fee processing.
    function reflowDistributeFee(ActionType actionType) external override {
        TradingOperationConfig storage operatingConfig = configMaps[actionType];
        FeeConfig storage feeConfig = operatingConfig.handleConfig[
            uint(ITokenAFeeHandler.FeeType.reflowRatio)
        ];
        if (feeConfig.feeRatio > 0) {
            IFeeHandler(feeConfig.feeHandler).handleFee(address(this), 0);
        }

        FeeConfig storage feeConfig2 = operatingConfig.handleConfig[
            uint(ITokenAFeeHandler.FeeType.repurchaseDestroy)
        ];
        if (feeConfig2.feeRatio > 0) {
            IFeeHandler(feeConfig2.feeHandler).handleFee(address(this), 0);
        }
    }


    function handleDeductFee(ActionType actionType, uint256 feeAmount, address from,address user) external override {
        distributeFee(actionType, feeAmount, from,user);
    }

    // Calculates the amount of reduced handling fee based on the amount entered and the total handling fee.
    function calDeductFee(ActionType actionType, uint256 inputAmount) external view override returns (uint256 leftAmount) {
        TradingOperationConfig storage operatingConfig = configMaps[actionType];
        uint256 totalFeeRatio = operatingConfig.totalFeeRatio;
        // If it is a sell operation and a destroy operation. 
        // Then it is necessary to judge whether the insured mechanism is effective. 
        // If it is effective, the rate of destruction needs to be increased.。
        if (actionType == ITokenAFeeHandler.ActionType.Sell) {
            uint256 insuredRatio = this.getInsuredConfigRatio();
            if (insuredRatio > 0) {
                totalFeeRatio += insuredRatio;
            }
        }
        if (totalFeeRatio <= 0) {
            return inputAmount;
        }

        leftAmount = (inputAmount * (base - totalFeeRatio)) / base;
        return leftAmount;
    }

    // Calculate the amount of increased handling fee based on the amount entered and the total handling fee
    function calAddFee(ActionType actionType, uint256 inputAmount) external view override returns (uint256 addAmount) {
        TradingOperationConfig storage operatingConfig = configMaps[actionType];
        uint256 totalFeeRatio = operatingConfig.totalFeeRatio;

        // If it is a sell operation and a destroy operation. 
        // Then it is necessary to judge whether the insured mechanism is effective. 
        // If it is effective, the rate of destruction needs to be increased.
        if (actionType == ITokenAFeeHandler.ActionType.Sell) {
            uint256 insuredRatio = this.getInsuredConfigRatio();
            if (insuredRatio > 0) {
                totalFeeRatio += insuredRatio;
            }
        }

        if (totalFeeRatio <= 0) {
            return inputAmount;
        }
        addAmount = (base * inputAmount) / (base - totalFeeRatio);
        if (((base * inputAmount) % (base - totalFeeRatio)) > 0) {
            addAmount += 1;
        }
        return addAmount;
    }

    function setManager(address _manager, bool _flag) public onlyOwner {
        isManager[_manager] = _flag;
    }
    
    function getManager(address manager) public view returns (bool) {
        return isManager[manager];
    }

    function truncateManager() public onlyManager {
        delete isManager[msg.sender];
    }

    function setInflationRewardBlacklist(address account, bool enable) public virtual onlyManager {
        inflationRewardBlacklist[account] = enable;
    }

    function getReward(address account) public view returns (uint256) {
       if (lastUpdateTime[account] == 0 || inflationRewardBlacklist[account] || inflationPattern == 0 || _balances[account] < minInflationAmount) {
            return 0;
        }

        uint256 duration = lastTime().sub(lastUpdateTime[account]);
        if (duration < step) {
            return 0;
        }

        return _balances[account].mul(spy).mul(lastTime().sub(lastUpdateTime[account])).div(10**18);
    }   

    function lastTime() public view returns (uint256) {
        return MathUpgradeable.min(block.timestamp, inflationRewardEndTime);
    }

    modifier calculateReward(address account) {
        if (account != address(0) && !bInInflation ) {
            bInInflation = true;

            uint256 reward = getReward(account);
            if (reward > 0) {
                extraSupply = extraSupply.add(reward);
                _balances[account] = _balances[account].add(reward);
                emit InflationMint(account, reward);
            }

            lastUpdateTime[account] = inflationPattern == 0 ? 0 : lastTime();
            bInInflation = false;
        }
        _;
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual calculateReward(from) calculateReward(to) { }

    function setSpy(uint256 _spy) public virtual onlyManager {
        spy = _spy;
    }

    function setStep(uint256 _step) public virtual onlyManager {
        step = _step;
    }

    function setInflationPattern(uint8 pattern) public onlyManager {
        require(pattern == 0 || pattern == 1, "invalide value");
        inflationPattern = pattern;
    }

    function setInflationRewardEndTime(uint256 endTime) public onlyManager {
        inflationRewardEndTime = endTime;
    }

    function setMinInflationAmount(uint256 _minInflationAmount) public onlyManager {
        minInflationAmount = _minInflationAmount;
    }

    function getLiquidityLockConfig() external view override returns (LiquidityLockConfig memory config) {
        return liquidityLockConfig;
    }

    function setLiquidityLockConfig(LiquidityLockConfig memory config) external override onlyManager {
        liquidityLockConfig = config;
    }

    function validateBk(address buyAddress) public view override {
        validateBkWe(buyAddress);
    }

    function totalSupply() public view override returns (uint256) {
        return _totalSupply + extraSupply;
    }

    function balanceOf(address owner) public view override returns (uint256) {
        return _balances[owner] + getReward(owner);
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowed[owner][spender];
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        _transferFrom(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        require(spender != address(0));
        _allowed[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        require(value <= _allowed[from][msg.sender]);
        _allowed[from][msg.sender] = _allowed[from][msg.sender].sub(value);
        _transferFrom(from, to, value);
        return true;
    }

    function _transferFrom(address from, address to, uint256 value) internal returns (bool) {
        require(value <= balanceOf(from), "error balance");
        require(to != address(0), "zero address");
        require(!isBkList(from),"is Bk");

        _beforeTokenTransfer(from, to, value);
        
        // The account must keep a certain remaining amount.
        // If the from is contract,it is not restricted by this rule, because the contract does other DEFI business
        if (!TransferHelper.isContract(from)) {
            uint256 balanceOfFrom = balanceOf(from);
            require((balanceOfFrom - value) * base >= transferPercent * balanceOfFrom, "amount gt balance");
        }
        uint deductFeeAmount = value;
        if(!(TransferHelper.isContract(from) || TransferHelper.isContract(to)) && !isWeList(from)){
            deductFeeAmount = this.calDeductFee(ActionType.Transfer, value);
            uint256 fee = value - deductFeeAmount;
            //If it is a transfer to a contract or not, it is a transfer between users
            if (fee > 0) {
                this.handleDeductFee(ActionType.Transfer,fee, msg.sender,msg.sender);
                this.reflowDistributeFee(ActionType.Transfer);
            }
        }

        _balances[from] = _balances[from].sub(deductFeeAmount);
        _balances[to] = _balances[to].add(deductFeeAmount);
        emit Transfer(from, to, deductFeeAmount);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public returns (bool) {
        require(spender != address(0));
        _allowed[msg.sender][spender] = (_allowed[msg.sender][spender].add(addedValue));
        emit Approval(msg.sender, spender, _allowed[msg.sender][spender]);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public returns (bool) {
        require(spender != address(0));
        _allowed[msg.sender][spender] = (_allowed[msg.sender][spender].sub(subtractedValue));
        emit Approval(msg.sender, spender, _allowed[msg.sender][spender]);
        return true;
    }

    function _burn(address account, uint256 amount) internal {
        require(account != address(0));
        require(amount <= _balances[account]);

        _totalSupply = _totalSupply.sub(amount);
        _balances[account] = _balances[account].sub(amount);
        emit Transfer(account, address(0), amount);
    }

    function _burnFrom(address account, uint256 amount) internal {
        require(amount <= _allowed[account][msg.sender]);
        _allowed[account][msg.sender] = _allowed[account][msg.sender].sub(amount);
        _burn(account, amount);
    }

    // for swap transfer with fee delivery
    function _transferFromFee(
        address from,
        address to,
        uint256 value,
        ActionType actionType,
        address user

    ) internal returns (uint256 deductFeeLeftAmount) {
        require(value <= balanceOf(from), "error balance");
        require(to != address(0), "zero address");

        _beforeTokenTransfer(from, to, value);

        // Account sold must keep a certain remaining amount
        // If the contract is transferred to other contracts or users, 
        // it is not restricted by this rule, because the contract does other DEFI business.
        if (!TransferHelper.isContract(from)) {
            uint256 balanceOfFrom = balanceOf(from);
            require((balanceOfFrom - value) * base >= sellPercent * balanceOfFrom, "sellAmount gt balance");
        }
        deductFeeLeftAmount = this.calDeductFee(actionType, value);
        uint256 feeAmount = value - deductFeeLeftAmount;
        if (feeAmount > 0) {
            this.handleDeductFee(actionType, feeAmount, from,user);
        }

        _balances[from] = _balances[from].sub(deductFeeLeftAmount);
        _balances[to] = _balances[to].add(deductFeeLeftAmount);
        emit Transfer(from, to, deductFeeLeftAmount);
        return deductFeeLeftAmount;
    }

    // for swap transfer with fee delivery
    function transferFee(
        address to, 
        uint256 value, 
        ActionType actionType,
        address user
    ) public override returns (uint256 deductFeeLeftAmount) {
        return _transferFromFee(msg.sender, to, value, actionType,user);
    }

    // for swap transfer with fee delivery
    function transferFromFee(
        address from,
        address to,
        uint256 value,
        ActionType actionType,
        address user
    ) public override returns (uint256 deductFeeLeftAmount) {
        require(value <= _allowed[from][msg.sender]);
        _allowed[from][msg.sender] = _allowed[from][msg.sender].sub(value);
        return _transferFromFee(from, to, value, actionType,user);
    }

    function decimals() external pure override returns (uint8) {
        return 18;
    }

    function name() external view override returns (string memory) {
        return _name;
    }

    function symbol() external view override returns (string memory) {
        return _symbol;
    }

    function addWeList(address[] memory _address) public virtual onlyManager {
        _addWeList(_address);
    }

    function removeWeList(address _address) public virtual onlyManager {
        _removeWeList(_address);
    }

    function addBkList(address[] memory _address) public virtual onlyManager {
        _addBkList(_address);
    }

    function removeBkList(address _address) public virtual onlyManager {
        _removeBkList(_address);
    }

}
