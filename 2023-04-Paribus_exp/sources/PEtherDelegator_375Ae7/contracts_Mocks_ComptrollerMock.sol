// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "../Comptroller/ComptrollerNFTPart1.sol";
import "../Comptroller/ComptrollerNFTPart2.sol";

contract ComptrollerMockBase is ComptrollerNFTPart1, ComptrollerNFTPart2 {
    constructor() public { }

    function isComptroller() external pure returns (bool) {
        return true;
    }
}

contract AllowingComptrollerMock is ComptrollerMockBase { // Comptroller with no business restrictions
    function mintAllowed(address, address, uint) external returns (uint) { return uint(Error.NO_ERROR); }
    function mintNFTAllowed(address, address, uint) external returns (uint) { return uint(Error.NO_ERROR); }
    function mintVerify(address, address, uint, uint) external { }
    function mintNFTVerify(address, address, uint) external { }
    function redeemVerify(address, address, uint, uint) external { }
    function redeemNFTVerify(address, address, uint) external { }
    function borrowVerify(address, address, uint) external { }
    function transferVerify(address, address, address, uint) external { }
    function transferNFTVerify(address, address, address, uint) external { }
    function redeemAllowed(address, address, uint) external returns (uint) { return uint(Error.NO_ERROR); }
    function redeemNFTAllowed(address, address, uint) external returns (uint) { return uint(Error.NO_ERROR); }
    function borrowAllowed(address, address, uint) external returns (uint) { return uint(Error.NO_ERROR); }
    function transferAllowed(address, address, address, uint) external returns (uint) { return uint(Error.NO_ERROR); }
    function transferNFTAllowed(address, address, address, uint) external returns (uint) { return uint(Error.NO_ERROR); }
    function repayBorrowAllowed(address, address, address, uint) external returns (uint) { return uint(Error.NO_ERROR); }
    function repayBorrowVerify(address, address, address, uint, uint) external { }
    function liquidateBorrowVerify(address, address, address, address, uint, uint) external { }
    function seizeAllowed(address, address, address, address, uint) external returns (uint) { return uint(Error.NO_ERROR); }
    function liquidateNFTCollateralAllowed(address, address, address, uint, address) external returns (uint) { return uint(Error.NO_ERROR); }
    function seizeVerify(address, address, address, address, uint) external { }
    function liquidateBorrowAllowed(address, address, address, address, uint) external returns (uint) { return uint(Error.NO_ERROR); }
    function liquidateNFTCollateralVerify(address, address, address, uint) external { }
}

contract DenyingComptrollerMock is ComptrollerMockBase {
    function mintAllowed(address, address, uint) external returns (uint) { return uint(Error.REJECTION); }
    function mintVerify(address, address, uint, uint) external { }
    function redeemVerify(address, address, uint, uint) external { }
    function borrowVerify(address, address, uint) external { }
    function transferVerify(address, address, address, uint) external { }
    function redeemAllowed(address, address, uint) external returns (uint) { return uint(Error.REJECTION); }
    function borrowAllowed(address, address, uint) external returns (uint) { return uint(Error.REJECTION); }
    function transferAllowed(address, address, address, uint) external returns (uint) { return uint(Error.REJECTION); }
    function repayBorrowAllowed(address, address, address, uint) external returns (uint) { return uint(Error.REJECTION); }
    function repayBorrowVerify(address, address, address, uint, uint) external { }
    function liquidateBorrowVerify(address, address, address, address, uint, uint) external { }
    function seizeAllowed(address, address, address, address, uint) external returns (uint) { return uint(Error.REJECTION); }
    function seizeVerify(address, address, address, address, uint) external { }
    function liquidateBorrowAllowed(address, address, address, address, uint) external returns (uint) { return uint(Error.REJECTION); }
}

contract ComptrollerStorageV2Mock is ComptrollerNFTStorage {
    int foo;
    int bar;
}

contract ComptrollerPart1V2Mock is ComptrollerStorageV2Mock, ComptrollerNFTPart1 {
    function getFoo() external view returns (int) {
        return foo;
    }

    function setFoo(int _foo) external {
        foo = _foo;
    }
}

contract ComptrollerPart2V2Mock is ComptrollerStorageV2Mock, ComptrollerNFTPart2 {
    function getBar() external view returns (int) {
        return bar;
    }

    function setBar(int _bar) external {
        bar = _bar;
    }
}

contract ComptrollerV2Interface is ComptrollerPart1V2Mock, ComptrollerPart2V2Mock { }
