// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./50038-h-02-lzreceive-call-for-releaseoneid-results-in-oog-error-pa.sol";

/* NFTMirror H-02 — getSendOptions underfunds lzReceive → OOG (Pashov 2024-12) */
contract PoC_50038 is Test {
    function test_lzReceiveOOG() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.oogStored());
        assertGt(e.gasUsedSample(), uint256(e.budget()));
        assertEq(uint256(e.budget()), 100_000);
        // Token not minted under the budgeted path
        assertFalse(e.shadow().exists(8903));
    }
}
