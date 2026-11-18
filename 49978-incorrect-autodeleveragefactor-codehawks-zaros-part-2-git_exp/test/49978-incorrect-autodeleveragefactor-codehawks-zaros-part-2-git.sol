// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Zaros Market.getAutoDeleverageFactor — CodeHawks 2025-01, part 2.
    The ADL factor is x^z, with x = 0 at the start threshold and x = 1 at
    the end threshold. Settlement multiplies trader PnL by that factor.
    At the moment ADL turns on, a 100 USD profit is paid as 0 and stays
    in the market. The fix is (1 - x)^z, which pays the full 100 USD.
*/

type UD60x18 is uint256;
type SD59x18 is int256;

uint256 constant UD60x18_UNIT = 1e18;

function ud60x18(uint128 x) pure returns (UD60x18) {
    return UD60x18.wrap(uint256(x));
}

library UDOps {
    function intoSD59x18(UD60x18 x) internal pure returns (SD59x18) {
        return SD59x18.wrap(int256(UD60x18.unwrap(x)));
    }

    function sub(UD60x18 a, UD60x18 b) internal pure returns (UD60x18) {
        return UD60x18.wrap(UD60x18.unwrap(a) - UD60x18.unwrap(b));
    }

    function div(UD60x18 a, UD60x18 b) internal pure returns (UD60x18) {
        return UD60x18.wrap(UD60x18.unwrap(a) * 1e18 / UD60x18.unwrap(b));
    }

    function pow(UD60x18 x, UD60x18) internal pure returns (UD60x18) {
        return x;
    }

    function mul(UD60x18 a, UD60x18 b) internal pure returns (UD60x18) {
        return UD60x18.wrap(UD60x18.unwrap(a) * UD60x18.unwrap(b) / 1e18);
    }

    function gte(UD60x18 a, UD60x18 b) internal pure returns (bool) {
        return UD60x18.unwrap(a) >= UD60x18.unwrap(b);
    }
}

library SDOps {
    function lte(SD59x18 a, SD59x18 b) internal pure returns (bool) {
        return SD59x18.unwrap(a) <= SD59x18.unwrap(b);
    }

    function isZero(SD59x18 a) internal pure returns (bool) {
        return SD59x18.unwrap(a) == 0;
    }

    function div(SD59x18 a, SD59x18 b) internal pure returns (SD59x18) {
        return SD59x18.wrap(SD59x18.unwrap(a) * 1e18 / SD59x18.unwrap(b));
    }

    function intoUD60x18(SD59x18 a) internal pure returns (UD60x18) {
        int256 v = SD59x18.unwrap(a);
        require(v >= 0, "neg");
        return UD60x18.wrap(uint256(v));
    }
}

library Math {
    function min(UD60x18 a, UD60x18 b) internal pure returns (UD60x18) {
        return UD60x18.unwrap(a) < UD60x18.unwrap(b) ? a : b;
    }
}

using UDOps for UD60x18;
using SDOps for SD59x18;

