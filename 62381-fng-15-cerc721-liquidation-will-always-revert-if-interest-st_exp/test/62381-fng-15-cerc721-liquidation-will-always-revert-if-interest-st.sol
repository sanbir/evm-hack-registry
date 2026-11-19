// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Fungify CErc721._liquidateBorrow (Hexens, 2023-11).
    accrueInterest returns 0 when this block already accrued. The freshness
    check treats that 0 as stale and reverts, so the 100 of collateral is
    not seized. The fixed accrue returns the stored exchange rate instead.
*/

error LiquidateFreshnessCheck();

contract CToken {
    uint256 public accrualBlockNumber = type(uint256).max;
    uint256 public exchangeRate = 2 ether;
    uint256 public collateral = 100 ether;
    uint256 public constant NO_ERROR = 0;
    uint256 public lastSeized;

    function accrueInterest() public returns (uint256) {
        uint256 currentBlockNumber = block.number;
        if (accrualBlockNumber == currentBlockNumber) {
            return NO_ERROR; // quoted short-circuit: rate is not returned
        }
        accrualBlockNumber = currentBlockNumber;
        return exchangeRate;
    }

    function liquidate() external returns (uint256 seized) {
        uint256 assetsExchangeRate = accrueInterest();
        // Quoted check. The published function reverts here. Returning 0 leaves the same collateral in place.
        if (accrualBlockNumber != block.number || assetsExchangeRate == 0) {
            lastSeized = assetsExchangeRate; // @> VULN: the same-block accrue returned 0, so the 100 is not seized
            return 0;
        }
        seized = collateral;
        collateral = 0;
        lastSeized = seized;
    }
}

contract CTokenFixed {
    uint256 public accrualBlockNumber = type(uint256).max;
    uint256 public exchangeRate = 2 ether;
    uint256 public collateral = 100 ether;
    uint256 public lastSeized;

    function accrueInterest() public returns (uint256) {
        uint256 currentBlockNumber = block.number;
        if (accrualBlockNumber == currentBlockNumber) {
            return exchangeRate;
        }
        accrualBlockNumber = currentBlockNumber;
        return exchangeRate;
    }

    function liquidate() external returns (uint256 seized) {
        uint256 assetsExchangeRate = accrueInterest();
        require(accrualBlockNumber == block.number && assetsExchangeRate != 0, "fresh");
        seized = collateral;
        collateral = 0;
        lastSeized = seized;
    }
}

contract StuckMarker {
    string public symbol = "UNSEIZED";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract Exploit {
    uint256 public constant COLLATERAL = 100 ether;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    CToken public market;
    StuckMarker public marker;

    function run() external {
        market = new CToken();
        marker = new StuckMarker();
        uint256 first = market.accrueInterest();
        require(first == 2 ether, "first accrue returns the rate");
        uint256 seized = market.liquidate();
        require(seized == 0, "liquidation paid");
        require(market.collateral() == COLLATERAL, "collateral still there");
        require(market.lastSeized() == 0, "zero rate stored");
        marker.mint(SINK, COLLATERAL);
        require(marker.balanceOf(SINK) == COLLATERAL, "100 unseized");
    }
}
