// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NukeFund, EntityForging, Receiver, Exploit} from "./37917-h-03-incorrect-percentage-calculation-in-nukefund-and-entity.sol";

contract TaxCutPercentageTest is Test {
    /// @notice CONTROL — at the untouched default taxCut = 10, the math
    ///         happens to coincide with the intended 10% (this is exactly
    ///         why the bug hides at the default value).
    function test_defaultTaxCut_coincidentallyCorrect() public {
        Receiver dev = new Receiver();
        NukeFund fund = new NukeFund(address(dev));

        (bool ok, ) = address(fund).call{value: 1 ether}("");
        require(ok);

        // devShare = 1 ether / 10 = 0.1 ether == the intended 10%.
        assertEq(address(dev).balance, 0.1 ether);
        assertEq(fund.getFundBalance(), 0.9 ether);
    }

    /// @notice HARM — the moment the owner re-tunes taxCut away from 10
    ///         (here to 5, intending 5%), the dev silently collects 20%
    ///         instead — 4x the intended cut — on BOTH NukeFund and
    ///         EntityForging, at the expense of the fund pool / the forger.
    function test_taxCutChanged_devOverchargesOnBothContracts() public {
        Exploit exploit = new Exploit();

        uint256 devBefore = address(exploit.devAddr()).balance;
        uint256 forgerBefore = address(exploit.forger()).balance;

        exploit.run{value: 2 ether}();

        uint256 devAfter = address(exploit.devAddr()).balance;
        uint256 forgerAfter = address(exploit.forger()).balance;

        // Dev collected 0.2 ether from EACH contract (0.4 ether total)
        // instead of the intended 0.05 ether each (0.1 ether total).
        assertEq(devAfter - devBefore, 0.4 ether);

        // NukeFund pool booked only 0.8 ether instead of the intended 0.95.
        assertEq(exploit.nukeFund().getFundBalance(), 0.8 ether);

        // The forger received only 0.8 ether instead of the intended 0.95.
        assertEq(forgerAfter - forgerBefore, 0.8 ether);
    }
}
