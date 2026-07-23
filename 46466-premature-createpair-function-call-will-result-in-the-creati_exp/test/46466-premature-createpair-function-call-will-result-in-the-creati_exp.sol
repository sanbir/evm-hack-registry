// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./46466-premature-createpair-function-call-will-result-in-the-creati.sol";

/*//////////////////////////////////////////////////////////////////////////
    Sweep n Flip — Premature createPair DoS of NFT wrapper pairs (#46466)
//////////////////////////////////////////////////////////////////////////*/
contract PrematureCreatePairTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        UniswapV2Factory factory = e.factory();
        address usdc = address(e.usdc());
        address wrapper = e.realWrapper();

        assertEq(e.precomputedWrapper(), wrapper, "CREATE2 match");
        assertTrue(factory.isWrapper(wrapper), "wrapper registered");
        assertTrue(factory.delegates(usdc, wrapper), "pair stuck as delegated");
        assertTrue(factory.delegates(wrapper, usdc), "reverse delegates stuck");
    }

    /// @notice Control: createWrapper BEFORE createPair → not delegated.
    function test_legitimateOrderNotDelegated() public {
        UniswapV2Factory factory = new UniswapV2Factory();
        MockERC20 usdc = new MockERC20();
        MockERC721 apes = new MockERC721();

        address wrapper = factory.createWrapper(address(apes));
        factory.createPair(address(usdc), wrapper);

        assertTrue(factory.isWrapper(wrapper));
        assertFalse(factory.delegates(address(usdc), wrapper), "native pair must not be delegated");
    }
}
