// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24; import "forge-std/Test.sol";import "./31276-the-previous-milestone-stem-should-be-scaled-for-use-with-th.sol";contract MilestoneStemTest is Test{function test_legacyStemScaleMismatch()external{Exploit e=new Exploit();e.run();assertEq(e.silo().correctTip()-e.silo().stemTipForToken(),99_999_900);}}
