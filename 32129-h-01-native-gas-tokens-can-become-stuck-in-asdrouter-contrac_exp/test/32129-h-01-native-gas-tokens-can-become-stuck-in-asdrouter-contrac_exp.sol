// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./32129-h-01-native-gas-tokens-can-become-stuck-in-asdrouter-contrac.sol";

/*//////////////////////////////////////////////////////////////
    Canto — native gas stuck in ASDRouter (#32129)
//////////////////////////////////////////////////////////////*/
contract ASDRouterStuckNativeTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        vm.deal(address(e), e.GAS());
        e.run();

        assertEq(address(e.router()).balance, e.GAS(), "1 ETH stuck on router");
        assertEq(e.asd().balanceOf(e.receiver()), e.AMOUNT(), "ASD delivered");
        assertEq(e.refund().balance, 0, "no refund");
    }

    function test_stuckNative_standalone() public {
        MockASD asd = new MockASD();
        ASDRouter router = new ASDRouter(1);
        address recv = makeAddr("recv");
        address ref = makeAddr("ref");
        asd.mint(address(router), 1000e18);

        OftComposeMessage memory payload = OftComposeMessage({
            _dstLzEid: 1,
            _dstReceiver: recv,
            _cantoAsdAddress: address(asd),
            _cantoRefundAddress: ref,
            _feeForSend: 0
        });

        router.sendOnCanto{value: 1 ether}(bytes32(0), payload, 1000e18);
        assertEq(address(router).balance, 1 ether);
        assertEq(asd.balanceOf(recv), 1000e18);
    }
}
