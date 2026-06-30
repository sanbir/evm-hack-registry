// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import {IUniswapV2Router02} from '@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol';
import {IUniswapV2Pair} from '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import {USDT, ROUTER, MARKETING_1, MARKETING_2, INCENTIVE} from './Const.sol';
import {IR} from './interface/IR.sol';
import {IDividendTracker} from './interface/IDividendTracker.sol';
import './lib/Helper.sol';

contract BCE is ERC20, Ownable {
    mapping(address => uint256) public lastUpdateTime;
    address public immutable uniswapV2Pair;
    IDividendTracker public trackerCommunity;
    IDividendTracker public trackerSuper;
    IDividendTracker public trackerGenesis;
    uint40 public burnCount;
    uint40 public liquidityCount;
    uint40 public lanuchTime;
    mapping(address => uint256) public lastBuyTime;
    uint256 public lastBurnPool;
    uint256 public scheduledDestruction;
    mapping(address => bool) public excludeHold;
    mapping(address => bool) public whiteList;
    mapping(address => bool) public invested;
    mapping(address => uint256) public lpTracker;
    mapping(uint40 => uint256) public dailyInvestment;
    mapping(uint40 => IR.Log) public burnLogs;
    mapping(uint40 => IR.Log) public liquidityLogs;
    mapping(address => uint40[]) public userBurnIds;
    mapping(address => uint40[]) public userLiquidityIds;
    mapping(address => uint256) public userAccumulateBuy;
    mapping(address => IR.Postion) public userBurnPostion;
    mapping(address => IR.Postion) public userLiquidityPostion;
    uint256 public globalKpi;
    uint256 public MIN_HOLD_AMOUNT = 100 ether;
    uint256[2][4] public NODE_BUY_LIMIT = [[uint256(0), 0], [uint256(100e18), 500e18], [uint256(200e18), 1000e18], [uint256(600e18), 3000e18]];

    IR public R;

    constructor(address _owner) ERC20('BCE', 'BCE') Ownable(_owner) {
        uniswapV2Pair = IUniswapV2Factory(IUniswapV2Router02(ROUTER).factory()).createPair(USDT, address(this));
        _mint(_owner, 21000000 ether);
        lastBurnPool = block.timestamp / 1 days;
        excludeHold[address(0)] = true;
        excludeHold[address(1)] = true;
        excludeHold[address(0xdead)] = true;
        excludeHold[address(this)] = true;
        excludeHold[_owner] = true;
        excludeHold[uniswapV2Pair] = true;
        whiteList[_owner] = true;
    }

    function balanceOf(address account) public view virtual override returns (uint256) {
        return super.balanceOf(account) + calculateInterestHold(account);
    }

    function setR(address addr) public onlyOwner {
        R = IR(addr);
    }

    function setWhiteList(address addr, bool flag) public onlyOwner {
        whiteList[addr] = flag;
    }

    function setMinHoldAmount(uint256 amount) public onlyOwner {
        MIN_HOLD_AMOUNT = amount;
    }

    function setTracker(address addrCommunity, address addrSuper, address addrGenesis) public onlyOwner {
        trackerCommunity = IDividendTracker(addrCommunity);
        trackerSuper = IDividendTracker(addrSuper);
        trackerGenesis = IDividendTracker(addrGenesis);
        _approve(address(this), addrCommunity, type(uint256).max);
        _approve(address(this), addrSuper, type(uint256).max);
        _approve(address(this), addrGenesis, type(uint256).max);
        excludeHold[addrCommunity] = true;
        excludeHold[addrSuper] = true;
        excludeHold[addrGenesis] = true;
    }

    function lanuch() public onlyOwner {
        require(lanuchTime == 0, 'lanuched');
        lanuchTime = uint40(block.timestamp);
    }

    function getUserBurnCount(address user) public view returns (uint256) {
        return userBurnIds[user].length;
    }

    function getUserLiquidityCount(address user) public view returns (uint256) {
        return userLiquidityIds[user].length;
    }

    function transfer(address to, uint256 value) public virtual override returns (bool) {
        address owner = _msgSender();
        _update(owner, to, value);
        return true;
    }

    function _processAddLiquidity(address account, uint256 amountLP, uint256 amountUSDT) internal {
        require(userBurnPostion[account].amountUSDT == 0 && userLiquidityPostion[account].amountUSDT <= 200 ether, 'position is exists 1');
        liquidityCount++;
        liquidityLogs[liquidityCount] = IR.Log({index: liquidityCount, time: uint40(block.timestamp), amountToken: amountLP, amountUSDT: amountUSDT, account: account});
        userLiquidityIds[account].push(liquidityCount);

        claimInterestBurnAndLiquidity(account);

        IR.Postion storage pos = userLiquidityPostion[account];

        int256 deltaLP;
        int256 deltaUSDT;
        if (pos.amountUSDT == 0) {
            pos.amountToken = amountLP;
            pos.amountUSDT = amountUSDT;
            pos.startTime = block.timestamp;
            pos.claimed = 0;
            deltaLP = int256(amountLP);
            deltaUSDT = int256(amountUSDT);
            lpTracker[account] = amountLP;
        } else {
            uint256 eliminated = pos.claimed / 3;
            deltaLP = int256(amountLP) - int256((pos.amountToken * eliminated) / pos.amountUSDT);
            deltaUSDT = int256(amountUSDT) - int256(eliminated);
            pos.startTime = block.timestamp;
            pos.amountToken = Helper.add(pos.amountToken, deltaLP);
            pos.amountUSDT = Helper.add(pos.amountUSDT, deltaUSDT);
            pos.claimed = 0;
            lpTracker[account] = Helper.add(lpTracker[account], deltaLP);
        }
        R.notifyLiquidity(account, deltaUSDT);
        globalKpi += amountUSDT;
        pos.globalKpi = globalKpi;
    }

    function _processBurn(address account, uint256 amount) internal {
        require(userBurnPostion[account].amountUSDT <= 200 ether && userLiquidityPostion[account].amountUSDT == 0, 'position is exists 2');
        (uint256 reserveUSDT, uint256 reserveBCE) = Helper.getReserves(uniswapV2Pair);
        uint256 usdt = (reserveUSDT * amount) / reserveBCE;
        _checkInvestment(account, usdt, reserveUSDT);
        burnCount++;
        burnLogs[burnCount] = IR.Log({index: burnCount, time: uint40(block.timestamp), amountToken: amount, amountUSDT: usdt, account: account});
        userBurnIds[account].push(burnCount);

        claimInterestBurnAndLiquidity(account);

        IR.Postion storage pos = userBurnPostion[account];

        int256 deltaBCE;
        int256 deltaUSDT;
        if (pos.amountToken == 0) {
            pos.amountToken = amount;
            pos.amountUSDT = usdt;
            pos.startTime = block.timestamp;
            pos.claimed = 0;
            deltaBCE = int256(amount);
            deltaUSDT = int256(usdt);
        } else {
            uint256 eliminated = pos.claimed / 3;
            deltaBCE = int256(amount) - int256(eliminated);
            deltaUSDT = int256(usdt) - int256((pos.amountUSDT * eliminated) / pos.amountToken);
            pos.startTime = block.timestamp;
            pos.amountToken = Helper.add(pos.amountToken, deltaBCE);
            pos.amountUSDT = Helper.add(pos.amountUSDT, deltaUSDT);
            pos.claimed = 0;
        }
        R.notifyBurn(account, deltaBCE, deltaUSDT);
        globalKpi += usdt;
        pos.globalKpi = globalKpi;
    }

    function _distributeFee() internal {
        uint256 amount = balanceOf(address(this)) / 35;
        if (amount == 0) return;
        trackerCommunity.distributeDividends(amount * 3);
        trackerSuper.distributeDividends(amount * 10);
        trackerGenesis.distributeDividends(amount * 8);
        super._update(address(this), MARKETING_1, amount * 3);
        super._update(address(this), MARKETING_2, amount * 3);
        super._update(address(this), INCENTIVE, amount * 8);
    }

    function _checkInvestment(address account, uint256 amountUSDT, uint256 reserveUSDT) internal {
        uint40 today = uint40(block.timestamp / 1 days);
        if (!invested[account]) {
            invested[account] = true;
            dailyInvestment[today] += amountUSDT;
        }
        if (lanuchTime / 1 days == today) return;
        uint256 todayInvestment = dailyInvestment[today];
        if (reserveUSDT < 2e6 ether) require(todayInvestment <= 8e4 ether, 'MI');
        else if (reserveUSDT < 5e6 ether) require(todayInvestment <= 15e4 ether, 'MI');
        else if (reserveUSDT < 1e7 ether) require(todayInvestment <= 30e4 ether, 'MI');
        else require(todayInvestment <= 50e4 ether, 'MI');
    }

    function _update(address from, address to, uint256 value) internal override {
        _claimInterestHold(from);
        if (to == from && value == 1 ether) {
            claimInterestBurnAndLiquidity(from);
            super._update(from, to, value);
            return;
        }
        if (address(0) == from) {
            super._update(from, to, value);
            return;
        }
        if (to == address(0) && value > 0) {
            _processBurn(from, value);
        }
        address _uniswapV2Pair = uniswapV2Pair;
        (uint256 reserveUSDT, uint256 reserveBCE) = Helper.getReserves(_uniswapV2Pair);
        if (_uniswapV2Pair == from) {
            require(Helper.isRemoveLiquidity(IERC20(USDT), value, _uniswapV2Pair) == 0 || tx.origin == owner(), 'not allow remove');
            require(lanuchTime > 0, 'not lanuched');
            if (block.timestamp < lanuchTime + 30 minutes) {
                uint256 node = R.getUserNode(to);
                uint256 buyUSDT = IERC20(USDT).balanceOf(_uniswapV2Pair) - reserveUSDT;
                userAccumulateBuy[to] += buyUSDT;
                require(buyUSDT <= NODE_BUY_LIMIT[node][0] && userAccumulateBuy[to] <= NODE_BUY_LIMIT[node][1], 'buy limit');
            }

            if (!whiteList[to]) {
                uint256 fee = value / 20;
                super._update(from, address(this), fee);
                value -= fee;
            }

            _distributeFee();
            lastBuyTime[to] = block.timestamp;
        } else if (_uniswapV2Pair == to) {
            (uint256 lpAmount, uint256 deltaUSDT) = Helper.isAddLiquidity(IERC20(USDT), value, _uniswapV2Pair);
            if (lpAmount > 0) {
                if (from != owner()) {
                    _checkInvestment(from, deltaUSDT * 2, reserveUSDT);
                    _processAddLiquidity(from, lpAmount, deltaUSDT * 2);
                }
            } else {
                // sell
                require(block.timestamp >= lastBuyTime[from] + 1 minutes, 'cold');
                if (from != owner() || !whiteList[from]) {
                    uint256 fee = (value * 30) / 100;
                    super._update(from, address(this), fee);
                    value -= fee;
                    _distributeFee();
                }

                uint256 per = reserveBCE / 2100000 ether;
                per = per >= 10 ? 10 : per;
                scheduledDestruction += (value * per * 10) / 100;
            }
        } else {
            if (lastBuyTime[to] == 0) lastBuyTime[to] = block.timestamp;
            if (from != address(this)) {
                uint256 today = block.timestamp / 1 days;
                if (lastBurnPool < today) {
                    super._update(_uniswapV2Pair, address(0), reserveBCE / 100);
                    IUniswapV2Pair(_uniswapV2Pair).sync();
                    lastBurnPool++;
                }
                if (scheduledDestruction > 0) {
                    super._update(_uniswapV2Pair, address(0), scheduledDestruction);
                    IUniswapV2Pair(_uniswapV2Pair).sync();
                    scheduledDestruction = 0;
                }
                if (value == 0.3 ether) {
                    require(reserveBCE > 0, 'no liquidity');
                    require((balanceOf(from) * reserveUSDT) / reserveBCE >= 200 ether, 'lt 200u');
                    R.notifyTransfer(from, to);
                }
                if (!whiteList[from]) {
                    super._update(from, address(0), value / 2);
                    value /= 2;
                }
            }
        }
        if (value > 0) super._update(from, to, value);
        _claimInterestHold(to);
    }

    function calculateInterestHold(address account) public view returns (uint256 interest) {
        if (excludeHold[account]) return 0;
        uint256 principal = super.balanceOf(account);
        if (principal < MIN_HOLD_AMOUNT) return 0;

        uint256 lastTime = lastUpdateTime[account];
        if (lastTime == 0) return 0;

        uint256 secondsElapsed = block.timestamp - lastTime;
        if (secondsElapsed == 0) return 0;

        // interest = (principal * 3 * secondsElapsed) / (86400 * 1000);
        interest = (principal * secondsElapsed) / 288e5;
    }

    function calculateInterestBurnAndLiquidity(address account) public view returns (uint256 interestBurn, uint256 interestLiquidity) {
        (uint256 reserveUSDT, uint256 reserveBCE) = Helper.getReserves(uniswapV2Pair);
        uint256 posLiquidity = userLiquidityPostion[account].amountUSDT;
        uint256 posBurn = userBurnPostion[account].amountUSDT;
        uint256 posTotal = posLiquidity + posBurn;
        uint256 globalKpiAcceleration = R.globalKpiAcceleration(account);
        uint256 tReward = R.calculateReward(account);
        uint256[4] memory _var = [uint256(0), 0, 0, 0];

        IR.Postion storage pos = userBurnPostion[account];
        uint256 principal = pos.amountToken;
        _var[0] = block.timestamp - pos.startTime;
        if (principal > 0 && _var[0] > 0) {
            // interest = (principal * 2 * secondsElapsed) / (86400 * 100);
            interestBurn = (principal * _var[0]) / 432e4;

            _var[1] = globalKpi - pos.globalKpi;
            _var[2] = (_var[1] * globalKpiAcceleration * reserveBCE * posBurn) / (1e5 * reserveUSDT * posTotal);
            interestBurn += _var[2] > interestBurn ? interestBurn : _var[2];

            interestBurn += (tReward * posBurn) / posTotal;
            _var[3] = principal * 3 - pos.claimed;
            interestBurn = interestBurn > _var[3] ? _var[3] : interestBurn;
        }

        pos = userLiquidityPostion[account];
        principal = pos.amountUSDT;
        _var[0] = block.timestamp - pos.startTime;
        if (principal > 0 && _var[0] > 0) {
            // interest = (principal * 2 * secondsElapsed * reserveBCE) / (86400 * 100 * reserveUSDT);
            interestLiquidity = (principal * _var[0] * reserveBCE) / (432e4 * reserveUSDT);

            _var[1] = globalKpi - pos.globalKpi;
            _var[2] = (_var[1] * globalKpiAcceleration * reserveBCE * posLiquidity) / (1e5 * reserveUSDT * posTotal);
            interestLiquidity += _var[2] > interestLiquidity ? interestLiquidity : _var[2];

            interestLiquidity += (tReward * posLiquidity) / posTotal;
            _var[3] = ((principal * 3 - pos.claimed) * reserveBCE) / reserveUSDT;
            interestLiquidity = interestLiquidity > _var[3] ? _var[3] : interestLiquidity;
        }
    }

    function _cleanPostion(IR.Postion storage pos) internal {
        pos.amountToken = 0;
        pos.amountUSDT = 0;
        pos.claimed = 0;
        pos.startTime = 0;
        pos.globalKpi = 0;
    }

    function claimInterestBurnAndLiquidity(address account) public {
        (uint256 interestBurn, uint256 interestLiquidity) = calculateInterestBurnAndLiquidity(account);
        if (interestBurn > 0) {
            _mint(account, interestBurn);
            IR.Postion storage pos = userBurnPostion[account];
            pos.claimed += interestBurn;
            pos.globalKpi = globalKpi;
            pos.startTime = block.timestamp;
            if (pos.claimed + 3 >= pos.amountToken * 3) {
                R.notifyBurn(account, -int256(pos.amountToken), -int256(pos.amountUSDT));
                _cleanPostion(pos);
            }
        }
        if (interestLiquidity > 0) {
            _mint(account, interestLiquidity);
            IR.Postion storage pos = userLiquidityPostion[account];
            (uint256 reserveUSDT, uint256 reserveBCE) = Helper.getReserves(uniswapV2Pair);
            pos.claimed += (interestLiquidity * reserveUSDT) / reserveBCE;
            pos.globalKpi = globalKpi;
            pos.startTime = block.timestamp;
            if (pos.claimed + 3 >= pos.amountUSDT * 3) {
                R.notifyLiquidity(account, -int256(pos.amountUSDT));
                _cleanPostion(pos);
                lpTracker[account] = 0;
            }
        }
        if (interestBurn > 0 || interestLiquidity > 0) R.claimReward(account);
    }

    function _claimInterestHold(address account) internal {
        uint256 interest = calculateInterestHold(account);
        if (interest > 0) {
            _mint(account, interest);
            lastUpdateTime[account] = block.timestamp;
        }
        if (lastUpdateTime[account] == 0 && super.balanceOf(account) >= MIN_HOLD_AMOUNT) lastUpdateTime[account] = block.timestamp;
    }
}
