// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    LoanToken,
    PriceOracle,
    Vault
} from "./53742-updateregisterederc20modifies-the-wrong-token-sigmaprime-non.sol";

/// @dev Auditor fix: resolve the id from token_address, then write that id.
contract VaultFixed is Vault {
    constructor(LoanToken _loan, address _owner) Vault(_loan, _owner) {}

    function updateRegisteredErc20(
        address token_address,
        uint256 LTV,
        address oracle_address,
        uint256
    ) external override onlyOwner {
        uint256 id = tokenIdOf[token_address];
        require(id != 0, "unregistered");
        _tokenId_oracleAddress[id] = oracle_address;
        _tokenId_tokenLTV[id] = LTV;
    }
}

contract Finding53742Test is Test {
    address internal constant GOLD = address(0x1111111111111111111111111111111111110001);
    address internal constant DUST = address(0x1111111111111111111111111111111111110002);

    function test_exploit_pays_1000_on_the_wrong_token() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.paid(), 1000 ether, "1000 loan tokens paid");
        assertEq(e.dustOracleAfter(), address(e.richOracle()), "write hit DUST");
        assertEq(e.goldOracleAfter(), address(e.goldOracle()), "GOLD oracle unchanged");
        assertEq(e.loan().balanceOf(address(e)), 1000 ether, "attacker received 1000");
        assertEq(e.vault()._tokenId_tokenLTV(2), 10000, "DUST LTV is 100%");
        assertEq(e.vault()._tokenId_tokenLTV(1), 5000, "GOLD LTV still 50%");
    }

    function test_control_updates_the_named_token() public {
        LoanToken loan = new LoanToken();
        PriceOracle goldOracle = new PriceOracle(500 ether);
        PriceOracle dustOracle = new PriceOracle(1 ether);
        PriceOracle richOracle = new PriceOracle(1000 ether);
        VaultFixed vault = new VaultFixed(loan, address(this));
        vault.registerErc20(GOLD, address(goldOracle), 5000);
        vault.registerErc20(DUST, address(dustOracle), 5000);
        loan.mint(address(vault), 1000 ether);

        vault.updateRegisteredErc20(GOLD, 10000, address(richOracle), 0);
        assertEq(vault._tokenId_oracleAddress(1), address(richOracle), "GOLD updated");
        assertEq(vault._tokenId_oracleAddress(2), address(dustOracle), "DUST untouched");

        uint256 paid = vault.borrow(DUST, 1 ether);
        assertEq(paid, 0.5 ether, "1 DUST at price 1 and 50% LTV pays 0.5");
        assertEq(loan.balanceOf(address(vault)), 999.5 ether, "the 1000 was not paid");
    }
}
