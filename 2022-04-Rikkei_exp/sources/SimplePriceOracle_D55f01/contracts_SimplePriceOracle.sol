pragma solidity ^0.5.16;

import "./PriceOracle.sol";
import "./RBep20.sol";

interface oracleChainlink {
    function decimals() external view returns (uint8);
    function latestRoundData()
    external
    view
    returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

contract SimplePriceOracle is PriceOracle {
    mapping(address => uint) prices;

    event PricePosted(address asset, uint previousPriceMantissa, uint requestedPriceMantissa, uint newPriceMantissa);

    mapping(address => oracleChainlink) public oracleData;

    constructor() public {
    }

    // === VULNERABILITY: MISSING ACCESS CONTROL ON PRICE ORACLE SETTER ===
    // This is the root cause of the 2022-04-Rikkei exploit (~$270k loss).
    //
    // VULNERABILITY LOCATION: contracts_SimplePriceOracle.sol:29
    //   function setOracleData(address rToken, oracleChainlink _oracle) external {
    //       oracleData[rToken] = _oracle;
    //   }
    //
    // - Declared `external` with NO modifiers (no onlyAdmin, no onlyOwner).
    // - `oracleData` mapping is the single source of truth for every market's price feed.
    // - getUnderlyingPrice() trusts whatever the pointed contract returns for
    //   decimals() and latestRoundData().answer WITHOUT any validation, staleness check,
    //   or sanity bounds.
    // - Resulting price is fed directly into Cointroller liquidity calculations:
    //     collateralValue = collateralFactor * exchangeRate * oraclePrice * rTokenBalance
    // - Impact: attacker can manufacture arbitrary collateral value for any entered market,
    //   allowing borrow of 100% of any other listed market's cash reserves.
    //
    // See exploit usage in test/RikkeiOracleHijack.sol and test/Rikkei_exp.sol .
    function setOracleData(address rToken, oracleChainlink _oracle) external {
        oracleData[rToken] = _oracle;
    }

    function getUnderlyingPrice(RToken rToken) public view returns (uint) {
        uint decimals = oracleData[address(rToken)].decimals();
        (uint80 roundId,int256 answer,uint256 startedAt,uint256 updatedAt,uint80 answeredInRound) = oracleData[address(rToken)].latestRoundData();
        return 10 ** (18 - decimals) * uint(answer);
    }
}