contract Usd {
    string public symbol = "USD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Market {
    struct Data {
        uint128 autoDeleverageStartThreshold;
        uint128 autoDeleverageEndThreshold;
        uint128 autoDeleverageExponentZ;
    }

    Usd public usd;
    Data internal self;
    uint256 public pnl = 100 ether;
    uint256 public delegatedCredit = 1000 ether;
    int256 public debt = 500 ether;
    uint256 public paid;
    uint256 public kept;
    uint256 public lastFactor;

    constructor(Usd _usd) {
        usd = _usd;
        self.autoDeleverageStartThreshold = 0.5e18;
        self.autoDeleverageEndThreshold = 0.8e18;
        self.autoDeleverageExponentZ = 1e18;
    }

    function isAutoDeleverageTriggered(UD60x18 delegatedCreditUsdX18, SD59x18 totalDebtUsdX18)
        public
        view
        returns (bool triggered)
    {
        SD59x18 sdDelegatedCreditUsdX18 = delegatedCreditUsdX18.intoSD59x18();
        if (sdDelegatedCreditUsdX18.lte(totalDebtUsdX18) || sdDelegatedCreditUsdX18.isZero()) {
            return false;
        }
        UD60x18 marketDebtRatio = totalDebtUsdX18.div(sdDelegatedCreditUsdX18).intoUD60x18();
        triggered = marketDebtRatio.gte(ud60x18(self.autoDeleverageStartThreshold));
    }

    function getAutoDeleverageFactor(UD60x18 delegatedCreditUsdX18, SD59x18 totalDebtUsdX18)
        public
        view
        virtual
        returns (UD60x18 autoDeleverageFactorX18)
    {
        SD59x18 sdDelegatedCreditUsdX18 = delegatedCreditUsdX18.intoSD59x18();
        if (sdDelegatedCreditUsdX18.lte(totalDebtUsdX18) || sdDelegatedCreditUsdX18.isZero()) {
            return UD60x18.wrap(UD60x18_UNIT);
        }

        UD60x18 marketDebtRatio = totalDebtUsdX18.div(sdDelegatedCreditUsdX18).intoUD60x18();

        UD60x18 autoDeleverageStartThresholdX18 = ud60x18(self.autoDeleverageStartThreshold);
        UD60x18 autoDeleverageEndThresholdX18 = ud60x18(self.autoDeleverageEndThreshold);
        UD60x18 autoDeleverageExponentZX18 = ud60x18(self.autoDeleverageExponentZ);

        UD60x18 unscaledDeleverageFactor = Math.min(marketDebtRatio, autoDeleverageEndThresholdX18).sub(
            autoDeleverageStartThresholdX18
        ).div(autoDeleverageEndThresholdX18.sub(autoDeleverageStartThresholdX18));

        // x^z is 0 when the debt ratio equals the start threshold. viaIR inlines pow.
        autoDeleverageFactorX18 = unscaledDeleverageFactor.pow(autoDeleverageExponentZX18);
    }

    function settle(address trader) external returns (uint256 payout) {
        UD60x18 credit = ud60x18(uint128(delegatedCredit));
        SD59x18 totalDebt = SD59x18.wrap(debt);
        bool adl = isAutoDeleverageTriggered(credit, totalDebt);
        require(adl, "adl");
        UD60x18 factor = getAutoDeleverageFactor(credit, totalDebt);
        lastFactor = UD60x18.unwrap(factor);
        // @> VULN: x^z is 0 at the ADL start threshold, so the trader's profit is multiplied by zero
        payout = pnl * lastFactor / 1e18;
        paid = payout;
        require(usd.transferFrom(msg.sender, address(this), pnl), "pull");
        if (payout > 0) require(usd.transfer(trader, payout), "pay");
        kept = pnl - payout;
    }
}

contract MarketFixed is Market {
    constructor(Usd _usd) Market(_usd) {}

    function getAutoDeleverageFactor(UD60x18 delegatedCreditUsdX18, SD59x18 totalDebtUsdX18)
        public
        view
        override
        returns (UD60x18 autoDeleverageFactorX18)
    {
        SD59x18 sdDelegatedCreditUsdX18 = delegatedCreditUsdX18.intoSD59x18();
        if (sdDelegatedCreditUsdX18.lte(totalDebtUsdX18) || sdDelegatedCreditUsdX18.isZero()) {
            return UD60x18.wrap(UD60x18_UNIT);
        }
        UD60x18 marketDebtRatio = totalDebtUsdX18.div(sdDelegatedCreditUsdX18).intoUD60x18();
        UD60x18 autoDeleverageStartThresholdX18 = ud60x18(self.autoDeleverageStartThreshold);
        UD60x18 autoDeleverageEndThresholdX18 = ud60x18(self.autoDeleverageEndThreshold);
        UD60x18 autoDeleverageExponentZX18 = ud60x18(self.autoDeleverageExponentZ);
        UD60x18 unscaledDeleverageFactor = Math.min(marketDebtRatio, autoDeleverageEndThresholdX18).sub(
            autoDeleverageStartThresholdX18
        ).div(autoDeleverageEndThresholdX18.sub(autoDeleverageStartThresholdX18));
        autoDeleverageFactorX18 =
            UD60x18.wrap(UD60x18_UNIT).sub(unscaledDeleverageFactor).pow(autoDeleverageExponentZX18);
    }
}

contract Exploit {
    address public constant TRADER = 0x0000000000000000000000000000000000000B0b;

    Usd public usd;
    Market public market;
    uint256 public paid;
    uint256 public kept;

    constructor() {
        usd = new Usd();
        market = new Market(usd);
        usd.mint(address(this), 100 ether);
        usd.approve(address(market), 100 ether);
    }

    function run() external {
        uint256 ratio = 0.5e18;
        require(ratio == 0.5e18, "start");
        paid = market.settle(TRADER);
        kept = market.kept();
        require(market.lastFactor() == 0, "factor");
        require(paid == 0, "paid");
        require(usd.balanceOf(TRADER) == 0, "trader");
        require(kept == 100 ether, "kept");
        require(usd.balanceOf(address(market)) == 100 ether, "market");
    }
}
