// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Plaza Finance Pool — H-9 (Sherlock 2024-12, issue 895)
    COLLATERAL_THRESHOLD is 120% (1_200_000 at 1e6 precision). Crossing it snaps
    the bond redeem rate from 80% of TVL to the target price of 100. With the
    report's pool (bond supply 10), TVL 1190 pays leverage 238 and TVL 1210 pays
    leverage 210. Holders lose 28 while the collateral rises. 125% keeps 1210 on
    the 80/20 curve and pays leverage 242.
    getRedeemAmount is the audited function, constants included.
*/

library Decimals {
    function toBaseUnit(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        return amount / (10 ** decimals);
    }

    function fromBaseUnit(uint256 baseUnitAmount, uint8 decimals) internal pure returns (uint256) {
        return baseUnitAmount * (10 ** decimals);
    }
}

contract Pool {
    using Decimals for uint256;

    uint256 internal constant POINT_EIGHT = 800000;
    uint256 internal constant POINT_TWO = 200000;
    uint256 internal constant COLLATERAL_THRESHOLD = 1200000; // FIX: 1250000
    uint256 internal constant PRECISION = 1000000;
    uint256 internal constant BOND_TARGET_PRICE = 100;

    enum TokenType {
        BOND,
        LEVERAGE
    }

    error ZeroDebtSupply();
    error ZeroLeverageSupply();

    function getRedeemAmount(
        TokenType tokenType,
        uint256 depositAmount,
        uint256 bondSupply,
        uint256 levSupply,
        uint256 poolReserves,
        uint256 ethPrice,
        uint8 oracleDecimals,
        uint256 marketRate
    ) public pure returns (uint256) {
        if (bondSupply == 0) {
            revert ZeroDebtSupply();
        }

        uint256 tvl = (ethPrice * poolReserves).toBaseUnit(oracleDecimals);
        uint256 assetSupply = bondSupply;
        uint256 multiplier = POINT_EIGHT;

        uint256 collateralLevel;
        if (tokenType == TokenType.BOND) {
            collateralLevel = ((tvl - (depositAmount * BOND_TARGET_PRICE)) * PRECISION)
                / ((bondSupply - depositAmount) * BOND_TARGET_PRICE);
        } else {
            multiplier = POINT_TWO;
            assetSupply = levSupply;
            collateralLevel = (tvl * PRECISION) / (bondSupply * BOND_TARGET_PRICE);

            if (assetSupply == 0) {
                revert ZeroLeverageSupply();
            }
        }

        uint256 redeemRate;
        if (collateralLevel <= COLLATERAL_THRESHOLD) { // @> VULN: 120% cliff, not the continuous 125%
            redeemRate = ((tvl * multiplier) / assetSupply); // @beat:below
        } else if (tokenType == TokenType.LEVERAGE) {
            redeemRate = ((tvl - (bondSupply * BOND_TARGET_PRICE)) / assetSupply) * PRECISION; // @beat:snap
        } else {
            redeemRate = BOND_TARGET_PRICE * PRECISION;
        }

        if (marketRate != 0 && marketRate < redeemRate) {
            redeemRate = marketRate;
        }

        return ((depositAmount * redeemRate).fromBaseUnit(oracleDecimals) / ethPrice) / PRECISION;
    }

    /// @dev Report's continuous curve: 125% still uses the 20% leverage share at TVL 1210.
    function redeemIfThreshold125(uint256 poolReserves) external pure returns (uint256) {
        uint256 tvl = poolReserves;
        uint256 collateralLevel = (tvl * PRECISION) / (10 * BOND_TARGET_PRICE);
        require(collateralLevel <= 1250000, "above 125");
        uint256 redeemRate = (tvl * POINT_TWO) / 10;
        return (10 * redeemRate) / PRECISION;
    }
}

contract Exploit {
    Pool public pool;
    uint256 public levBefore;
    uint256 public levAfter;
    uint256 public loss;
    uint256 public fairAfter;

    constructor() {
        pool = new Pool(); // nonce 1
    }

    function _quote(uint256 reserves) internal view returns (uint256) {
        return pool.getRedeemAmount(Pool.TokenType.LEVERAGE, 10, 10, 10, reserves, 1, 0, 0);
    }

    function run() external {
        levBefore = _quote(1190); // @beat:before
        levAfter = _quote(1210); // @beat:after
        loss = levBefore - levAfter;
        fairAfter = pool.redeemIfThreshold125(1210); // @beat:fair
        require(levBefore == 238, "1190 leverage claim");
        require(levAfter == 210, "1210 leverage claim");
        require(loss == 28, "28 lost while TVL rose"); // @beat:loss
        require(fairAfter == 242, "125% would pay 242");
    }
}
