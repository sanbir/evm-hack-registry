// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "../PNFTToken/PErc721/PErc721Delegate.sol";
import "../PToken/PErc20/PErc20Delegate.sol";
import "../PToken/PEther/PEtherDelegate.sol";

contract PNFTTokenStorageV2Mock is PNFTTokenStorage {
    int foo;
    int bar;
}

contract PErc721DelegateV2Mock is PErc721Delegate, PNFTTokenStorageV2Mock { // that EXACT inheritance order is CRUCIAL here
    function getBar() external view returns (int) {
        return bar;
    }

    function setBar(int _bar) external {
        bar = _bar;
    }

    function getFoo() external view returns (int) {
        return foo;
    }

    function setFoo(int _foo) external {
        foo = _foo;
    }
}

contract PTokenStorageV2Mock is PTokenStorage {
    int foo;
    int bar;
}

contract PErc20DelegateV2Mock is PErc20Delegate, PTokenStorageV2Mock { // that EXACT inheritance order is CRUCIAL here
    function getBar() external view returns (int) {
        return bar;
    }

    function setBar(int _bar) external {
        bar = _bar;
    }

    function getFoo() external view returns (int) {
        return foo;
    }

    function setFoo(int _foo) external {
        foo = _foo;
    }
}

contract PEtherStorageV2Mock is PTokenStorage {
    int foo;
    int bar;
}

contract PEtherDelegateV2Mock is PEtherDelegate, PEtherStorageV2Mock { // that EXACT inheritance order is CRUCIAL here
    function getBar() external view returns (int) {
        return bar;
    }

    function setBar(int _bar) external {
        bar = _bar;
    }

    function getFoo() external view returns (int) {
        return foo;
    }

    function setFoo(int _foo) external {
        foo = _foo;
    }
}
