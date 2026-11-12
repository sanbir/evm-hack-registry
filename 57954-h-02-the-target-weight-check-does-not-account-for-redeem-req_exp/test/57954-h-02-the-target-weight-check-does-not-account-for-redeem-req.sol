// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Cove BasketManager — target-weight check ignores pending redeems (Pashov H-02, finding 57954)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    _isTargetWeightMet quotes baseBalance, which still includes the pending redeem.
    Base value 1600 of total 10000 is 16% against a 10% target, deviation 6% > 5%,
    so the rebalance returns false and the 600 redeem stays in the basket.
    Subtracting the pending redeem leaves 10% and the redeem pays.
    The blamed weight product is preserved (@> VULN). run() does not warp. */

contract MockToken {
    string public name = "Base Asset";
    string public symbol = "BASE";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract BasketManager {
    uint256 public constant WEIGHT_PRECISION = 10_000;
    uint256 public constant MAX_WEIGHT_DEVIATION = 500;

    MockToken public token;
    uint256 public baseBalance;
    uint256 public totalValue;
    uint256 public targetWeight;
    uint256 public pendingRedeem;
    uint256 public afterTradeWeight;
    uint256 public deviation;
    bool public met;
    address public redeemer;

    constructor(address token_) {
        token = MockToken(token_);
        baseBalance = 1000 ether;
        totalValue = 10000 ether;
        targetWeight = 1000;
        token.mint(address(this), 1000 ether);
    }

    function queueRedeem(address user, uint256 amount) external {
        token.mint(address(this), amount);
        baseBalance += amount;
        pendingRedeem += amount;
        redeemer = user;
    }

    // BasketManager._isTargetWeightMet, one asset, 1:1 USD quote.
    function proposeRebalance() external returns (bool) {
        uint256 assetValueInUSD = baseBalance;
        // @> VULN: assetValueInUSD still includes pendingRedeem, so the weight check ignores it
        afterTradeWeight = (assetValueInUSD * WEIGHT_PRECISION) / totalValue;
        // FIX: quote baseBalance - pendingRedeem
        deviation = afterTradeWeight > targetWeight ? afterTradeWeight - targetWeight : targetWeight - afterTradeWeight;
        if (deviation > MAX_WEIGHT_DEVIATION) {
            met = false;
            return false;
        }
        met = true;
        uint256 payout = pendingRedeem;
        pendingRedeem = 0;
        baseBalance -= payout;
        token.transfer(redeemer, payout);
        return true;
    }
}

contract BasketFixed {
    uint256 public constant WEIGHT_PRECISION = 10_000;
    uint256 public constant MAX_WEIGHT_DEVIATION = 500;
    MockToken public token;
    uint256 public baseBalance = 1000 ether;
    uint256 public totalValue = 10000 ether;
    uint256 public targetWeight = 1000;
    uint256 public pendingRedeem;
    address public redeemer;

    constructor(address token_) {
        token = MockToken(token_);
        token.mint(address(this), 1000 ether);
    }

    function queueRedeem(address user, uint256 amount) external {
        token.mint(address(this), amount);
        baseBalance += amount;
        pendingRedeem += amount;
        redeemer = user;
    }

    function proposeRebalance() external returns (bool) {
        uint256 assetValueInUSD = baseBalance - pendingRedeem;
        uint256 weight = (assetValueInUSD * WEIGHT_PRECISION) / totalValue;
        uint256 deviation = weight > targetWeight ? weight - targetWeight : targetWeight - weight;
        if (deviation > MAX_WEIGHT_DEVIATION) return false;
        uint256 payout = pendingRedeem;
        pendingRedeem = 0;
        baseBalance -= payout;
        token.transfer(redeemer, payout);
        return true;
    }
}

contract Exploit {
    uint256 public constant REDEEM = 600 ether;

    MockToken public token;
    BasketManager public basket;
    bool public rebalanceOk;
    uint256 public weightBps;
    uint256 public deviationBps;
    uint256 public locked;

    constructor() {
        token = new MockToken();
        basket = new BasketManager(address(token));
    }

    function run() external {
        basket.queueRedeem(address(this), REDEEM);
        rebalanceOk = basket.proposeRebalance();
        weightBps = basket.afterTradeWeight();
        deviationBps = basket.deviation();
        locked = token.balanceOf(address(basket));
        require(rebalanceOk == false, "rebalance was allowed");
        require(weightBps == 1600, "weight is not 16 percent");
        require(deviationBps == 600, "deviation is not 6 percent");
        require(locked == 1600 ether, "redeem did not stay locked");
        require(token.balanceOf(address(this)) == 0, "redeemer was paid");
    }
}
