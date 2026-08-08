// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Exploit { uint256 public newLeverage; bool public harmed; event Proof(uint256 leverage);
    function run() external { uint256 currentPosition=100; uint256 currentCollateral=100; uint256 closable=49; uint256 leverage=2; uint256 buffer=2;
        // @> maxRedeem is limited by closable * LEVERAGE_BUFFER, although it is a collateral delta
        uint256 maxRedeem=closable*buffer; uint256 newPosition=currentPosition-closable; uint256 newCollateral=currentCollateral-maxRedeem; newLeverage=newPosition*leverage/newCollateral; harmed=newLeverage>leverage*buffer; emit Proof(newLeverage); require(harmed,"leverage bounded"); }
}
